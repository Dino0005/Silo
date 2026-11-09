import Foundation

/// Keeps every installed Windows game protected from stock macOS Steam (`AppInfoPatcher.protectWindowsInstall`).
///
/// Steam holds `appinfo.vdf` in memory and writes it back on exit, so the protection can only be (re)applied
/// while Steam is closed and has to be checked again after every session. The guard is a small per-user
/// LaunchAgent running `Silo --native-steam-guard`: at load (login) and each time Steam quits it runs
/// `NativeSteamInstaller.protectInstalledWindowsGames`, so the next Steam start always reads a protected cache —
/// including games installed meanwhile by Silo's classic Windows Steam into a shared library.
public enum NativeSteamGuard {
    public static let label = "com.mikael.silo.native-steam-guard"
    /// The argument that runs the guard loop.
    public static let flag = "--native-steam-guard"

    /// `~/Library/LaunchAgents/<label>.plist`.
    public static func launchAgentURL(home: URL) -> URL {
        home.appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    /// The LaunchAgent: started at login, restarted if it ever exits, output into Silo's logs.
    public static func launchAgentPlist(siloExecutable: URL, logURL: URL) throws -> Data {
        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [siloExecutable.path, flag],
            "RunAtLoad": true,
            "KeepAlive": true,
            "ProcessType": "Background",
            "StandardOutPath": logURL.path,
            "StandardErrorPath": logURL.path,
        ]
        return try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    }

    /// Decides, from successive "is Steam running" samples, when to protect: on the first sample with Steam
    /// closed (the guard just started) and on every running → closed edge. Never while Steam runs.
    public struct Watch: Sendable {
        private var lastRunning: Bool?
        public init() {}

        public mutating func shouldProtect(steamRunning: Bool) -> Bool {
            defer { lastRunning = steamRunning }
            return !steamRunning && lastRunning != false
        }
    }
}
