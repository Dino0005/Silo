import Foundation

/// Wires stock macOS Steam to Silo for Windows games: the launcher script Steam runs as the game's "macOS
/// build", and the `appinfo.vdf` edits that point Steam at it (`AppInfoPatcher`).
///
/// Never touches Steam's files while the client runs — Steam keeps `appinfo.vdf` in memory and writes it back
/// on exit, so an edit made under a live client is silently lost (and could be half-read). Every edit is
/// preceded by a one-time backup of Steam's original cache.
public struct NativeSteamInstaller: Sendable {
    /// Folder (inside each library's `steamapps/common`) and file name of the launcher script. The appinfo
    /// launch entry points at it relative to the game's install dir, so a copy must sit in EVERY library.
    public static let runtimeFolder = "Silo Runtime"
    public static let launcherName = "silo-launch"
    /// The executable path stored in the launch entry.
    public static var launcherRelativePath: String { "../\(runtimeFolder)/\(launcherName)" }
    /// The argument that switches the Silo binary into its headless Steam-launch mode.
    public static let launchFlag = "--steam-launch"

    public enum Failure: Error, Equatable {
        case steamRunning
        case noAppInfoCache
    }

    /// The macOS Steam data folder, `~/Library/Application Support/Steam`.
    public let steamRoot: URL
    /// Where Silo keeps its own copy of Steam's untouched cache.
    public let backupDir: URL
    private let isSteamRunning: @Sendable () -> Bool

    public init(steamRoot: URL, backupDir: URL, isSteamRunning: @escaping @Sendable () -> Bool) {
        self.steamRoot = steamRoot
        self.backupDir = backupDir
        self.isSteamRunning = isSteamRunning
    }

    public var appInfoURL: URL { steamRoot.appendingPathComponent("appcache/appinfo.vdf") }
    public var originalBackupURL: URL { backupDir.appendingPathComponent("appinfo.orig.vdf") }

    /// The launcher script: hands Steam's arguments (and its working directory, the game's install dir) to
    /// the Silo binary. Rewritten on every install, so it follows Silo if the app is moved.
    public static func launcherScript(siloExecutable: URL) -> String {
        let quoted = siloExecutable.path.replacingOccurrences(of: "'", with: "'\\''")
        return """
            #!/bin/bash
            # Silo: Steam runs this as the "macOS build" of a Windows game. Written by Silo — do not edit.
            exec '\(quoted)' \(launchFlag) "$@"

            """
    }

    /// Steam's libraries, from `steamapps/libraryfolders.vdf`; the main one is always included.
    public func libraries(fileManager: FileManager = .default) -> [URL] {
        var roots = [steamRoot]
        let vdf = steamRoot.appendingPathComponent("steamapps/libraryfolders.vdf")
        if let text = try? String(contentsOf: vdf, encoding: .utf8),
           let folders = try? LibraryFoldersDecoder().decode(text: text) {
            for folder in folders where !roots.contains(where: { $0.standardizedFileURL == folder.path.standardizedFileURL }) {
                roots.append(folder.path)
            }
        }
        return roots
    }

    /// Writes the launcher into every reachable library. An unplugged external library is skipped (and
    /// returned), not created: its games simply can't start until it's back.
    @discardableResult
    public func installLauncher(siloExecutable: URL, fileManager: FileManager = .default) throws
        -> (installed: [URL], unreachable: [URL]) {
        let script = Data(Self.launcherScript(siloExecutable: siloExecutable).utf8)
        var installed: [URL] = [], unreachable: [URL] = []
        for library in libraries(fileManager: fileManager) {
            guard fileManager.fileExists(atPath: library.path) else { unreachable.append(library); continue }
            let dir = library.appendingPathComponent("steamapps/common/\(Self.runtimeFolder)", isDirectory: true)
            try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
            let file = dir.appendingPathComponent(Self.launcherName)
            try script.write(to: file, options: .atomic)
            try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
            installed.append(file)
        }
        return (installed, unreachable)
    }

    /// How one game should be patched.
    public struct GameRequest: Sendable, Equatable {
        public var appID: UInt32
        /// For a game that also has a macOS build: install the Windows one through Silo.
        public var preferWindows: Bool
        /// The bottle's Wine user folder relative to the home folder, for Steam Cloud; nil leaves cloud as is.
        public var cloudUserFolderFromHome: String?

        public init(appID: UInt32, preferWindows: Bool = false, cloudUserFolderFromHome: String? = nil) {
            self.appID = appID
            self.preferWindows = preferWindows
            self.cloudUserFolderFromHome = cloudUserFolderFromHome
        }
    }

    /// Patches Steam's cache for `games` (Steam must be closed). Games missing from the cache are skipped —
    /// Steam only caches apps it has seen, so a game not yet shown in the library appears on a later run.
    /// - Returns: per game, what changed (empty for a game left alone, e.g. a native Mac build).
    @discardableResult
    /// App ids installed in every reachable library, from their `steamapps/appmanifest_<id>.acf` files.
    public func installedAppIDs(fileManager: FileManager = .default) -> [UInt32] {
        var ids: Set<UInt32> = []
        for library in libraries(fileManager: fileManager) {
            let steamapps = library.appendingPathComponent("steamapps", isDirectory: true)
            for name in (try? fileManager.contentsOfDirectory(atPath: steamapps.path)) ?? []
            where name.hasPrefix("appmanifest_") && name.hasSuffix(".acf") {
                if let id = UInt32(name.dropFirst("appmanifest_".count).dropLast(".acf".count)) { ids.insert(id) }
            }
        }
        return ids.sorted()
    }

    /// The installed apps that are Windows games (`AppInfoPatcher.isWindowsGame`), read from Steam's cache.
    public func installedWindowsGameIDs(fileManager: FileManager = .default) throws -> Set<UInt32> {
        let cache = try AppInfoCache(contentsOf: appInfoURL)
        var ids: Set<UInt32> = []
        for id in installedAppIDs(fileManager: fileManager) {
            if let app = try cache.app(id), AppInfoPatcher.isWindowsGame(app.info) { ids.insert(id) }
        }
        return ids
    }

    /// Applies `AppInfoPatcher.protectWindowsInstall` to every installed app, so no Windows game in any library
    /// can be wiped by macOS Steam. Must run with Steam closed — before it starts (Silo's guard runs it after
    /// every Steam exit, because Steam writes `appinfo.vdf` back then). Writes nothing when nothing changed.
    /// Returns the apps it changed.
    @discardableResult
    public func protectInstalledWindowsGames(fileManager: FileManager = .default) throws -> [UInt32: AppInfoPatcher.Result] {
        guard !isSteamRunning() else { throw Failure.steamRunning }
        guard var data = try? Data(contentsOf: appInfoURL) else { throw Failure.noAppInfoCache }
        var results: [UInt32: AppInfoPatcher.Result] = [:]
        for id in installedAppIDs(fileManager: fileManager) {
            let cache = try AppInfoCache(data: data)
            guard var app = try cache.app(id) else { continue }
            let result = AppInfoPatcher.protectWindowsInstall(&app)
            guard result.changed else { continue }
            results[id] = result
            data = try cache.replacing(app)
        }
        guard !results.isEmpty else { return results }
        try fileManager.createDirectory(at: backupDir, withIntermediateDirectories: true)
        if !fileManager.fileExists(atPath: originalBackupURL.path) {
            try Data(contentsOf: appInfoURL).write(to: originalBackupURL, options: .atomic)
        }
        // Steam must not have started meanwhile: it would overwrite the file on exit anyway, and a half-read is worse.
        guard !isSteamRunning() else { throw Failure.steamRunning }
        try data.write(to: appInfoURL, options: .atomic)
        return results
    }

    public func patch(_ games: [GameRequest], fileManager: FileManager = .default) throws
        -> [UInt32: AppInfoPatcher.Result] {
        guard !isSteamRunning() else { throw Failure.steamRunning }
        guard var data = try? Data(contentsOf: appInfoURL) else { throw Failure.noAppInfoCache }
        try fileManager.createDirectory(at: backupDir, withIntermediateDirectories: true)
        if !fileManager.fileExists(atPath: originalBackupURL.path) {
            try data.write(to: originalBackupURL, options: .atomic)
        }
        var results: [UInt32: AppInfoPatcher.Result] = [:]
        for game in games {
            let cache = try AppInfoCache(data: data)
            guard var app = try cache.app(game.appID) else { continue }
            var result = AppInfoPatcher.enableSiloLaunch(&app, shim: Self.launcherRelativePath,
                                                         preferWindows: game.preferWindows)
            if result.changed || app.info.map("config")?.map("launch")?.map(AppInfoPatcher.entryKey) != nil {
                if let folder = game.cloudUserFolderFromHome {
                    result.changes += AppInfoPatcher.enableCloud(&app, userFolderFromHome: folder).changes
                }
            }
            results[game.appID] = result
            if result.changed { data = try cache.replacing(app) }
        }
        try data.write(to: appInfoURL, options: .atomic)
        return results
    }
}
