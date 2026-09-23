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

    public init(runner: ProcessRunning) {
        self.runner = runner
    }

    /// Set to `1` to disable the alt loader entirely, for the whole app.
    static let disableFlag = "SILO_DISABLE_ALTLOADER"

    /// `/usr/bin/open`, so the host is started **by LaunchServices** — which is what gives it the bundle
    /// identity the window inherits. Launching the executable directly does NOT work: measured on
    /// CrossOver's own helper, which starts and then sits there (2026-09-20).
    static let openTool = URL(fileURLWithPath: "/usr/bin/open")

    /// Where a launch's hand-over socket lives. One per game id, under the per-user temp dir, so two
    /// games can't collide and a stale file from a crashed run is simply overwritten (the host `unlink`s
    /// it before binding).
    public static func socketPath(forGameID id: String, temporaryDirectory: URL) -> URL {
        temporaryDirectory.appendingPathComponent("silo-altloader-\(bundleSafe(id)).sock")
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
        environment: [String: String] = ProcessInfo.processInfo.environment,
        temporaryDirectory: URL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true),
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
        let app = bundle.bundleURL(in: hostAppsDir)
        guard let result = try? await runner.run(
            executable: Self.openTool,
            arguments: ["-a", app.path, "--args", socket.path],
            environment: [:], currentDirectory: nil),
              result.succeeded
        else {
            await cleanup(prefix: prefix, wine: wine, fileManager: fileManager)
            return nil
        }
        return socket
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
