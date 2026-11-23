import Foundation

/// Keeps every installed Windows game protected from stock macOS Steam (`AppInfoPatcher.protectWindowsInstall`).
///
/// Steam holds `appinfo.vdf` in memory and writes it back on exit, so the protection can only be (re)applied
/// while Steam is closed and has to be checked again after every session. The guard is a small per-user
/// LaunchAgent running `Silo --native-steam-guard`: at load (login) and each time Steam quits it runs
/// `NativeSteamInstaller.protectInstalledWindowsGames`, so the next Steam start always reads a protected cache —
/// including games installed meanwhile by Silo's classic Windows Steam into a shared library.
public enum NativeSteamGuard {
    public static let label = Silo.bundleID + ".native-steam-guard"
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

    /// Steam's own log of each client start (`logs/bootstrap_log.txt`).
    public static func bootstrapLogURL(steamRoot: URL) -> URL {
        steamRoot.appendingPathComponent("logs/bootstrap_log.txt")
    }

    /// Pure: the start line of Steam's LAST session in `bootstrapLog` when that session installed a pending client
    /// update and then shut down — the moment Steam expects its bootstrapper to start it again. `Steam (Silo)` starts
    /// the client directly (no bootstrapper, so Silo's library can ride along) and exits, so nothing restarts it: the
    /// guard does, once per session (the start line identifies it). Measured 2026-11-14 08:36: "Found pending update",
    /// the localized "update complete, starting Steam…", then "Shutdown", and no new start until the user clicked again.
    /// Only the log's English lines are matched; the rest is in Steam's language. nil for any other session end.
    public static func sessionEndedForUpdate(bootstrapLog: String) -> String? {
        let lines = bootstrapLog.split(whereSeparator: \.isNewline).map(String.init)
        guard let start = lines.lastIndex(where: { $0.contains("Startup - updater built") }) else { return nil }
        // Steam writes each start line twice in a row: the session begins at the first of the last pair.
        var first = start
        while first > 0, lines[first - 1].contains("Startup - ") { first -= 1 }
        let session = lines[first...]
        guard session.contains(where: { $0.contains("Found pending update") }),
              let last = session.last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }),
              last.hasSuffix("Shutdown") else { return nil }
        return lines[first]
    }

    /// Which file a binary is: a Silo update replaces the app, so the guard's executable gets a new inode, size or
    /// modification date.
    public struct BinaryIdentity: Sendable, Equatable {
        public let inode: UInt64
        public let size: UInt64
        public let modified: Date

        public init(inode: UInt64, size: UInt64, modified: Date) {
            self.inode = inode
            self.size = size
            self.modified = modified
        }

        /// The file at `url` now; nil while it is missing (mid-update).
        public static func of(_ url: URL, fileManager: FileManager = .default) -> BinaryIdentity? {
            guard let a = try? fileManager.attributesOfItem(atPath: url.path),
                  let inode = (a[.systemFileNumber] as? NSNumber)?.uint64Value,
                  let size = (a[.size] as? NSNumber)?.uint64Value,
                  let modified = a[.modificationDate] as? Date else { return nil }
            return BinaryIdentity(inode: inode, size: size, modified: modified)
        }
    }

    /// Pure: whether the guard should exit so launchd (`KeepAlive`) starts it again from the updated Silo. Nothing
    /// restarted it after an update, so the old binary kept running until the next login — with the old Compatibility
    /// page and the old protection (found 2026-11-23: the "Uncharted fix" switch missing from Steam's page). Only once
    /// the new file has been left alone for `settle`, so the restart never picks up a copy still being written.
    public static func shouldRestartForUpdate(started: BinaryIdentity?, now: BinaryIdentity?, at date: Date = Date(),
                                              settle: TimeInterval = 5) -> Bool {
        guard let started, let now, now != started else { return false }
        return date.timeIntervalSince(now.modified) >= settle
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
