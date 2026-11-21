import Foundation

/// The "Steam per macOS" switch in Settings (user, 2026-11-13): everything Silo puts around macOS Steam, installed or
/// removed in one go.
///
/// **On** — `~/Applications/Steam (Silo).app` (`SteamLauncherApp`, signed ad-hoc only when it changed, so the privacy
/// grant survives), the "silo" compatibility tool (`SiloCompatTool`), the launch script in every Steam library
/// (`NativeSteamInstaller.installLauncher`) and the guard LaunchAgent (`NativeSteamGuard`).
///
/// **Off** — the launcher app, Silo's tools, the games' mappings to them, the debug-port marker and the game apps go; the
/// guard stays as **protection only** (user's rule): while the library with the Windows games is still configured in
/// macOS Steam, stock Steam would delete unprotected games (2026-11-08/09), so the guard keeps protecting them — and the
/// launch scripts they point at stay too — until the user removes that library from Steam. Then the guard retires
/// itself (`retire`). An unplugged library still counts as configured. The bottles are never removed here: only
/// `deleteBottles`, a separate button with a warning (they hold the saves of games without Steam Cloud).
public struct NativeSteamSetup: Sendable {
    /// The on/off state: a file in Silo's support folder, read by the guard at every pass.
    public static let markerName = "native-steam-enabled"
    /// What every script and tool Silo writes for Steam says about itself.
    static let writtenBySilo = "Written by Silo"

    public enum Failure: Error, Equatable {
        /// Steam has to be closed: the off switch edits `config.vdf`, which Steam rewrites on exit.
        case steamRunning
        /// A `swift run` build has no Silo.app to copy the launcher and the libraries from.
        case notAnApp
        /// The bottles are in use, or Steam per macOS is still on.
        case bottlesInUse
        /// macOS Steam isn't on this Mac: nothing to put Silo around.
        case steamNotInstalled
    }

    public struct Status: Sendable, Equatable {
        public var enabled = false
        /// Whether macOS Steam is on this Mac (`isSteamInstalled`); the switch can only be turned on when it is.
        public var steamInstalled = false
        public var launcherApp = false
        public var tool = false
        public var guardAgent = false
        /// Games Steam maps to Silo's tool.
        public var gamesOnTool = 0
        public var bottles = false
        /// Whether a game started from Steam finds the bridge (lsteamclient + the stand-in steam.exe) in the Wine
        /// runtime Silo uses — a runtime from before the bridge was built in has none, and the game then doesn't open.
        /// nil while no Wine is set up.
        public var wineBridge: Bool?
        public init() {}
    }

    public let paths: AppPaths
    public let steamRoot: URL
    public let home: URL
    /// The running Silo.app.
    public let siloApp: URL
    private let runner: ProcessRunning
    private let isSteamRunning: @Sendable () -> Bool
    /// The Mac's Applications folder, where Valve's installer puts `Steam.app`.
    let systemApplicationsDir: URL

    public init(paths: AppPaths = .standard(), runner: ProcessRunning = SystemProcessRunner(),
                home: URL = FileManager.default.homeDirectoryForCurrentUser,
                siloApp: URL = Bundle.main.bundleURL,
                systemApplicationsDir: URL = URL(fileURLWithPath: "/Applications", isDirectory: true),
                isSteamRunning: @escaping @Sendable () -> Bool = { MacSteamProcess.isRunning() }) {
        self.paths = paths
        self.systemApplicationsDir = systemApplicationsDir
        self.runner = runner
        self.home = home
        self.steamRoot = home.appendingPathComponent("Library/Application Support/Steam", isDirectory: true)
        self.siloApp = siloApp
        self.isSteamRunning = isSteamRunning
    }

    var marker: URL { paths.supportDir.appendingPathComponent(Self.markerName) }
    var applicationsDir: URL { home.appendingPathComponent("Applications", isDirectory: true) }
    public var launcherAppURL: URL { applicationsDir.appendingPathComponent(SteamLauncherApp.fileName, isDirectory: true) }
    var toolsDir: URL { steamRoot.appendingPathComponent("compatibilitytools.d", isDirectory: true) }
    var configVDF: URL { steamRoot.appendingPathComponent("config/config.vdf") }
    var guardAgentURL: URL { NativeSteamGuard.launchAgentURL(home: home) }
    var siloExecutable: URL { siloApp.appendingPathComponent("Contents/MacOS/Silo") }
    var installer: NativeSteamInstaller {
        NativeSteamInstaller(steamRoot: steamRoot, backupDir: paths.supportDir.appendingPathComponent("NativeSteam"),
                             isSteamRunning: isSteamRunning)
    }

    public var isEnabled: Bool { FileManager.default.fileExists(atPath: marker.path) }

    /// Whether macOS Steam is on this Mac: Valve's `Steam.app` in /Applications or ~/Applications, or the client it
    /// downloads at its first start (what "Steam (Silo)" starts).
    public func isSteamInstalled(fileManager: FileManager = .default) -> Bool {
        [systemApplicationsDir.appendingPathComponent("Steam.app"), applicationsDir.appendingPathComponent("Steam.app"),
         steamRoot.appendingPathComponent("Steam.AppBundle/Steam/Contents/MacOS/steam_osx")]
            .contains { fileManager.fileExists(atPath: $0.path) }
    }

    /// Whether a launch finds the bridge for `wine`: the same lookup the launch makes (`NativeSteamBottle.bridgeSource`),
    /// the runtime first, then the development folder. nil without a Wine.
    public func bridgeReady(wine: URL?, fileManager: FileManager = .default) -> Bool? {
        guard let wine else { return nil }
        let source = NativeSteamBottle(paths: paths, runner: runner).bridgeSource(wine: wine, fileManager: fileManager)
        return NativeSteamBottle.missingBridgeFiles(in: source, fileManager: fileManager).isEmpty
    }

    /// The Wine binary Silo launches with, from `config.json` (read here, not through `ConfigStore`, so the status
    /// stays synchronous; the store writes the file atomically).
    func configuredWine() -> URL? {
        (try? Data(contentsOf: paths.configFile))
            .flatMap { try? JSONDecoder().decode(AppState.self, from: $0) }?.backend.wineBinaryPath
    }

    public func status(fileManager: FileManager = .default) -> Status {
        var status = Status()
        status.enabled = isEnabled
        status.steamInstalled = isSteamInstalled(fileManager: fileManager)
        status.launcherApp = fileManager.fileExists(atPath: launcherAppURL.path)
        status.tool = SteamCompatMapping.installedTools(in: toolsDir, fileManager: fileManager).contains(SiloCompatTool.name)
        status.guardAgent = fileManager.fileExists(atPath: guardAgentURL.path)
        let config = (try? String(contentsOf: configVDF, encoding: .utf8)) ?? ""
        status.gamesOnTool = SteamCompatMapping.mappings(configVDF: config)
            .filter { $0.value == SiloCompatTool.name && !SteamCompatMapping.notGames.contains($0.key) }.count
        status.wineBridge = bridgeReady(wine: configuredWine(), fileManager: fileManager)
        status.bottles = [paths.nativeSteamBottle, paths.nativeSteamBottleMF].contains {
            fileManager.fileExists(atPath: $0.path)
        }
        return status
    }

    // MARK: - Moved or replaced Silo

    /// What Steam for macOS still runs from ANOTHER Silo.app (this one was moved, or replaced by a new version in
    /// another place): Steam's "Silo" tool, the guard's LaunchAgent, "Steam (Silo)". Each holds the app's path, so after
    /// a move the games stop starting from Steam and the guard stops protecting. Empty when everything is this app's.
    public func partsFromAnotherSilo(fileManager: FileManager = .default) -> [String] {
        var parts: [String] = []
        let run = toolsDir.appendingPathComponent(SiloCompatTool.name).appendingPathComponent("run")
        // Also when the tool still sits under an earlier id (an older Silo wrote it): rewriting moves its games over.
        let legacyLeft = SiloCompatTool.legacyNames.contains {
            (try? String(contentsOf: toolsDir.appendingPathComponent("\($0)/run"), encoding: .utf8))?
                .contains("# Written by Silo") == true
        }
        if legacyLeft
            || (try? String(contentsOf: run, encoding: .utf8)) != SiloCompatTool(siloExecutable: siloExecutable).runScript() {
            parts.append("compatibility tool")
        }
        let agent = (try? Data(contentsOf: guardAgentURL))
            .flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any] }
        if (agent?["ProgramArguments"] as? [String])?.first != siloExecutable.path { parts.append("guard") }
        if let launcher = SteamLauncherApp(appBundle: siloApp, fileManager: fileManager),
           !launcher.isCurrent(in: applicationsDir, fileManager: fileManager) {
            parts.append("Steam (Silo)")
        }
        return parts
    }

    /// At Silo's start: with Steam for macOS on and this Silo an app, points everything back at this app when any part
    /// still runs another copy (`enable()` again — it rewrites the tool, the launch scripts, the guard, and "Steam (Silo)"
    /// only if it changed). Returns what `enable()` did, or nothing when no part pointed elsewhere.
    public func repointIfMoved(fileManager: FileManager = .default) async throws -> [String] {
        guard isEnabled, SteamLauncherApp(appBundle: siloApp, fileManager: fileManager) != nil,
              !partsFromAnotherSilo(fileManager: fileManager).isEmpty else { return [] }
        return try await enable(fileManager: fileManager)
    }

    /// Whether `enable()`'s report says "Steam (Silo)" was rewritten — its privacy grant must then be given again.
    public static func launcherRewritten(_ done: [String]) -> Bool { done.contains { $0.hasPrefix("Steam (Silo) written") } }

    // MARK: - On

    /// Installs everything. Steam may be open: the tool and the launcher count from its next start through
    /// "Steam (Silo)". Returns what was done, one line each.
    @discardableResult
    public func enable(fileManager: FileManager = .default) async throws -> [String] {
        guard let launcher = SteamLauncherApp(appBundle: siloApp, fileManager: fileManager) else { throw Failure.notAnApp }
        guard isSteamInstalled(fileManager: fileManager) else { throw Failure.steamNotInstalled }
        var done: [String] = []
        try fileManager.createDirectory(at: paths.supportDir, withIntermediateDirectories: true)
        fileManager.createFile(atPath: marker.path, contents: Data())
        try SiloCompatTool(siloExecutable: siloExecutable).write(steamRoot: steamRoot, fileManager: fileManager)
        done.append("compatibility tool")
        if !launcher.isCurrent(in: applicationsDir, fileManager: fileManager) {
            try fileManager.createDirectory(at: applicationsDir, withIntermediateDirectories: true)
            let app = try launcher.write(into: applicationsDir, fileManager: fileManager)
            _ = try await runner.run(executable: URL(fileURLWithPath: "/usr/bin/codesign"),
                                     arguments: ["--force", "--sign", "-", app.path], environment: [:], currentDirectory: nil)
            // A grant given to the earlier signature stays listed as on but no longer counts (Steam Input then silently
            // gets no virtual pad); clear it, so the request below asks afresh (NotProton does the same for Steam).
            _ = try? await runner.run(executable: URL(fileURLWithPath: "/usr/bin/tccutil"),
                                      arguments: ["reset", SteamLauncherApp.privacyService, SteamLauncherApp.bundleIdentifier],
                                      environment: [:], currentDirectory: nil)
            done.append("Steam (Silo) written — authorize it in Privacy & Security")
        }
        // "Steam (Silo)" asks macOS for its grant now (prompt + listed in Privacy & Security, switched off), not at the
        // user's first Steam start; a no-op when it has it. Started through LaunchServices, so the request is its own.
        _ = try? await runner.run(executable: URL(fileURLWithPath: "/usr/bin/open"),
                                  arguments: ["-n", launcherAppURL.path, "--args", SteamLauncherApp.requestAccessFlag],
                                  environment: [:], currentDirectory: nil)
        let scripts = try installer.installLauncher(siloExecutable: siloExecutable, fileManager: fileManager)
        done.append("launch script in \(scripts.installed.count) libraries")
        try await installGuard(fileManager: fileManager)
        done.append("guard")
        return done
    }

    /// Writes the guard's LaunchAgent for this Silo and (re)starts it.
    public func installGuard(fileManager: FileManager = .default) async throws {
        try fileManager.createDirectory(at: guardAgentURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: paths.logsDir, withIntermediateDirectories: true)
        try NativeSteamGuard.launchAgentPlist(
            siloExecutable: siloExecutable, logURL: paths.logsDir.appendingPathComponent("native-steam-guard.log"))
            .write(to: guardAgentURL, options: .atomic)
        let launchctl = URL(fileURLWithPath: "/bin/launchctl")
        let domain = "gui/\(getuid())"
        _ = try? await runner.run(executable: launchctl, arguments: ["bootout", "\(domain)/\(NativeSteamGuard.label)"],
                                  environment: [:], currentDirectory: nil)
        // bootout returns before launchd has finished removing the old job; bootstrap fails (EIO) until it has.
        for attempt in 0..<10 {
            let result = try await runner.run(executable: launchctl, arguments: ["bootstrap", domain, guardAgentURL.path],
                                              environment: [:], currentDirectory: nil)
            if result.succeeded || attempt == 9 { break }
            try? await Task.sleep(for: .milliseconds(500))
        }
    }

    // MARK: - Off

    /// Removes everything but the protection (see the type's comment). Steam must be closed.
    @discardableResult
    public func disable(fileManager: FileManager = .default) async throws -> [String] {
        guard !isSteamRunning() else { throw Failure.steamRunning }
        var done: [String] = []
        try? fileManager.removeItem(at: marker)
        if fileManager.fileExists(atPath: launcherAppURL.path) {
            try fileManager.removeItem(at: launcherAppURL)
            done.append("Steam (Silo) removed")
        }
        let tools = Self.siloTools(in: toolsDir, fileManager: fileManager)
        for tool in tools { try fileManager.removeItem(at: tool) }
        let names = tools.reduce(into: Set([SiloCompatTool.name] + SiloCompatTool.legacyNames)) { $0.formUnion(SteamCompatMapping.toolNames(inToolDir: $1)) }
        if let text = try? String(contentsOf: configVDF, encoding: .utf8) {
            let cleaned = SteamCompatMapping.removingMappings(to: names, in: text)
            if cleaned != text { try Data(cleaned.utf8).write(to: configVDF, options: .atomic) }
        }
        done.append("\(tools.count) compatibility tool(s) and their mappings removed")
        try? fileManager.removeItem(at: SteamLibraryFilters.debugPortMarker(steamRoot: steamRoot))
        try? fileManager.removeItem(at: paths.gameAppsDir)
        // The guard re-reads the switch at its next pass; restarting it makes that now.
        _ = try? await runner.run(executable: URL(fileURLWithPath: "/bin/launchctl"),
                                  arguments: ["kickstart", "-k", "gui/\(getuid())/\(NativeSteamGuard.label)"],
                                  environment: [:], currentDirectory: nil)
        return done
    }

    /// The tools in `compatibilitytools.d` that Silo wrote (their `run` says so) — "silo" and lab copies of it.
    static func siloTools(in toolsDir: URL, fileManager: FileManager = .default) -> [URL] {
        ((try? fileManager.contentsOfDirectory(at: toolsDir, includingPropertiesForKeys: nil)) ?? []).filter {
            ((try? String(contentsOf: $0.appendingPathComponent("run"), encoding: .utf8)) ?? "").contains(writtenBySilo)
        }.sorted { $0.path < $1.path }
    }

    // MARK: - Protection only

    /// Pure: whether the guard still has games to protect — any configured library unreachable (an unplugged disk may
    /// hold Windows games: retiring then would let Steam wipe them when it's back), or any Windows game installed.
    public static func protectionNeeded(libraries: [URL], windowsGamesInstalled: Bool,
                                        isReachable: (URL) -> Bool) -> Bool {
        windowsGamesInstalled || libraries.contains { !isReachable($0) }
    }

    /// Whether the guard, with the switch off, still has to protect.
    public func protectionNeeded(fileManager: FileManager = .default) -> Bool {
        let installer = self.installer
        let windows = (try? installer.installedWindowsGameIDs(fileManager: fileManager))?.isEmpty == false
        return Self.protectionNeeded(libraries: installer.libraries(fileManager: fileManager), windowsGamesInstalled: windows,
                                     isReachable: { fileManager.fileExists(atPath: $0.path) })
    }

    /// The guard's last act once nothing is left to protect: the launch scripts and its own LaunchAgent go.
    public func retire(fileManager: FileManager = .default) async {
        for library in installer.libraries(fileManager: fileManager) {
            let dir = library.appendingPathComponent("steamapps/common/\(NativeSteamInstaller.runtimeFolder)")
            let script = dir.appendingPathComponent(NativeSteamInstaller.launcherName)
            if ((try? String(contentsOf: script, encoding: .utf8)) ?? "").contains("Written by Silo") {
                try? fileManager.removeItem(at: dir)
            }
        }
        try? fileManager.removeItem(at: guardAgentURL)
        _ = try? await runner.run(executable: URL(fileURLWithPath: "/bin/launchctl"),
                                  arguments: ["bootout", "gui/\(getuid())/\(NativeSteamGuard.label)"],
                                  environment: [:], currentDirectory: nil)
    }

    // MARK: - Bottles

    /// Deletes SteamNative and SteamNativeMF — only with the switch off, Steam closed and nothing running in them.
    public func deleteBottles(fileManager: FileManager = .default) throws {
        let bottles = [paths.nativeSteamBottle, paths.nativeSteamBottleMF]
        guard !isEnabled, !isSteamRunning(),
              !bottles.contains(where: { WineServerProbe.isLive(prefix: $0, fileManager: fileManager) })
        else { throw Failure.bottlesInUse }
        for bottle in bottles where fileManager.fileExists(atPath: bottle.path) { try fileManager.removeItem(at: bottle) }
    }
}
