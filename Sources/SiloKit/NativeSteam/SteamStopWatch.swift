import AppKit
import Foundation

/// Steam's **Stop** for a game Silo runs through its compatibility tool. Measured 2026-11-13 on UNCHARTED: Stop only
/// set the app to "Terminating" (`logs/content_log.txt`) — no signal reached Silo (the process Steam launched) nor any
/// Wine process, and the game kept running. A normal quit request to the game's app closed it cleanly, and so did
/// `SIGTERM`. So while the game runs, Silo reads the new lines of Steam's content log (read only) and, on
/// "Terminating" for its app, asks the game to quit; `NativeSteamLauncher` ends it if it is still there 10 s later.
public struct SteamStopWatch: Sendable {
    public let log: URL
    public let appID: Int
    private var offset: UInt64

    /// Starts at the log's current end: only what Steam writes from now on counts.
    public init(log: URL = FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent("Library/Application Support/Steam/logs/content_log.txt"),
                appID: Int, fileManager: FileManager = .default) {
        self.log = log
        self.appID = appID
        let size = (try? fileManager.attributesOfItem(atPath: log.path)[.size] as? NSNumber)?.uint64Value
        self.offset = size ?? 0
    }

    /// Pure: whether a content-log line sets `appID` to Terminating —
    /// `[…] AppID 1659420 state changed : Fully Installed,App Running,Terminating,`.
    static func isStopRequest(_ line: some StringProtocol, appID: Int) -> Bool {
        guard let range = line.range(of: "AppID \(appID) state changed :") else { return false }
        return line[range.upperBound...].split(separator: ",")
            .contains { $0.trimmingCharacters(in: .whitespaces) == "Terminating" }
    }

    /// Whether Steam asked to stop the game since the last call.
    public mutating func stopRequested() -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: log) else { return false }
        defer { try? handle.close() }
        let end = (try? handle.seekToEnd()) ?? 0
        if end < offset { offset = 0 }                    // Steam rotated the log
        guard end > offset, (try? handle.seek(toOffset: offset)) != nil,
              let data = try? handle.readToEnd() else { return false }
        // Only whole lines; a half-written last line is read again next time.
        guard let lastNewline = data.lastIndex(of: UInt8(ascii: "\n")) else { return false }
        offset += UInt64(lastNewline - data.startIndex + 1)
        let text = String(decoding: data[data.startIndex...lastNewline], as: UTF8.self)
        return text.split(separator: "\n").contains { Self.isStopRequest($0, appID: appID) }
    }

    /// The running apps that are this game: its game app, or the alt-loader host when the launch fell back to it.
    @MainActor
    static func gameApps(appID: Int) -> [NSRunningApplication] {
        let id = GameHostBundle.bundleSafe(String(appID))
        return [GameHostBundle.gameAppIDPrefix + id, GameHostBundle.bundleIDPrefix + id]
            .flatMap { NSRunningApplication.runningApplications(withBundleIdentifier: $0) }
    }

    /// A normal quit request to the game — what Cmd-Q does: the game can save and close itself.
    @MainActor
    public static func askToQuit(appID: Int) -> Int {
        let apps = gameApps(appID: appID)
        apps.forEach { $0.terminate() }
        return apps.count
    }

    /// `SIGTERM` to the game's processes, for a game that ignored the quit request.
    @MainActor
    public static func terminate(appID: Int) -> Int {
        let pids = gameApps(appID: appID).map(\.processIdentifier).filter { $0 > 0 }
        pids.forEach { kill($0, SIGTERM) }
        return pids.count
    }
}
