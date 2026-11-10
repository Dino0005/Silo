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
        /// `prepareInstall`: the app isn't in Steam's cache (Steam hasn't shown it yet).
        case notInCache(UInt32)
        /// `prepareInstall`: the app has a native Mac build, or no Windows one — nothing for Silo to install.
        case notAWindowsGame(UInt32)
        /// `prepareInstall`: the target library isn't mounted.
        case libraryUnreachable(URL)
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

    /// Puts back Steam's own entry for each app, taken from an untouched `appinfo.vdf` (e.g. `originalBackupURL`):
    /// undoes every Silo edit for those games. Only with Steam closed. Returns the ids restored; ids missing from
    /// either cache are skipped.
    /// ⚠️ An installed Windows game restored this way is unprotected until the guard's next pass.
    @discardableResult
    public func restoreOriginal(_ appIDs: [UInt32], from pristine: URL) throws -> [UInt32] {
        guard !isSteamRunning() else { throw Failure.steamRunning }
        guard var data = try? Data(contentsOf: appInfoURL) else { throw Failure.noAppInfoCache }
        let source = try AppInfoCache(contentsOf: pristine)
        var restored: [UInt32] = []
        for id in appIDs {
            guard let original = try source.app(id), try AppInfoCache(data: data).app(id) != nil else { continue }
            data = try AppInfoCache(data: data).replacing(original)
            restored.append(id)
        }
        if !restored.isEmpty { try data.write(to: appInfoURL, options: .atomic) }
        return restored
    }

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

    /// The two lists `SteamLibraryFilters` needs, over every app in Steam's cache (installed or not): Windows
    /// games with no Mac build of their own (`AppInfoPatcher.isWindowsGame`), and every app with a Windows build
    /// (`common.oslist` has `windows` — Silo only ever adds `macos`, so this is the original platform list).
    /// Readable while Steam runs (it rewrites the file as it goes).
    public func windowsGameIDsInCache() throws -> (windowsOnly: [UInt32], windowsBuild: [UInt32]) {
        let cache = try AppInfoCache(contentsOf: appInfoURL)
        var only: [UInt32] = [], build: [UInt32] = []
        for id in cache.appIDs {
            guard let info = try cache.app(id)?.info else { continue }
            if (info.map("common")?.string("oslist") ?? "").osList.contains("windows") { build.append(id) }
            if AppInfoPatcher.isWindowsGame(info) { only.append(id) }
        }
        return (only, build)
    }

    /// Windows games (`AppInfoPatcher.isWindowsGame`) Silo hasn't protected yet — `common.oslist` without `macos`,
    /// so stock macOS Steam refuses to install them ("Invalid platform"). Their Install goes through Silo
    /// (`SteamInstallWithSilo`). Readable while Steam runs.
    public func windowsGamesNeedingSilo() throws -> [UInt32] {
        let cache = try AppInfoCache(contentsOf: appInfoURL)
        return try cache.appIDs.filter { id in
            guard let info = try cache.app(id)?.info, AppInfoPatcher.isWindowsGame(info) else { return false }
            return !(info.map("common")?.string("oslist") ?? "").osList.contains("macos")
        }
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

    /// Applies `AppInfoPatcher.protectWindowsInstall` and Silo's launch entry (`enableSiloLaunch`) to every
    /// installed Windows game, so none can be wiped by macOS Steam and Play runs each through Silo. Must run with Steam closed — before it starts (Silo's guard runs it after
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
            // Protection, then Silo's launch entry: a protected game without it makes Steam exec the Windows exe
            // on Play ("OS Error 0", FATAL FURY 2026-11-10). Cloud rules are left alone (per game, later).
            var result = AppInfoPatcher.protectWindowsInstall(&app)
            if AppInfoPatcher.isWindowsGame(app.info) {
                result.changes += AppInfoPatcher.enableSiloLaunch(&app, shim: Self.launcherRelativePath).changes
            }
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

    /// Where a new game goes by default: the first reachable library besides Steam's own folder (games live on
    /// the external drive, not the Mac's disk), else Steam's own folder.
    public func defaultGameLibrary(fileManager: FileManager = .default) -> URL {
        libraries(fileManager: fileManager).dropFirst().first { fileManager.fileExists(atPath: $0.path) } ?? steamRoot
    }

    /// What `prepareInstall` did.
    public enum PrepareOutcome: Sendable, Equatable {
        /// A new placeholder manifest, plus the protection / launch-entry changes (empty if already protected).
        case prepared(manifest: URL, changes: [String])
        /// A library already holds a manifest for the app; nothing was written there.
        case alreadyInLibrary(URL)
    }

    /// Readies a Windows game that isn't installed for download into `library` (Steam must be closed): writes a
    /// placeholder `appmanifest_<id>.acf` there — Steam reads manifests only at start and then updates the app
    /// in the library that holds it (`app_install` itself always uses Steam's own folder, measured 2026-11-10) —
    /// and protects + enables the game like the guard does, so the next Steam start downloads the Windows depots
    /// as an ordinary update, visible and pausable in Steam's Downloads panel.
    @discardableResult
    public func prepareInstall(_ appID: UInt32, in library: URL, fileManager: FileManager = .default) throws
        -> PrepareOutcome {
        guard !isSteamRunning() else { throw Failure.steamRunning }
        let name = "appmanifest_\(appID).acf"
        if let existing = libraries(fileManager: fileManager)
            .map({ $0.appendingPathComponent("steamapps/\(name)") })
            .first(where: { fileManager.fileExists(atPath: $0.path) }) {
            return .alreadyInLibrary(existing)
        }
        guard fileManager.fileExists(atPath: library.path) else { throw Failure.libraryUnreachable(library) }
        guard let data = try? Data(contentsOf: appInfoURL) else { throw Failure.noAppInfoCache }
        guard let app = try AppInfoCache(data: data).app(appID) else { throw Failure.notInCache(appID) }
        guard AppInfoPatcher.isWindowsGame(app.info) else { throw Failure.notAWindowsGame(appID) }
        let title = app.info.map("common")?.string("name") ?? "App \(appID)"
        let installDir = app.info.map("config")?.string("installdir") ?? title
        let steamapps = library.appendingPathComponent("steamapps", isDirectory: true)
        try fileManager.createDirectory(at: steamapps, withIntermediateDirectories: true)
        let manifest = steamapps.appendingPathComponent(name)
        try Data(Self.placeholderManifest(appID: appID, name: title, installDir: installDir).utf8)
            .write(to: manifest, options: .atomic)
        let changes = try protectInstalledWindowsGames(fileManager: fileManager)[appID]?.changes ?? []
        return .prepared(manifest: manifest, changes: changes)
    }

    /// The smallest manifest Steam accepts as "update required" for an app with nothing on disk yet.
    static func placeholderManifest(appID: UInt32, name: String, installDir: String) -> String {
        func quoted(_ s: String) -> String {
            "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        return """
            "AppState"
            {
            \t"appid"\t\t\(quoted(String(appID)))
            \t"universe"\t\t"1"
            \t"name"\t\t\(quoted(name))
            \t"StateFlags"\t\t"2"
            \t"installdir"\t\t\(quoted(installDir))
            \t"SizeOnDisk"\t\t"0"
            \t"buildid"\t\t"0"
            \t"AutoUpdateBehavior"\t\t"0"
            \t"InstalledDepots"
            \t{
            \t}
            }

            """
    }

    /// Patches Steam's cache for `games` (Steam must be closed). Games missing from the cache are skipped —
    /// Steam only caches apps it has seen, so a game not yet shown in the library appears on a later run.
    /// - Returns: per game, what changed (empty for a game left alone, e.g. a native Mac build).
    @discardableResult
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
