import Foundation
import Testing
@testable import SiloKit

/// The pid a killed Steam leaves in `user.reg`, which made a game start before its client (2026-09-24).
/// The registry text below mirrors the SteamBottle's real `ActiveProcess` section.
struct SteamStalePidTests {
    private func userReg(pid: String) -> String {
        """
        WINE REGISTRY Version 2
        ;; All keys relative to \\\\User\\\\S-1-5-21-0-0-0-1000

        [Software\\\\Valve\\\\Steam] 1790276600
        #time=1dd4c5770b94b00
        "pid"=dword:00000abc

        [Software\\\\Valve\\\\Steam\\\\ActiveProcess] 1790276632
        #time=1dd4c5770b94b76
        "ActiveUser"=dword:00000000
        "pid"=dword:\(pid)

        [Software\\\\Wine] 1790276000
        """
    }

    @Test func aStalePidIsZeroedAndReadinessDropsAway() throws {
        let text = userReg(pid: "000000e0")
        #expect(SteamReadiness.hasActivePid(text))
        let cleared = try #require(SteamReadiness.clearingActivePid(text))
        #expect(!SteamReadiness.hasActivePid(cleared))
    }

    /// Only the `ActiveProcess` pid moves: another section's `"pid"` (here `Software\Valve\Steam`) and every
    /// other line stay byte-identical — this edits a live registry hive, so nothing else may change.
    @Test func onlyTheActiveProcessPidChanges() throws {
        let text = userReg(pid: "000000e0")
        let cleared = try #require(SteamReadiness.clearingActivePid(text))
        let before = text.components(separatedBy: "\n"), after = cleared.components(separatedBy: "\n")
        #expect(before.count == after.count)
        let changed = zip(before, after).filter { $0 != $1 }
        #expect(changed.count == 1)
        #expect(changed.first?.1 == #""pid"=dword:00000000"#)
        #expect(cleared.contains(#""pid"=dword:00000abc"#))
    }

    @Test func nothingToDoWhenAlreadyZeroOrAbsent() {
        #expect(SteamReadiness.clearingActivePid(userReg(pid: "00000000")) == nil)
        #expect(SteamReadiness.clearingActivePid("WINE REGISTRY Version 2\n[Software\\\\Wine] 1\n") == nil)
    }

    /// Windows line endings survive the edit.
    @Test func keepsCRLF() throws {
        let text = userReg(pid: "000000e0").replacingOccurrences(of: "\n", with: "\r\n")
        let cleared = try #require(SteamReadiness.clearingActivePid(text))
        #expect(cleared.contains("\"pid\"=dword:00000000\r\n"))
        #expect(!SteamReadiness.hasActivePid(cleared))
    }

    /// On a bottle with no wineserver (a prefix nobody is running) the file is actually rewritten.
    @Test func aDownBottleGetsItsFileCleared() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let prefix = try tmp.makeDir("SteamBottle")
        try userReg(pid: "000000e0").write(to: SteamReadiness.userReg(prefix: prefix), atomically: true, encoding: .utf8)
        #expect(SteamReadiness.clearStalePid(prefix: prefix))
        #expect(!SteamReadiness.isReady(prefix: prefix))
        #expect(!SteamReadiness.clearStalePid(prefix: prefix))     // second call: nothing left to do
    }
}
