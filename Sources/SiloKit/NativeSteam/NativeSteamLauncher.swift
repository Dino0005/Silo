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

    public init(paths: AppPaths = .standard(), runner: ProcessRunning = SystemProcessRunner(),
                pollInterval: Duration = .seconds(1)) {
        self.paths = paths
        self.runner = runner
        self.pollInterval = pollInterval
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

        let orchestrator = LaunchOrchestrator(
            runner: runner, linker: GraphicsLinker(),
            steamClientRoot: NativeSteamBridge.defaultClientInstallPath()
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent())
        guard let exe = request.executable.flatMap({ FileManager.default.fileExists(atPath: $0.path) ? $0 : nil })
            ?? orchestrator.resolvedExecutable(app: app, config: config) else {
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
        let bottle = NativeSteamBottle(paths: paths, runner: runner)
        log("bottle \(paths.nativeSteamBottle.path), backend \(chosen), wine \(context.wineBinary.path)")
        try await bottle.ensureBottle()
        try bottle.stageRuntime(wine: context.wineBinary)

        let pid = try await orchestrator.launchInBottle(
            app: app, config: config, backend: backend, graphics: chosen,
            wine: context.wineBinary, prefix: paths.nativeSteamBottle,
            logURL: paths.log(forAppID: app.appID), gameExe: exe,
            altLoaderTarget: .init(gameName: app.name, gameID: String(app.appID),
                                   hostAppsDir: paths.hostAppsDir, playLink: .playSteam(appID: app.appID)),
            steamBridge: NativeSteamBridge(clientInstallPath: NativeSteamBridge.defaultClientInstallPath()))
        log("started \(app.name) (pid \(pid))")
        _ = try? await ConfigStore(paths: paths).updateGame(appID: app.appID) { $0.lastPlayed = Date() }

        // The wine launcher lives as long as the stand-in client, which waits for the game.
        while runner.isRunning(pid: pid) {
            try? await Task.sleep(for: pollInterval)
        }
        log("\(app.name) ended")
        return 0
    }

    /// The game as Silo models it, from the `appmanifest` in the library the install dir belongs to.
    static func steamApp(for request: NativeSteamLaunchRequest) throws -> SteamApp {
        let steamapps = request.installDir.deletingLastPathComponent().deletingLastPathComponent()
        let manifest = steamapps.appendingPathComponent("appmanifest_\(request.appID).acf")
        guard let text = try? String(contentsOf: manifest, encoding: .utf8) else { throw Failure.noManifest(manifest) }
        return try AppManifestDecoder().decode(text: text, libraryPath: steamapps.deletingLastPathComponent())
    }
}
