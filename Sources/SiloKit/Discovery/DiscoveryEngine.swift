import Foundation

/// Parses a Steam library root (the Steam bottle's `steamapps`) for installed games.
///
/// Reads the primary `steamapps` directory plus any additional libraries listed in
/// `libraryfolders.vdf`, parses every `appmanifest_*.acf`, and returns the games sorted by name.
/// Unparseable manifests and missing extra libraries are skipped rather than failing the whole scan;
/// an *unreadable* primary library (permissions/IO) throws `libraryUnreadable` so the UI can say so.
public actor DiscoveryEngine {
    private let fileManager: FileManager
    private let manifestDecoder = AppManifestDecoder()
    private let libraryDecoder = LibraryFoldersDecoder()
    /// Upper bound on any single manifest/VDF we'll read into memory (see `discoverGames`/`collectLibraryRoots`).
    private let maxManifestBytes: Int

    public init(fileManager: FileManager = .default, maxManifestBytes: Int = 8 * 1024 * 1024) {
        self.fileManager = fileManager
        self.maxManifestBytes = maxManifestBytes
    }

    public enum DiscoveryError: Error, Sendable, Equatable {
        case steamDirNotFound(URL)
        /// The primary library exists but couldn't be listed (permissions/IO) — a real failure the UI
        /// should surface, unlike `steamDirNotFound` (a fresh bottle that has no library yet).
        case libraryUnreadable(URL)
    }

    /// Discover all games reachable from `steamRoot` (the primary Steam install directory).
    /// - Parameter bottlePrefix: the Wine prefix `steamRoot` lives inside — needed to resolve any
    ///   Windows-style library paths (`X:\SteamLibrary`) that Steam-under-Wine writes to
    ///   `libraryfolders.vdf` for additional library folders, via the bottle's `dosdevices/<letter>:`
    ///   symlinks. Pass `nil` to keep the previous behavior (Windows-style entries are skipped).
    public func discoverGames(steamRoot: URL, bottlePrefix: URL? = nil) throws -> [SteamApp] {
        let primarySteamapps = steamRoot.appendingPathComponent("steamapps", isDirectory: true)
        guard fileManager.fileExists(atPath: primarySteamapps.path) else {
            throw DiscoveryError.steamDirNotFound(primarySteamapps)
        }

        let libraryRoots = collectLibraryRoots(primarySteamRoot: steamRoot, bottlePrefix: bottlePrefix)

        var apps: [SteamApp] = []
        var seen = Set<Int>()
        for (index, root) in libraryRoots.enumerated() {
            // Skip shared system packages (Steamworks Common Redistributables, runtimes, tools): Steam
            // installs them with `LastOwner == 0`, so they aren't games — see `SteamApp.isSharedSystemApp`.
            for app in try scanLibrary(root: root, required: index == 0)
            where !app.isSharedSystemApp && seen.insert(app.appID).inserted {
                apps.append(app)
            }
        }
        return apps.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    // MARK: - Internals

    /// Primary library + any other libraries from `libraryfolders.vdf`, de-duplicated. Host-absolute
    /// (already-Unix) paths are used as-is; Windows-style paths (`X:\...`, written by Steam running
    /// inside the Wine bottle) are resolved through `bottlePrefix`'s `dosdevices/<letter>:` symlink when
    /// one is supplied — see `hostURL(forWindowsLibraryPath:bottlePrefix:)`.
    private func collectLibraryRoots(primarySteamRoot: URL, bottlePrefix: URL?) -> [URL] {
        var roots: [URL] = [primarySteamRoot]
        var seenPaths = Set([primarySteamRoot.standardizedFileURL.path])

        let steamapps = primarySteamRoot.appendingPathComponent("steamapps", isDirectory: true)
        let vdf = steamapps.appendingPathComponent("libraryfolders.vdf")
        // Bound the whole-file read like `scanLibrary` does for appmanifests — a real `libraryfolders.vdf`
        // is a few KB; a pathologically large (corrupt/hostile) one shouldn't be slurped into memory.
        let vdfSize = (try? vdf.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        if vdfSize <= maxManifestBytes,
           let text = try? String(contentsOf: vdf, encoding: .utf8),
           let folders = try? libraryDecoder.decode(text: text) {
            for folder in folders {
                let resolved: URL?
                if folder.rawPath.hasPrefix("/") {
                    resolved = folder.path.standardizedFileURL
                } else if let bottlePrefix {
                    resolved = hostURL(forWindowsLibraryPath: folder.rawPath, bottlePrefix: bottlePrefix)?
                        .standardizedFileURL
                } else {
                    resolved = nil
                }
                guard let resolved else { continue }
                if seenPaths.insert(resolved.path).inserted {
                    roots.append(resolved)
                }
            }
        }
        return roots
    }

    /// Resolve a Windows-style library path (e.g. `X:\SteamLibrary`) written by Steam running inside a
    /// Wine bottle, to the real host (macOS) path — via the bottle's own `dosdevices/<letter>:` symlink,
    /// which Wine maintains for every drive the user has configured (winecfg's Drives tab). Returns nil
    /// for anything that isn't a `<letter>:\...` form, or whose drive isn't configured/reachable right
    /// now (e.g. an ejected external volume) — matching the existing "skip what we can't resolve" behavior.
    private func hostURL(forWindowsLibraryPath winPath: String, bottlePrefix: URL) -> URL? {
        let chars = Array(winPath)
        guard chars.count >= 2, chars[1] == ":", let letter = chars[0].lowercased().first, letter.isLetter
        else { return nil }
        let symlink = bottlePrefix.appendingPathComponent("dosdevices").appendingPathComponent("\(letter):")
        guard let destination = try? fileManager.destinationOfSymbolicLink(atPath: symlink.path) else {
            return nil
        }
        let base = destination.hasPrefix("/")
            ? URL(fileURLWithPath: destination)
            : symlink.deletingLastPathComponent().appendingPathComponent(destination).standardizedFileURL
        let rest = String(chars[2...]).replacingOccurrences(of: "\\", with: "/")
        let trimmed = rest.hasPrefix("/") ? String(rest.dropFirst()) : rest
        return trimmed.isEmpty ? base : base.appendingPathComponent(trimmed)
    }

    /// `required` marks the primary library: a listing failure there throws `libraryUnreadable` (the UI
    /// surfaces it); extra libraries from `libraryfolders.vdf` keep the documented skip-on-missing behavior.
    private func scanLibrary(root: URL, required: Bool) throws -> [SteamApp] {
        let steamapps = root.appendingPathComponent("steamapps", isDirectory: true)
        let entries: [URL]
        do {
            entries = try fileManager.contentsOfDirectory(at: steamapps, includingPropertiesForKeys: nil)
        } catch {
            if required { throw DiscoveryError.libraryUnreadable(steamapps) }
            return []
        }

        var apps: [SteamApp] = []
        for entry in entries
        where entry.lastPathComponent.hasPrefix("appmanifest_") && entry.pathExtension == "acf" {
            // Skip a pathologically large file: the tokenizer reads the whole manifest into memory, and a
            // real appmanifest is a few KB — anything over the cap isn't a manifest worth parsing.
            let size = (try? entry.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            guard size <= maxManifestBytes else { continue }
            guard let text = try? String(contentsOf: entry, encoding: .utf8),
                  let app = try? manifestDecoder.decode(text: text, libraryPath: root) else { continue }
            apps.append(app)
        }
        return apps
    }
}
