import Foundation

/// Builds launch plans and runs the launch pipeline for a game in the Steam bottle.
///
/// `makePlan` is a **pure** function (exhaustively tested); `launchInBottle` is the thin async wrapper
/// that injects graphics libraries into the (already-provisioned) bottle prefix and spawns the game.
public struct LaunchOrchestrator: Sendable {
    private let runner: ProcessRunning
    private let linker: GraphicsLinker
    private let presenceInstaller: SteamPresenceInstaller

    public init(
        runner: ProcessRunning,
        linker: GraphicsLinker,
        presenceInstaller: SteamPresenceInstaller = SteamPresenceInstaller()
    ) {
        self.runner = runner
        self.linker = linker
        self.presenceInstaller = presenceInstaller
    }

    public enum LaunchError: Error, Sendable, Equatable {
        case wineNotConfigured
        case executableNotFound(URL)
        /// A 32-bit (i386) game was launched under GPTK, which is 64-bit-only (Apple ships no 32-bit
        /// D3DMetal) — it could only fall back to wined3d and fail. The caller steers the user to DXMT.
        case unsupported32BitOnGPTK(URL)
    }

    /// GPTK / D3DMetal is 64-bit-only, so a 32-bit game under it can only fall back to wined3d and fail.
    /// Refuse it up front (the caller surfaces an honest "use DXMT" message) rather than launching into a
    /// guaranteed graphics-init failure. Fails **open**: only a CONFIRMED i386 PE is refused — an
    /// unreadable/unknown executable is allowed through. DXMT (32-bit-capable) is never refused here.
    private func check32BitSupported(_ exe: URL, graphics: GraphicsBackend) throws {
        if graphics == .gptk, WindowsExecutable.is32Bit(exe) {
            throw LaunchError.unsupported32BitOnGPTK(exe)
        }
    }

    // MARK: - Pure plan builder

    /// Fixed name for the per-game virtual desktop `explorer` creates (see `desktopGeometry` below) —
    /// distinct from Steam's own `Silo` desktop (`SteamBottle.launchSteam`) so the two never collide if a
    /// game and the Steam client were ever inspected side by side; explorer scopes desktops by name, not
    /// by caller, so reusing one name across sequential game launches is fine (Silo never runs two games
    /// at once in the same bottle).
    static let gameDesktopName = "SiloGame"

    /// Build the launch plan for ANY executable in the bottle (a Steam game's resolved exe or a manual
    /// game's `.exe`) — it's keyed off `gameExe` + `config`, not the app identity, so it serves both.
    /// - Parameter wine: the resolved launch binary — the per-backend variant runtime `BottleResolver`
    ///   hands back (the DXMT clone, or the base for GPTK). Defaults to `backend.wineBinaryPath` when a
    ///   caller has no variant to inject, so `backend` still gates the graphics overrides via `libDir(for:)`.
    /// - Parameter desktopGeometry: `"<width>x<height>"` in real screen pixels (see `ScreenGeometry`), or
    ///   nil to launch rootless. When set AND `graphics == .gptk`, the game runs inside an `explorer
    ///   /desktop=` virtual desktop sized to exactly that — see the inline comment in the function body,
    ///   just before `LaunchPlan` is built, for why.
    /// - Parameter sharedBottle: `true` only for a game co-resident with the real Steam client in the
    ///   shared Steam bottle (`launchInBottle`) — the ONE case `Silo.enforceMsync` exists to protect
    ///   (splitting the wineserver there would silently break Steamworks IPC). Manual games each get their
    ///   OWN isolated prefix with no Steam client in it (`launchManualGame`, `runInstaller` on a manual
    ///   bottle) — there's no shared wineserver to protect, so `config.envFlags.syncMode` is honored as
    ///   the user picked it, instead of being silently overridden.
    public static func makePlan(
        config: GameConfig,
        backend: BackendConfig,
        graphics: GraphicsBackend = .gptk,
        wine: URL? = nil,
        gameExe: URL,
        workingDirectory: URL? = nil,
        prefix: URL,
        logURL: URL,
        sharedBottle: Bool = true,
        desktopGeometry: String? = nil
    ) throws -> LaunchPlan {
        guard let wine = wine ?? backend.wineBinaryPath else {
            throw LaunchError.wineNotConfigured
        }

        var environment = config.envFlags.environment(graphics: graphics)
        // Layer the base wine env (WINEDEBUG, DYLD bundled deps) under the user's flags, then force the
        // shared Steam-bottle WINEPREFIX (so the game is co-resident with the Steam client), regardless of
        // any user override.
        for (key, value) in Silo.wineEnvironment(prefix: prefix, wine: wine) where environment[key] == nil {
            environment[key] = value
        }
        environment["WINEPREFIX"] = prefix.path
        if sharedBottle {
            // The game shares ONE wineserver with the co-resident Steam client (see `Silo.enforceMsync`).
            // This deliberately overrides whatever EnvFlags.syncMode (and any WINEMSYNC/WINEESYNC in
            // envFlags.extra) produced — an esync/none per-game override would split the wineserver and
            // silently break Steamworks IPC, the exact failure the shared bottle exists to avoid.
            Silo.enforceMsync(&environment)
        }
        // else: an isolated manual-game bottle has no co-resident Steam client and no wineserver to
        // protect, so config.envFlags.syncMode (already folded into `environment` above) is honored as
        // the Sync picker in Settings actually shows it — instead of being silently overridden like the
        // shared Steam bottle case above.

        // The active backend's translated d3d modules are overlaid into the wine runtime's own lib/wine
        // tree (GraphicsLinker.overlayGPTK / overlayDXMT), so wine loads them directly — no WINEDLLPATH.
        // Force exactly that backend's module set to builtin (`GraphicsBackend.dllOverrides`) so the
        // overlaid versions beat the native wined3d copies the in-bottle Steam client's redist (Steamworks
        // Common Redistributables) drops into system32. Each backend's runtime carries only its own builtin
        // d3d set, so the override resolves deterministically to that one layer. GPTK additionally ships
        // D3DMetal.framework + libd3dshared in the runtime's lib/external, which dyld must find; DXMT's
        // winemetal.so links the system Metal.framework, so it needs no extra DYLD path. Gated on the
        // backend being configured — an unconfigured backend means the game falls back to wine's wined3d.
        if backend.libDir(for: graphics) != nil {
            if graphics.overlaysExternalFramework {
                let external = wine.wineRuntimeExternalDir
                environment["DYLD_FALLBACK_LIBRARY_PATH"] = "\(external.path):\(wine.siloDyldFallback)"
                environment["DYLD_FALLBACK_FRAMEWORK_PATH"] = external.path
            }
            environment["WINEDLLOVERRIDES"] = mergeOverride(
                environment["WINEDLLOVERRIDES"], graphics.dllOverrides)
        }

        var arguments = Self.invocation(for: gameExe) + config.customArgs
        // winemac.drv only ever honors a ChangeDisplaySettings/fullscreen request against what IT considers
        // the PRIMARY adapter (see dlls/winemac.drv/display.c — a deliberate upstream Wine limitation, not
        // a Silo bug: it rejects (fakes success on) any other adapter, "Changing non-primary adapter
        // settings is currently unsupported"). GPTK registers a second, fake NVIDIA/DLSS adapter alongside
        // the real GPU for its MetalFX bridge (`GraphicsLinker`'s nvngx rename); when THAT one ends up
        // marked primary instead of the real GPU, a rootless game's fullscreen request silently fails and
        // it's left windowed-but-undersized (menu bar/Dock visible around it — confirmed on-device against
        // Tekken 8, matching CrossOver.app side by side). Running the game inside an `explorer /desktop=`
        // virtual desktop sized to the real screen sidesteps the whole failure mode: Wine resizes its OWN
        // window, never touching a real macOS display or its primary/non-primary distinction — exactly
        // CrossOver's own long-documented fix ("Emulate a virtual desktop") for this class of bug. DXMT
        // hasn't shown the same failure on-device, so this is GPTK-only until evidence says otherwise.
        if graphics == .gptk, let desktopGeometry, !desktopGeometry.isEmpty {
            arguments = ["explorer", "/desktop=\(Self.gameDesktopName),\(desktopGeometry)"] + arguments
        }

        return LaunchPlan(
            executable: wine,
            arguments: arguments,
            environment: environment,
            // A game may resolve its data relative to a "start in" dir that isn't the exe's own folder
            // (e.g. an installer shortcut's WORKING_DIR). Honor it when set; otherwise default to the exe dir.
            currentDirectory: workingDirectory ?? gameExe.deletingLastPathComponent(),
            logURL: logURL
        )
    }

    /// The wine argument vector that runs `target`. Wine can exec a PE image (`.exe`) directly, but a
    /// Windows Installer package (`.msi`) is data, not a PE — it must be handed to the bottle's builtin
    /// `msiexec /i`. Everything else runs directly. (Steam/manual game targets are always `.exe`; only the
    /// "run installer" path feeds an `.msi` here.)
    static func invocation(for target: URL) -> [String] {
        guard target.pathExtension.lowercased() == "msi" else { return [target.path] }
        return ["msiexec", "/i", dosPath(for: target)]
    }

    /// Map a unix path to its `Z:` DOS equivalent (wine's default unix-root drive), e.g.
    /// `/a/b c.msi` → `Z:\a\b c.msi`. `msiexec` needs a DOS path; the child gets the argv element verbatim
    /// (no shell), so spaces need no quoting.
    static func dosPath(for url: URL) -> String {
        "Z:" + url.path.replacingOccurrences(of: "/", with: "\\")
    }

    // MARK: - Full pipeline

    /// Launch a game **co-resident in a shared prefix** (the Steam bottle) under GPTK, where a running
    /// Steam client serves Steamworks. Links graphics into the shared prefix, writes `steam_appid.txt`,
    /// and spawns with `WINEPREFIX` forced to `prefix`. The prefix must already be provisioned (by
    /// `SteamBottle`). Returns the child PID.
    /// - Parameter desktopGeometry: forwarded to `makePlan` — see its doc comment. Nil (the default) keeps
    ///   the prior rootless behavior; callers pass `ScreenGeometry.nativeResolution()` to get the fix.
    @discardableResult
    public func launchInBottle(
        app: SteamApp, config: GameConfig, backend: BackendConfig,
        graphics: GraphicsBackend, wine: URL? = nil, prefix: URL, logURL: URL,
        gameExe: URL? = nil, desktopGeometry: String? = nil
    ) async throws -> Int32 {
        guard let launchWine = wine ?? backend.wineBinaryPath else { throw LaunchError.wineNotConfigured }
        // Reuse the exe the caller already resolved (the VM resolves it once to pick the backend), else
        // resolve it here — avoids a second full install-dir walk AND guarantees the launched binary is the
        // one the backend decision was made against.
        let gameExe = try gameExe ?? resolveExecutable(app: app, config: config)
        try check32BitSupported(gameExe, graphics: graphics)
        try linkGraphics(backendConfig: backend, graphics: graphics, wine: launchWine, prefix: prefix)
        try presenceInstaller.apply(strategy: config.presence, appID: app.appID, gameExe: gameExe)
        let plan = try Self.makePlan(
            config: config, backend: backend, graphics: graphics, wine: launchWine,
            gameExe: gameExe, prefix: prefix, logURL: logURL, desktopGeometry: desktopGeometry)
        return try await spawn(plan)
    }

    // MARK: - Manual (non-Steam) games

    /// Launch a user-added non-Steam game in the bottle prefix under GPTK. No Steam presence (these don't
    /// use Steamworks) and no Steam client requirement — just wine + the absolute `.exe` path. Returns PID.
    /// - Parameter desktopGeometry: forwarded to `makePlan` — see its doc comment. Nil (the default) keeps
    ///   the prior rootless behavior; callers pass `ScreenGeometry.nativeResolution()` to get the fix.
    @discardableResult
    public func launchManualGame(
        _ game: ManualGame, backend: BackendConfig,
        graphics: GraphicsBackend, wine: URL? = nil, prefix: URL, logURL: URL, desktopGeometry: String? = nil
    ) async throws -> Int32 {
        guard let launchWine = wine ?? backend.wineBinaryPath else { throw LaunchError.wineNotConfigured }
        guard FileManager.default.fileExists(atPath: game.executablePath.path) else {
            throw LaunchError.executableNotFound(game.executablePath)
        }
        try check32BitSupported(game.executablePath, graphics: graphics)
        try linkGraphics(backendConfig: backend, graphics: graphics, wine: launchWine, prefix: prefix)
        let plan = try Self.makePlan(
            config: game.gameConfig, backend: backend, graphics: graphics, wine: launchWine,
            gameExe: game.executablePath, workingDirectory: game.workingDirectory, prefix: prefix, logURL: logURL,
            sharedBottle: false, desktopGeometry: desktopGeometry)
        return try await spawn(plan)
    }

    /// Run an installer (`.exe` or `.msi`) in the bottle prefix and **WAIT for it to finish**. Unlike a game
    /// launch (detached — Silo never owns a game's lifecycle), an installer is transient setup, like the
    /// license-bearing component installers: it runs blocking, so this returns when the user closes its
    /// window. That exit is the deterministic "install finished" signal the caller uses to scan for the
    /// shortcuts it wrote — no polling, no focus heuristics. Installs into the bottle's `drive_c`.
    @discardableResult
    public func runInstaller(
        exe: URL, backend: BackendConfig, graphics: GraphicsBackend = .gptk, prefix: URL, logURL: URL,
        sharedBottle: Bool = false
    ) async throws -> ProcessResult {
        guard let wine = backend.wineBinaryPath else { throw LaunchError.wineNotConfigured }
        guard FileManager.default.fileExists(atPath: exe.path) else {
            throw LaunchError.executableNotFound(exe)
        }
        try linkGraphics(backendConfig: backend, graphics: graphics, wine: wine, prefix: prefix)
        let plan = try Self.makePlan(
            config: GameConfig(appID: 0, presence: .none), backend: backend, graphics: graphics,
            wine: wine, gameExe: exe, prefix: prefix, logURL: logURL, sharedBottle: sharedBottle)
        writeLogHeader(for: plan)
        let result = try await runner.run(
            executable: plan.executable, arguments: plan.arguments,
            environment: plan.environment, currentDirectory: plan.currentDirectory)
        // Best-effort: append the installer's output under the header (the log viewer shows manual logs).
        if let handle = try? FileHandle(forWritingTo: logURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: result.standardOutput)
            try? handle.write(contentsOf: result.standardError)
        }
        return result
    }

    private func spawn(_ plan: LaunchPlan) async throws -> Int32 {
        writeLogHeader(for: plan)
        return try await runner.spawnDetached(
            executable: plan.executable, arguments: plan.arguments,
            environment: plan.environment, currentDirectory: plan.currentDirectory, logURL: plan.logURL)
    }

    /// Truncate the log and write the resolved launch context at the top (a fresh log per launch); the
    /// child's stdout/stderr then appends after it (`spawnDetached` seeks to end). Best-effort — a failed
    /// header write never blocks the launch.
    private func writeLogHeader(for plan: LaunchPlan) {
        try? FileManager.default.createDirectory(
            at: plan.logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data(plan.logHeader(at: Date()).utf8).write(to: plan.logURL)
    }

    /// Whether a launched process is still alive (best-effort). Used only by the first-run Steam WARM-UP,
    /// which owns its transient client PID locally to drive the download/relaunch loop; Silo does NOT track
    /// user-launched games or the running Steam client this way (it launches them detached and lets them
    /// outlive the app — see `WineServerProbe` for PID-free bottle liveness).
    public func isRunning(pid: Int32) -> Bool { runner.isRunning(pid: pid) }

    /// SIGTERM a process (best-effort) — used only by the warm-up to shut its transient download client down
    /// so setup can wrap the steamwebhelper. Not a user-facing "stop": Silo doesn't stop running games.
    public func terminate(pid: Int32) { runner.terminate(pid: pid) }

    /// The absolute path of the executable a Steam game would launch (from `config.executableRelativePath`
    /// or an auto-scan of its install dir), or nil if it can't be resolved. Used by `BackendChooser` to pick
    /// the Automatic backend from the game binary. Does a directory walk when auto-detecting — call off-main.
    public func resolvedExecutable(app: SteamApp, config: GameConfig) -> URL? {
        try? resolveExecutable(app: app, config: config)
    }

    /// Run a built-in wine tool (e.g. `winecfg`) against `prefix` with the resolved `wine`, detached. The
    /// caller resolves `{prefix, wine}` through `BottleResolver` (never hard-codes them). Msync env so the
    /// tool shares the bottle's wineserver instead of forking a second one on the same prefix.
    public func runWineTool(_ tool: String, prefix: URL, wine: URL) async {
        _ = try? await runner.spawnDetached(
            executable: wine, arguments: [tool],
            environment: Silo.msyncWineEnvironment(prefix: prefix, wine: wine), currentDirectory: nil,
            logURL: prefix.appendingPathComponent("winetool.log"))
    }

    // MARK: - Helpers

    private func resolveExecutable(app: SteamApp, config: GameConfig) throws -> URL {
        let installURL = app.installURL
        if let relative = config.executableRelativePath {
            // A user-entered relative exe must stay inside the install dir — reject a path that climbs out.
            guard !relative.split(separator: "/").contains("..") else {
                throw LaunchError.executableNotFound(installURL)
            }
            return installURL.appendingPathComponent(relative)
        }
        if let found = ExecutableResolver.firstExecutable(in: installURL) { return found }
        throw LaunchError.executableNotFound(installURL)
    }

    /// Wire up the selected backend's graphics translation before launch: overlay D3DMetal (GPTK) or DXMT
    /// into the wine RUNTIME (idempotent, shared by every co-resident game in that backend's bottle). For
    /// DXMT it ALSO seeds `winemetal.dll` into the game `prefix` (see `installDXMTPrefixLoaders` — wine can't
    /// load the winemetal builtin otherwise). Skipped when that backend is unconfigured — the game then falls
    /// back to wine's own wined3d.
    private func linkGraphics(
        backendConfig: BackendConfig, graphics: GraphicsBackend, wine: URL, prefix: URL
    ) throws {
        guard let libDir = backendConfig.libDir(for: graphics) else { return }
        switch graphics {
        case .gptk: try linker.overlayGPTK(wineBinary: wine, gptkLibDir: libDir)
        case .dxmt:
            try linker.overlayDXMT(wineBinary: wine, dxmtLibDir: libDir)
            try linker.installDXMTPrefixLoaders(prefix: prefix, dxmtLibDir: libDir)
        }
    }

    private static func mergeOverride(_ existing: String?, _ addition: String) -> String {
        guard let existing, !existing.isEmpty else { return addition }
        return existing + ";" + addition
    }
}
