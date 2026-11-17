import Darwin
import Foundation

/// "A game started from macOS Steam through Silo is running" — so Silo's guard leaves Steam's UI alone while
/// the user plays (user, 2026-11-09). The headless launcher (`NativeSteamLauncher`) drops one file per game,
/// named after the app id and holding its own pid, for as long as it waits for the game; a file whose pid is
/// gone (a crash) doesn't count and is cleaned up.
public struct NativeSteamPlaying: Sendable {
    public let dir: URL

    public init(paths: AppPaths) {
        dir = paths.supportDir.appendingPathComponent("NativeSteam/playing", isDirectory: true)
    }

    public func begin(appID: Int, pid: Int32 = getpid(), fileManager: FileManager = .default) {
        try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        try? Data(String(pid).utf8).write(to: dir.appendingPathComponent(String(appID)), options: .atomic)
    }

    public func end(appID: Int, fileManager: FileManager = .default) {
        try? fileManager.removeItem(at: dir.appendingPathComponent(String(appID)))
    }

    /// Whether any recorded launcher is still alive.
    public func isPlaying(fileManager: FileManager = .default,
                          isAlive: (Int32) -> Bool = { kill($0, 0) == 0 || errno == EPERM }) -> Bool {
        var playing = false
        for name in (try? fileManager.contentsOfDirectory(atPath: dir.path)) ?? [] {
            let file = dir.appendingPathComponent(name)
            if let text = try? String(contentsOf: file, encoding: .utf8),
               let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 0, isAlive(pid) {
                playing = true
            } else {
                try? fileManager.removeItem(at: file)
            }
        }
        return playing
    }
}
