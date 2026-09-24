import Foundation

/// One launch's worth of alt-loader setup: the per-game host `.app`, the registry gate, and the socket
/// Wine hands the new process over on.
///
/// **What this buys:** the process that ends up owning the game's macOS window is our own bundled host,
/// so Mission Control and Stage Manager show the game's icon instead of a blank sheet (measured, and
/// confirmed on screen 2026-09-23). See `GameHostBundle` and `AltLoaderWhitelist` for the two halves,
/// and `STATUS.md` for how the protocol was established.
///
/// **Always-on by design, with one global escape hatch.** There is deliberately no per-game setting: a
/// toggle would ask the user to understand a Wine internal to get an icon. `SILO_DISABLE_ALTLOADER=1`
/// turns the whole thing off if a game ever misbehaves — a per-game opt-out is worth adding only if a
/// real game demands it, not before.
///
/// **Every step degrades to "launch the old way".** No host in the bundle (a `swift run` dev build), an
/// unwritable `HostApps` dir, a registry import that fails, `open` refusing: `prepare` returns `nil`,
/// the caller sets no `CX_ALT_LOADER_SOCKET`, and Wine starts the game exactly as it does today. The
/// icon is cosmetic and must never be able to stop a game from starting.
public struct AltLoaderSession: Sendable {
    private let runner: ProcessRunning
    private let environment: [String: String]
    private let temporaryDirectory: URL
    private let socketWaitTimeout: Duration

    /// - Parameters:
    ///   - environment: where the host path and the kill switch are read from. Injectable so a test can
    ///     hand over a fake host without mutating the process environment.
    ///   - temporaryDirectory: where the hand-over socket is created.
    ///   - socketWaitTimeout: how long `prepare` waits for the host to `bind`. Zero means "don't wait",
    ///     which is what the unit tests use — no real host binds there.
    public init(runner: ProcessRunning,
                environment: [String: String] = ProcessInfo.processInfo.environment,
                temporaryDirectory: URL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true),
                socketWaitTimeout: Duration = .seconds(5)) {
        self.runner = runner
        self.environment = environment
        self.temporaryDirectory = temporaryDirectory
        self.socketWaitTimeout = socketWaitTimeout
    }

    /// What a launch needs in order to be handed to a host: the identity the window will carry, and
    /// where the per-game bundles live. Passing `nil` instead of a `Target` is how a caller opts out.
    public struct Target: Sendable {
        /// Shown as the process name and the bundle's `CFBundleName`.
        public let gameName: String
        /// Stable per-game token — a Steam app ID, or a manual game's UUID string.
        public let gameID: String
        /// Normally `AppPaths.hostAppsDir`.
        public let hostAppsDir: URL

        public init(gameName: String, gameID: String, hostAppsDir: URL) {
            self.gameName = gameName
            self.gameID = gameID
            self.hostAppsDir = hostAppsDir
        }
    }

    /// Set to `1` to disable the alt loader entirely, for the whole app.
    static let disableFlag = "SILO_DISABLE_ALTLOADER"

    /// `/usr/bin/open`, so the host is started **by LaunchServices** — which is what gives it the bundle
    /// identity the window inherits. Launching the executable directly does NOT work: measured on
    /// CrossOver's own helper, which starts and then sits there (2026-09-20).
    static let openTool = URL(fileURLWithPath: "/usr/bin/open")

    /// The hard limit on an `AF_UNIX` path: `sockaddr_un.sun_path` is 104 bytes on Darwin, one of which
    /// is the terminator. **Exceeding it does not fail — it truncates**, and a truncated bind produces a
    /// socket under a *different* name than the one Wine connects to, so Wine falls back to `fork()` and
    /// the window stays icon-less. Measured 2026-09-24 on a manual game: the per-user `TMPDIR` (49 bytes)
    /// plus a 36-char UUID plus `silo-altloader-.sock` came to 105 — two bytes over, silently.
    static let maxSocketPathLength = 103

    /// Where a launch's hand-over socket lives. One per game, under the per-user temp dir (never `/tmp`:
    /// a world-writable path would let a local squatter receive the fds Wine passes, including the
    /// wineserver socket). A stale file from a crashed run is simply overwritten — the host `unlink`s it
    /// before binding.
    ///
    /// The name is kept **short on purpose**, because of `maxSocketPathLength`: a readable head from the
    /// id plus a hash of the whole id, which keeps it unique for ids that share a prefix (manual games'
    /// UUIDs do not, but a Steam app id and a UUID starting with the same digits could).
    public static func socketPath(forGameID id: String, temporaryDirectory: URL) -> URL {
        let safe = bundleSafe(id)
        let head = String(safe.prefix(8))
        return temporaryDirectory.appendingPathComponent("silo-al-\(head)-\(shortHash(id)).sock")
    }

    /// FNV-1a, 64-bit, as 16 hex digits. Not a cryptographic need: this only has to keep two games'
    /// sockets apart, and be the same value on every launch of the same game.
    private static func shortHash(_ s: String) -> String {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for b in s.utf8 {
            h ^= UInt64(b)
            h = h &* 0x0000_0100_0000_01b3
        }
        return String(h, radix: 16)
    }

    /// Prepare the hand-over and return the socket to publish as `CX_ALT_LOADER_SOCKET`, or `nil` to
    /// launch the old way.
    ///
    /// - Parameters:
    ///   - gameName: shown as the process name and the bundle's `CFBundleName`.
    ///   - gameID: stable per-game token (Steam app ID, or a manual game's UUID).
    ///   - gameExe: the Windows executable; its **base name** is what goes in the whitelist, because
    ///     that is what Wine matches on (`AltLoaderWhitelist.exeName`).
    ///   - iconICO: the exe's icon from `PEIcon`, if any.
    public func prepare(
        gameName: String,
        gameID: String,
        gameExe: URL,
        iconICO: Data?,
        prefix: URL,
        wine: URL,
        hostAppsDir: URL,
        fileManager: FileManager = .default
    ) async -> URL? {
        guard environment[Self.disableFlag] != "1" else { return nil }
        guard let host = AltLoaderHost.resolved(environment: environment, fileManager: fileManager)
        else { return nil }

        let bundle = GameHostBundle(name: gameName, id: gameID)
        guard let hostInBundle = try? bundle.write(
            into: hostAppsDir, hostBinary: host, iconICO: iconICO, fileManager: fileManager)
        else { return nil }
        _ = hostInBundle   // the bundle is what we launch; the path is only useful for diagnostics

        // Gate Wine's hand-over to THIS exe. Without it the socket is consumed by the first process the
        // prefix creates — on a cold bottle `wineboot.exe --init`, which owns no window (measured).
        let exeName = AltLoaderWhitelist.exeName(for: gameExe.lastPathComponent)
        guard await applyRegistry(AltLoaderWhitelist.enableReg(exeNames: [exeName]),
                                  named: "silo-altloader.reg", prefix: prefix, wine: wine,
                                  fileManager: fileManager)
        else { return nil }

        let socket = Self.socketPath(forGameID: gameID, temporaryDirectory: temporaryDirectory)
        // Better no hand-over than a truncated one: a truncated bind looks like it worked and then
        // silently costs the icon (see `maxSocketPathLength`).
        guard socket.path.utf8.count <= Self.maxSocketPathLength else {
            await cleanup(prefix: prefix, wine: wine, fileManager: fileManager)
            return nil
        }
        // Remove any socket left by an earlier run BEFORE starting the host. The host cannot clean up
        // after itself — it becomes the game and never returns — so the file outlives it. Left in place
        // it makes the readiness wait below a lie: the game then connects to a socket nobody accepts on
        // and **hangs** waiting for the reply (measured 2026-09-24 on God of War's second launch).
        try? fileManager.removeItem(at: socket)

        let app = bundle.bundleURL(in: hostAppsDir)
        guard let result = try? await runner.run(
            executable: Self.openTool,
            // `-n` forces a NEW instance. Without it LaunchServices sees an app with this bundle id
            // already running — the previous run of the same game, or a leftover that outlived it — and
            // merely activates that one, so nothing binds the new socket and the launch silently goes
            // back to the old path (measured 2026-09-24: a second launch adopted nothing while the first
            // game's host was still alive).
            arguments: ["-n", "-a", app.path, "--args", socket.path],
            environment: [:], currentDirectory: nil),
              result.succeeded
        else {
            await cleanup(prefix: prefix, wine: wine, fileManager: fileManager)
            return nil
        }

        // `open` returns as soon as LaunchServices has taken the request — the host still has to start
        // and `bind`. The spawn follows within milliseconds, so without this wait the game can reach
        // `connect()` first, get ENOENT, and fork. Waiting for the socket file to appear IS the readiness
        // signal: it comes into existence at `bind`, and `listen` follows immediately.
        guard await waitForSocket(socket, fileManager: fileManager) else {
            await cleanup(prefix: prefix, wine: wine, fileManager: fileManager)
            return nil
        }
        return socket
    }

    /// Poll for the host's socket. A zero timeout means "don't wait" — what the unit tests use, since no
    /// real host binds there.
    private func waitForSocket(_ socket: URL, fileManager: FileManager) async -> Bool {
        guard socketWaitTimeout > .zero else { return true }
        let deadline = ContinuousClock.now.advanced(by: socketWaitTimeout)
        while ContinuousClock.now < deadline {
            if fileManager.fileExists(atPath: socket.path) { return true }
            do { try await Task.sleep(for: .milliseconds(25)) } catch { return false }
        }
        return fileManager.fileExists(atPath: socket.path)
    }

    /// Remove the whitelist key. **Always call this once the launch has been handed over**, including on
    /// failure paths.
    ///
    /// Leaving the key behind is not neutral: an `UseAltLoader` that exists but no longer lists the exe
    /// matches nothing, which would silently exclude *every* executable from the alt loader — the state a
    /// half-finished `reg delete` produced during the experiments. `disableReg` deletes the key outright.
    public func cleanup(prefix: URL, wine: URL, fileManager: FileManager = .default) async {
        _ = await applyRegistry(AltLoaderWhitelist.disableReg(),
                                named: "silo-altloader-off.reg", prefix: prefix, wine: wine,
                                fileManager: fileManager)
    }

    /// Import a `.reg` through `wine regedit /S`, the same way `SteamBottle.applyWineDefaults` does —
    /// one import instead of per-value `reg add` calls, which hung repeatedly when driven by hand.
    private func applyRegistry(_ text: String, named name: String, prefix: URL, wine: URL,
                               fileManager: FileManager) async -> Bool {
        let driveC = prefix.appendingPathComponent("drive_c")
        try? fileManager.createDirectory(at: driveC, withIntermediateDirectories: true)
        let file = driveC.appendingPathComponent(name)
        guard (try? text.write(to: file, atomically: true, encoding: .utf8)) != nil else { return false }
        let result = try? await runner.run(
            executable: wine, arguments: ["regedit", "/S", "C:\\\(name)"],
            environment: Silo.msyncWineEnvironment(prefix: prefix, wine: wine),
            currentDirectory: prefix)
        try? fileManager.removeItem(at: file)
        return result?.succeeded == true
    }

    /// Filesystem-safe token for the socket file name.
    private static func bundleSafe(_ s: String) -> String {
        String(s.unicodeScalars.map {
            CharacterSet.alphanumerics.contains($0) || $0 == "-" ? Character($0) : "-"
        })
    }
}
