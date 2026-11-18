import Foundation

/// The game's identity for a launch from **macOS Steam**: Wine's loader placed inside the game's host bundle
/// (`GameHostBundle`), so every process of the game runs *from* that `.app` and macOS gives it the game's name and
/// icon in the Dock, Mission Control and Stage Manager.
///
/// Why not the alt-loader host there: the host adopts exactly one process, and a game that relaunches itself
/// (measured on SOULCALIBUR VI, 2026-11-12: the adopted process starts a fresh copy of the game and exits, as soon as
/// Steam Input's pad reaches it) leaves the copy outside the bundle — Dock "wine", blank Stage Manager tile.
/// Here a small injected library (`Scripts/game-loader`, `silo-game-loader.dylib`) re-points every exec of the
/// loader for one of the game's executables at the copy in the bundle, relaunches included. Same idea as NotProton's
/// PR #90 (sn0wst0rm; final version in the NotProton fork as d77e605/8946aab/71b8965) — Silo's own code.
///
/// The loader is a **private copy** of the runtime's `lib/wine/x86_64-unix/wine` with the game's identity and Game Mode
/// in its embedded plist (`EmbeddedInfoPlist`, re-signed ad-hoc), and every other entry of that directory is
/// **symlinked** beside it: the loader finds `ntdll.so` next to itself, and
/// `ntdll.so` resolves through its symlink to the real runtime, from which Wine derives its other directories.
/// (`CLAUDE.md`'s 2026-09-17 note that a moved loader can't work was measured without those siblings.)
public enum GameAppLoader {
    /// The loader's name inside `Contents/MacOS` — the one name the injected library and the Steam hook look for.
    public static let loaderName = "wine"
    /// The injected library inside Silo.app.
    static let injectorRelativePath = "Contents/Helpers/silo-game-loader.dylib"

    /// Environment the injected library reads: the loader to exec, and the game's executable names.
    public static let loaderEnvKey = "SILO_GAME_LOADER"
    public static let executablesEnvKey = "SILO_GAME_EXES"

    /// The injected library of the running app, or nil (a `swift run` build has no `.app`).
    public static func injector(inAppBundle appBundle: URL = Bundle.main.bundleURL,
                                fileManager: FileManager = .default) -> URL? {
        let url = appBundle.appendingPathComponent(injectorRelativePath)
        return fileManager.fileExists(atPath: url.path) ? url : nil
    }

    /// Pure: the `SILO_GAME_EXES` value — every distinct file name, joined by `:`.
    static func executablesValue(_ executables: [URL]) -> String {
        var seen = Set<String>(), names: [String] = []
        for name in executables.map(\.lastPathComponent) where !name.isEmpty && !name.contains(":") {
            if seen.insert(name.lowercased()).inserted { names.append(name) }
        }
        return names.joined(separator: ":")
    }

    /// Where `stage` left the loader: `loader` is final when `unsigned` is nil; otherwise the caller signs `unsigned`
    /// (ad-hoc) and calls `install`.
    public struct Staged: Sendable, Equatable {
        public let loader: URL
        public let unsigned: URL?
    }

    static let sourceMarkerName = ".wine.silo-source"

    /// Where the marker lives: `Contents/Resources`. Not beside the loader — `Contents/MacOS` must hold only code, or the
    /// bundle can't be signed as a whole (`signBundle`), which LaunchServices needs once the plist has `LSEnvironment`.
    static func markerURL(macOSDir: URL) -> URL {
        macOSDir.deletingLastPathComponent().appendingPathComponent("Resources", isDirectory: true)
            .appendingPathComponent(sourceMarkerName)
    }

    // MARK: - Started by the Games app

    /// What the injected library reads when the game app was started with no game — by the Games app, which lists the
    /// bundle by its games category and opens it directly (measured 2026-11-18: TEKKEN's icon for a few seconds, then
    /// nothing). `SILO_GAMES_HANDOFF` is the `steam://` link to ask for; `SILO_STEAM_LAUNCHER` is "Steam (Silo)", opened
    /// first when Steam isn't running, so Steam starts with Silo's library and grants. Same idea as Silo's own fix in its
    /// NotProton fork (49ee6f5, 2026-10-12); Silo's own code.
    public static let handoffEnvKey = "SILO_GAMES_HANDOFF"
    public static let steamLauncherEnvKey = "SILO_STEAM_LAUNCHER"

    /// Pure: the game app's `LSEnvironment` — the injected library, and where it hands a start with no game.
    public static func gamesHandoffEnvironment(appID: Int, injector: URL, steamLauncher: URL) -> [String: String] {
        ["DYLD_INSERT_LIBRARIES": injector.path,
         handoffEnvKey: "steam://rungameid/\(appID)",
         steamLauncherEnvKey: steamLauncher.path]
    }

    /// Prepares `macOSDir` (a game app's `Contents/MacOS`) for the loader of `unixDir` (`<runtime>/lib/wine/x86_64-unix`):
    /// every sibling symlinked, and — unless the loader there is already this runtime's for this identity — a private
    /// copy of the loader whose embedded plist carries the game's identity and Game Mode (`EmbeddedInfoPlist`),
    /// left unsigned beside it. A private copy, not a link: the runtime's own loader is never modified.
    public static func stage(unixDir: URL, in macOSDir: URL, identifier: String, name: String,
                             fileManager: FileManager = .default) throws -> Staged {
        let source = unixDir.appendingPathComponent(loaderName)
        let loader = macOSDir.appendingPathComponent(loaderName)
        try fileManager.createDirectory(at: macOSDir, withIntermediateDirectories: true)

        // The siblings: one symlink per entry of the runtime's unix dir; drop ours that point elsewhere.
        let wanted = try fileManager.contentsOfDirectory(atPath: unixDir.path).filter { $0 != loaderName }
        for entry in try fileManager.contentsOfDirectory(atPath: macOSDir.path) {
            let item = macOSDir.appendingPathComponent(entry)
            guard let target = try? fileManager.destinationOfSymbolicLink(atPath: item.path) else { continue }
            if target != unixDir.appendingPathComponent(entry).path { try fileManager.removeItem(at: item) }
        }
        for entry in wanted {
            let link = macOSDir.appendingPathComponent(entry)
            if (try? fileManager.destinationOfSymbolicLink(atPath: link.path)) != nil { continue }
            if fileManager.fileExists(atPath: link.path) { continue }   // never replace a real file of ours
            try fileManager.createSymbolicLink(at: link, withDestinationURL: unixDir.appendingPathComponent(entry))
        }

        // The loader: rebuilt only when the runtime's loader or the identity changed.
        let marker = markerURL(macOSDir: macOSDir)
        try? fileManager.removeItem(at: macOSDir.appendingPathComponent(sourceMarkerName))   // where it was before
        let stamp = try sourceStamp(source, identifier: identifier, name: name, fileManager: fileManager)
        if fileManager.fileExists(atPath: loader.path),
           (try? String(contentsOf: marker, encoding: .utf8)) == stamp { return Staged(loader: loader, unsigned: nil) }
        let patched = try EmbeddedInfoPlist.rewrite(
            Data(contentsOf: source), entries: EmbeddedInfoPlist.gameEntries(identifier: identifier, name: name))
        let temp = macOSDir.appendingPathComponent(".\(loaderName).silo-\(UUID().uuidString)")
        try patched.write(to: temp)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: temp.path)
        try? fileManager.removeItem(at: marker)
        return Staged(loader: loader, unsigned: temp)
    }

    /// Puts a signed `stage` copy in place of the loader and records what it was built from.
    public static func install(_ staged: Staged, unixDir: URL, identifier: String, name: String,
                               fileManager: FileManager = .default) throws {
        guard let unsigned = staged.unsigned else { return }
        if fileManager.fileExists(atPath: staged.loader.path) {
            _ = try fileManager.replaceItemAt(staged.loader, withItemAt: unsigned)
        } else {
            try fileManager.moveItem(at: unsigned, to: staged.loader)
        }
        let stamp = try sourceStamp(unixDir.appendingPathComponent(loaderName), identifier: identifier, name: name,
                                    fileManager: fileManager)
        let marker = markerURL(macOSDir: staged.loader.deletingLastPathComponent())
        try fileManager.createDirectory(at: marker.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(stamp.utf8).write(to: marker, options: .atomic)
    }

    /// What a staged loader was built from: the runtime loader's file identity and the game identity.
    static func sourceStamp(_ source: URL, identifier: String, name: String, fileManager: FileManager) throws -> String {
        let a = try fileManager.attributesOfItem(atPath: source.path)
        let inode = a[.systemFileNumber] as? Int ?? 0, size = a[.size] as? Int ?? 0
        let mtime = (a[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return "\(inode):\(size):\(mtime):\(identifier):\(name)"
    }

}
