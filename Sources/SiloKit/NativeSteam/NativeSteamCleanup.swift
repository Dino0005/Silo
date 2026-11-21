import Foundation

/// What Silo made for a game started from Steam for macOS, removed once the game is uninstalled (user, 2026-11-20:
/// "the game app Silo created should go with the game, not be left to me"): its game app in `GameApps/<id>` — the
/// bundle with its name and icon in the Dock and the Games app — and the `steamapps/compatdata/<id>` folder of its
/// library, when that holds nothing but Silo's links to the bottle's saves (`SteamCloudSaves.prepareCompatUser`).
/// The saves themselves live in the bottle and in Steam Cloud, so nothing of the player's goes.
///
/// Nothing is removed while one of Steam's libraries is missing (an unplugged external disk): its games would look
/// uninstalled. Game apps are made only by launches from Steam for macOS, so Steam's libraries are the whole picture.
public enum NativeSteamCleanup {
    /// The leftovers of games not installed in any of `libraries` (each a Steam library root, with `steamapps`).
    /// Empty when any library isn't reachable. `installed`: the app ids that have an `appmanifest_<id>.acf`.
    public static func leftovers(gameAppsDir: URL, libraries: [URL], installed: Set<UInt32>,
                                 fileManager: FileManager = .default) -> [URL] {
        guard libraries.allSatisfy({ fileManager.fileExists(atPath: $0.appendingPathComponent("steamapps").path) })
        else { return [] }
        func uninstalled(_ name: String) -> Bool { UInt32(name).map { !installed.contains($0) } ?? false }
        var found: [URL] = []
        for name in ((try? fileManager.contentsOfDirectory(atPath: gameAppsDir.path)) ?? []).sorted() where uninstalled(name) {
            found.append(gameAppsDir.appendingPathComponent(name, isDirectory: true))
        }
        for library in libraries {
            let compat = library.appendingPathComponent("steamapps/compatdata", isDirectory: true)
            for name in ((try? fileManager.contentsOfDirectory(atPath: compat.path)) ?? []).sorted() where uninstalled(name) {
                let dir = compat.appendingPathComponent(name, isDirectory: true)
                if isSiloLinksOnly(dir, fileManager: fileManager) { found.append(dir) }
            }
        }
        return found
    }

    /// Whether `compatData` is exactly Silo's layout: folders, symbolic links (never followed) and Silo's marker file.
    /// A real Wine prefix — anything with a regular file of its own — is not Silo's to remove.
    static func isSiloLinksOnly(_ compatData: URL, fileManager: FileManager = .default) -> Bool {
        let marker = compatData.appendingPathComponent("pfx/\(SteamCloudSaves.compatMarkerName)")
        guard fileManager.fileExists(atPath: marker.path),
              let walker = fileManager.enumerator(at: compatData, includingPropertiesForKeys: [.isSymbolicLinkKey, .isDirectoryKey],
                                                  options: [], errorHandler: { _, _ in false })
        else { return false }
        for case let url as URL in walker {
            let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
            if values?.isSymbolicLink == true { walker.skipDescendants(); continue }
            if values?.isDirectory == true { continue }
            if url.lastPathComponent == SteamCloudSaves.compatMarkerName { continue }
            return false
        }
        return true
    }

    /// The `.app` bundles inside `leftovers`' game-app folders — registered with LaunchServices (the Games app lists them
    /// from there), so they are unregistered when removed (`lsregisterArguments`), else the entry outlives the file.
    public static func appBundles(in leftovers: [URL], gameAppsDir: URL, fileManager: FileManager = .default) -> [URL] {
        leftovers.filter { $0.deletingLastPathComponent().standardizedFileURL == gameAppsDir.standardizedFileURL }
            .flatMap { dir in
                ((try? fileManager.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0.hasSuffix(".app") }.sorted()
                    .map { dir.appendingPathComponent($0, isDirectory: true) }
            }
    }

    /// LaunchServices' own tool, which unregisters a bundle path (there is no public API for it).
    public static let lsregister = URL(fileURLWithPath:
        "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister")

    public static func lsregisterArguments(unregistering app: URL) -> [String] { ["-u", app.path] }

    /// Removes `leftovers` (a symbolic link is removed itself, never what it points to). Returns one line per item.
    @discardableResult
    public static func remove(_ leftovers: [URL], fileManager: FileManager = .default) -> [String] {
        leftovers.compactMap { url in
            (try? fileManager.removeItem(at: url)) != nil ? "removed \(url.path) (game uninstalled)" : nil
        }
    }
}
