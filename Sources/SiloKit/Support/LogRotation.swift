import Foundation

/// Keeps the last few launch logs of a game instead of one.
///
/// **Why (2026-09-25):** each launch truncated `<game>.log`, so only the latest run survived. When Tekken 8
/// froze on one launch and ran on another, the working run's log was already gone and the two could not be
/// compared — exactly the comparison the freeze investigation needed. Now a launch first shifts the
/// previous logs down: `<game>.log` → `<game>.1.log` → … → `<game>.<keep-1>.log`, the oldest dropped.
///
/// `keep` counts the current launch too: 5 means this run plus the four before it. Best-effort — a
/// rotation that fails must never stop a launch.
enum LogRotation {
    static let defaultKeep = 5

    /// The file for the `index`-th previous run (`0` is the current log itself).
    static func url(for log: URL, index: Int) -> URL {
        guard index > 0 else { return log }
        let base = log.deletingPathExtension().lastPathComponent
        let ext = log.pathExtension.isEmpty ? "log" : log.pathExtension
        return log.deletingLastPathComponent().appendingPathComponent("\(base).\(index).\(ext)")
    }

    static func rotate(_ log: URL, keep: Int = defaultKeep, fileManager: FileManager = .default) {
        guard keep > 1, fileManager.fileExists(atPath: log.path) else { return }
        try? fileManager.removeItem(at: url(for: log, index: keep - 1))       // the oldest goes
        for index in stride(from: keep - 2, through: 0, by: -1) {
            let from = url(for: log, index: index)
            guard fileManager.fileExists(atPath: from.path) else { continue }
            try? fileManager.moveItem(at: from, to: url(for: log, index: index + 1))
        }
    }
}
