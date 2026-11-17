import Foundation

/// The single seam through which Silo executes external binaries (wine, wineboot, codesign, …).
///
/// Production code uses `SystemProcessRunner`; tests inject a fake so provisioning, linking, and
/// launching can be verified with no Wine installed.
///
/// Note: Silo launches games and the Steam client **detached** and does NOT track their PIDs or observe
/// their exit — it lets them outlive the app, like CrossOver, and reasons about bottle liveness PID-free via
/// `WineServerProbe`. The `isRunning`/`terminate` primitives remain ONLY for the first-run Steam warm-up,
/// which owns a transient client PID locally to drive its download/relaunch loop.
public protocol ProcessRunning: Sendable {
    /// Run to completion, capturing output. Used for short commands (e.g. `wineboot --init`).
    func run(
        executable: URL,
        arguments: [String],
        environment: [String: String],
        currentDirectory: URL?
    ) async throws -> ProcessResult

    /// Spawn detached (does not wait), streaming stdout+stderr to `logURL`. Used to launch the game.
    /// Returns the child PID.
    @discardableResult
    func spawnDetached(
        executable: URL,
        arguments: [String],
        environment: [String: String],
        currentDirectory: URL?,
        logURL: URL
    ) async throws -> Int32

    /// Whether a process with this PID is currently alive. Used only by the first-run Steam warm-up.
    func isRunning(pid: Int32) -> Bool

    /// Terminate a process by PID (SIGTERM). Used only by the warm-up to shut its transient download client
    /// down. No-op default.
    func terminate(pid: Int32)
}

extension ProcessRunning {
    public func terminate(pid: Int32) {}

    /// `spawnDetached`, with the child **responsible for itself** in macOS's privacy (TCC) accounting instead of
    /// inheriting Silo's — what an app opened from the Dock gets. Needed for macOS Steam started by Silo: as Silo's
    /// child it lost the permission to create Steam Input's virtual gamepad (measured 2026-11-13: no 045E/028E device,
    /// DualSense dead in SOULCALIBUR VI). Test doubles just spawn.
    public func spawnIndependent(executable: URL, arguments: [String], environment: [String: String],
                                 currentDirectory: URL?, logURL: URL) async throws -> Int32 {
        try await spawnDetached(executable: executable, arguments: arguments, environment: environment,
                                currentDirectory: currentDirectory, logURL: logURL)
    }
}
