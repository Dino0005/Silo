import Foundation
import Testing
@testable import SiloKit

struct LogRotationTests {
    private func write(_ url: URL, _ text: String) throws { try Data(text.utf8).write(to: url) }
    private func read(_ url: URL) -> String? { try? String(contentsOf: url, encoding: .utf8) }

    @Test func previousLaunchesShiftDownAndTheOldestIsDropped() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let log = tmp.url.appendingPathComponent("1778820.log")
        // Six launches with keep = 5: the first one must be gone, the other five kept in order.
        for n in 1...6 {
            LogRotation.rotate(log, keep: 5)
            try write(log, "launch \(n)")
        }
        #expect(read(log) == "launch 6")
        #expect(read(LogRotation.url(for: log, index: 1)) == "launch 5")
        #expect(read(LogRotation.url(for: log, index: 4)) == "launch 2")
        #expect(read(LogRotation.url(for: log, index: 5)) == nil)
        #expect(!FileManager.default.fileExists(atPath: tmp.url.appendingPathComponent("1778820.5.log").path))
    }

    @Test func namesKeepTheGameAndTheExtension() {
        let log = URL(fileURLWithPath: "/L/manual-ABC.log")
        #expect(LogRotation.url(for: log, index: 0) == log)
        #expect(LogRotation.url(for: log, index: 2).lastPathComponent == "manual-ABC.2.log")
    }

    /// A first launch has nothing to rotate and must not create anything.
    @Test func aFirstLaunchRotatesNothing() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let log = tmp.url.appendingPathComponent("new.log")
        LogRotation.rotate(log)
        #expect(try FileManager.default.contentsOfDirectory(atPath: tmp.url.path).isEmpty)
    }
}
