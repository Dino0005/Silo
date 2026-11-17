import Foundation

/// Silo's headless launch for a Windows game started from macOS Steam's Play button (`silo-launch` →
/// `Silo --steam-launch …`). Same choices as the library's Play (`GameLibraryViewModel.play`) — the game's
/// saved config, the graphics backend, the alt-loader host for the right Dock icon — but in the dedicated
/// `NativeSteamBottle`, through `NativeSteamBridge`, with no Windows Steam to bring up.
///
/// It stays alive until the game ends: Steam treats this process as the game, so "Running", the Stop button,
/// playtime and the Steam Cloud upload on exit all follow its lifetime.
public struct NativeSteamLauncher: Sendable {
    public let paths: AppPaths
    private let runner: ProcessRunning
    private let pollInterval: Duration

    /// Steam's environment for the game (its controller lists, `SDL_GAMECONTROLLER_IGNORE_DEVICES`).
    private let environment: [String: String]
    /// `silo-game-loader.dylib` of the running app (`GameAppLoader.injector`); nil keeps the alt-loader host.
    private let injectorURL: URL?
    /// `silo-overlay-fix.dylib` of the running app (`SteamOverlayFix`); nil leaves Steam's overlay as it is.
    private let overlayFix: URL?
    /// Steam's `logs/content_log.txt`, where its Stop shows up (`SteamStopWatch`).
    private let steamContentLog: URL

    public init(paths: AppPaths = .standard(), runner: ProcessRunning = SystemProcessRunner(),
                pollInterval: Duration = .seconds(1),
                environment: [String: String] = ProcessInfo.processInfo.environment,
                injector: URL? = GameAppLoader.injector(),
                overlayFix: URL? = SteamOverlayFix.library(),
                steamContentLog: URL = SteamStopWatch(appID: 0).log) {
        self.paths = paths
        self.runner = runner
        self.pollInterval = pollInterval
        self.environment = environment
        self.injectorURL = injector
        self.overlayFix = overlayFix
        self.steamContentLog = steamContentLog
    }

    public enum Failure: Error, Equatable {
        case noManifest(URL)
        case executableNotFound
        case refused(String)
    }

    /// Launches and waits. Returns the process exit status Steam sees (0 once the game has run).
    public func run(_ request: NativeSteamLaunchRequest, log: (String) -> Void = { _ in }) async throws -> Int32 {
        let state = await ConfigStore(paths: paths).load()
        let backend = state.backend
        let config = state.config(for: request.appID)
        let app = try Self.steamApp(for: request)

        // Steam Input's virtual pad always reaches the game as an Xbox 360 pad: Steam's description of it is dropped.
        // Wine inherits this process's environment, so it is removed from that too, not only from the bridge's copy.
        let environment = NativeSteamBridge.withoutVirtualGamepadInfo(self.environment)
        for key in [NativeSteamBridge.virtualGamepadInfoKey] + NativeSteamBridge.protonOnlyKeys { unsetenv(key) }
        log("steam input virtual pad: Xbox")

        // Steam's overlay + virtual-gamepad libraries, as Steam hands them to a macOS game — given to every Wine
        // command of this launch (`SteamLibrariesRunner`), not only the game's own.
        var overlay = NativeSteamBridge.overlayLibraries(
            fromSteam: environment["STEAM_DYLD_INSERT_LIBRARIES"],
            clientInstallPath: NativeSteamBridge.defaultClientInstallPath())
        overlay = SteamOverlayFix.adding(overlayFix, to: overlay)
        log("steam libraries: " + (overlay.isEmpty ? "none" : overlay.map(\.lastPathComponent).joined(separator: ", ")))
        let steamClientRoot = NativeSteamBridge.defaultClientInstallPath()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        guard let exe = request.executable.flatMap({ FileManager.default.fileExists(atPath: $0.path) ? $0 : nil })
            ?? LaunchOrchestrator(runner: self.runner, linker: GraphicsLinker(), steamClientRoot: steamClientRoot)
                .resolvedExecutable(app: app, config: config) else {
            throw Failure.executableNotFound
        }

        // The backend exactly as Play picks it (`GameLibraryViewModel.play`).
        let is32 = WindowsExecutable.is32Bit(exe)
        var learned = config.learnedUnderRuntime == backend.gptkRuntimeName ? config.learnedBackend : nil
        if let hint = learned, backend.libDir(for: hint) == nil { learned = nil }
        let chosen = BackendChooser.choose(config.graphics, is32Bit: is32, learned: learned)
        if let refusal = GameLibraryViewModel.bitnessRefusal(
            name: app.name, choice: config.graphics, chosen: chosen, is32: is32,
            dxmtConfigured: backend.libDir(for: .dxmt) != nil, dxmtSupports32Bit: backend.dxmtSupports32Bit) {
            throw Failure.refused(refusal)
        }

        let context = try BottleResolver(paths: paths).steam(backend: chosen, config: backend)

        // The game's identity: Wine's loader inside the game's own .app (`GameAppLoader`), so every process of the
        // game — a relaunch included — carries its name and icon. Without the injected library (a `swift run`
        // build) or if staging fails, the alt-loader host does it as before.
        let target = AltLoaderSession.Target(gameName: app.name, gameID: String(app.appID),
                                             hostAppsDir: paths.hostAppsDir, playLink: .playSteam(appID: app.appID))
        var gameApp: [String: String]?
        if let injector = injectorURL {
            gameApp = await LaunchOrchestrator(runner: self.runner, linker: GraphicsLinker(), steamClientRoot: steamClientRoot)
                .prepareGameApp(name: app.name, id: String(app.appID), gameAppsDir: paths.gameAppsDir,
                                gameExe: exe, app: app, wine: context.wineBinary)
            if gameApp != nil { overlay.insert(injector, at: 0) }
        }
        log(gameApp.map { "game app: \($0[GameAppLoader.loaderEnvKey] ?? "") for \($0[GameAppLoader.executablesEnvKey] ?? "")" }
            ?? "game app: none, the alt-loader host carries the icon")
        let runner: ProcessRunning = overlay.isEmpty ? self.runner
            : SteamLibrariesRunner(base: self.runner, libraries: overlay.map(\.path).joined(separator: ":"),
                                   extraEnvironment: gameApp ?? [:])
        let orchestrator = LaunchOrchestrator(runner: runner, linker: GraphicsLinker(), steamClientRoot: steamClientRoot)
        // Native Media Foundation as in the library's Play: only with a ready MF bottle built under this Wine.
        let mediaFoundation = config.envFlags.mediaFoundationNative
            && Self.mediaFoundationReady(paths: paths, currentRuntime: backend.wineRuntimeName)
        if config.envFlags.mediaFoundationNative, !mediaFoundation {
            log("Media Foundation bottle missing or built under another Wine: using the normal bottle")
        }
        let bottle = NativeSteamBottle(paths: paths, runner: runner, mediaFoundation: mediaFoundation)
        log("bottle \(bottle.prefix.path), backend \(chosen), wine \(context.wineBinary.path)")
        let source = bottle.bridgeSource(wine: context.wineBinary)
        log("bridge from \(source)")
        try await bottle.ensureBottle(source: source)
        if case .devFolder = source { try bottle.stageRuntime(wine: context.wineBinary) }

        // Steam Cloud: this game's save folders (named by its Steam Cloud rules) are the classic SteamBottle's — backed
        // up once before the first such launch, and a copy this bottle held on its own is kept in the backup.
        let appInfo = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Steam/appcache/appinfo.vdf")
        let folders = SteamCloudSaves.folders(savefiles: (try? AppInfoCache(contentsOf: appInfo).app(UInt32(app.appID)))??
            .info.map("ufs")?.map("savefiles"))
        // Steam resolves the cloud roots of a compat-tool launch in the game's compatdata: linked to the classic bottle
        // (the guard does it after each Steam session; this covers a game installed meanwhile).
        if let compatData = environment["STEAM_COMPAT_DATA_PATH"], !compatData.isEmpty,
           let canonicalUser = SharedSaveLinker().windowsUserDir(inPrefix: paths.steamBottle) {
            let data = URL(fileURLWithPath: compatData, isDirectory: true)
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
            for line in SteamCloudSaves.prepareCompatUser(
                compatData: data, canonicalUser: canonicalUser,
                backupDir: data.deletingLastPathComponent().deletingLastPathComponent()
                    .appendingPathComponent("silo-backups/compatdata-\(app.appID)-\(stamp)")) {
                log("saves: \(line)")
            }
        }
        if !folders.isEmpty {
            let backups = paths.supportDir.appendingPathComponent("Backups/steam-cloud/\(app.appID)", isDirectory: true)
            let linker = SharedSaveLinker()
            if linker.backUpOnce(folders, canonical: paths.steamBottle,
                                 backupDir: backups.appendingPathComponent("before-first-cloud-launch")) {
                log("saves: SteamBottle's \(folders.map { $0.name }.joined(separator: ", ")) backed up before the first cloud launch")
            }
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
            for line in linker.linkToCanonical(folders, bottle: bottle.prefix, canonical: paths.steamBottle,
                                               backupDir: backups.appendingPathComponent(stamp)) {
                log("saves: \(line)")
            }
        }

        // Steam Input's pads stay Steam's: hidden from Wine's hidraw path unless the game reads them directly.
        if let line = await SteamInputControllers.apply(
            environment: environment, flags: config.envFlags, prefix: bottle.prefix, wine: context.wineBinary,
            runner: runner) {
            log(line)
        }

        // What Windows Steam would do on first launch and macOS Steam never does: the game's install script.
        for outcome in await SteamInstallScriptRunner(runner: runner).run(
            appID: app.appID, installDir: app.installURL, prefix: bottle.prefix, wine: context.wineBinary) {
            switch outcome {
            case .ran(let step, let code): log("install script \"\(step)\": exit \(code)")
            case .skipped: break
            }
        }

        let pid = try await orchestrator.launchInBottle(
            app: app, config: config, backend: backend, graphics: chosen,
            wine: context.wineBinary, prefix: bottle.prefix,
            logURL: paths.log(forAppID: app.appID), gameExe: exe,
            altLoaderTarget: gameApp == nil ? target : nil,
            steamBridge: NativeSteamBridge(
                clientInstallPath: NativeSteamBridge.defaultClientInstallPath(),
                nativeVCRuntime: NativeSteamBridge.nativeVCRuntime(
                    inSystem32: bottle.prefix.appendingPathComponent("drive_c/windows/system32")),
                overlayLibraries: overlay, steamEnvironment: environment))
        log("started \(app.name) (pid \(pid))")
        _ = try? await ConfigStore(paths: paths).updateGame(appID: app.appID) { $0.lastPlayed = Date() }

        // The wine launcher lives as long as the stand-in client, which waits for the game. Meanwhile the guard
        // keeps away from Steam's UI.
        let playing = NativeSteamPlaying(paths: paths)
        playing.begin(appID: app.appID)
        defer { playing.end(appID: app.appID) }
        // Steam's Stop reaches no process of ours: Silo watches Steam's log for it (`SteamStopWatch`) and ends the game —
        // a quit request first, then SIGTERM and Wine's own shutdown of the bottle if it is still there 10 s later.
        var stopWatch = SteamStopWatch(log: steamContentLog, appID: app.appID)
        let clock = ContinuousClock()
        var stopAsked: ContinuousClock.Instant?
        var forced = false
        while runner.isRunning(pid: pid) {
            if stopAsked == nil, stopWatch.stopRequested() {
                let apps = await MainActor.run { SteamStopWatch.askToQuit(appID: app.appID) }
                log("Steam asked to stop the game: quit request to \(apps) app(s)")
                stopAsked = clock.now
            } else if let asked = stopAsked, !forced, clock.now - asked > .seconds(10) {
                forced = true
                let killed = await MainActor.run { SteamStopWatch.terminate(appID: app.appID) }
                let server = WineRuntimeLayout(wineBinary: context.wineBinary).wineserver
                _ = try? await self.runner.run(executable: server, arguments: ["-k"],
                                               environment: ["WINEPREFIX": bottle.prefix.path], currentDirectory: nil)
                log("the game ignored the quit request: SIGTERM to \(killed) app(s), wineserver -k")
            }
            try? await Task.sleep(for: pollInterval)
        }
        log("\(app.name) ended")
        return 0
    }

    /// Whether `SteamNativeMF` can serve a game: the classic MF bottle (its source) is built and current — or, once
    /// cloned, the clone itself is (a clone of a stale bottle carries the stale marker too).
    static func mediaFoundationReady(paths: AppPaths, currentRuntime: String?,
                                     fileManager: FileManager = .default) -> Bool {
        let prefix = BottleCloner.isPrefix(paths.nativeSteamBottleMF, fileManager: fileManager)
            ? paths.nativeSteamBottleMF : paths.steamBottleMF
        return MediaFoundationInstaller.isInstalled(inPrefix: prefix, fileManager: fileManager)
            && !MediaFoundationInstaller.isStale(inPrefix: prefix, currentRuntime: currentRuntime,
                                                 fileManager: fileManager)
    }

    /// The game as Silo models it, from the `appmanifest` in the library the install dir belongs to.
    static func steamApp(for request: NativeSteamLaunchRequest) throws -> SteamApp {
        let steamapps = request.installDir.deletingLastPathComponent().deletingLastPathComponent()
        let manifest = steamapps.appendingPathComponent("appmanifest_\(request.appID).acf")
        guard let text = try? String(contentsOf: manifest, encoding: .utf8) else { throw Failure.noManifest(manifest) }
        return try AppManifestDecoder().decode(text: text, libraryPath: steamapps.deletingLastPathComponent())
    }
}
