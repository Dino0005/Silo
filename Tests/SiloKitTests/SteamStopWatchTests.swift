import Foundation
import Testing
@testable import SiloKit

struct SteamStopWatchTests {
    @Test("Only a Terminating state for this app is a stop request")
    func parsesLines() {
        #expect(SteamStopWatch.isStopRequest(
            "[2026-11-13 21:16:39] AppID 1659420 state changed : Fully Installed,App Running,Terminating,", appID: 1659420))
        #expect(!SteamStopWatch.isStopRequest(
            "[2026-11-13 21:24:16] AppID 1659420 state changed : Fully Installed,App Running,", appID: 1659420))
        #expect(!SteamStopWatch.isStopRequest(
            "[x] AppID 544750 state changed : Fully Installed,App Running,Terminating,", appID: 1659420))
        #expect(!SteamStopWatch.isStopRequest(
            "[x] AppID 16594200 state changed : Fully Installed,App Running,Terminating,", appID: 1659420))
    }

    @Test("Reads only what Steam writes after the watch starts, whole lines only")
    func readsNewLines() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let log = try tmp.write("content_log.txt",
                                "[a] AppID 7 state changed : Fully Installed,App Running,Terminating,\n")
        var watch = SteamStopWatch(log: log, appID: 7)
        var asked = watch.stopRequested()
        #expect(!asked)                                  // the old line doesn't count
        let handle = try FileHandle(forWritingTo: log)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("[b] AppID 7 state changed : Fully Installed,App Running,".utf8))
        asked = watch.stopRequested()
        #expect(!asked)
        try handle.write(contentsOf: Data("\n[c] AppID 7 state changed : Fully Installed,App Running,Terminating".utf8))
        asked = watch.stopRequested()
        #expect(!asked)                                  // half-written line
        try handle.write(contentsOf: Data(",\n".utf8))
        try handle.close()
        asked = watch.stopRequested()
        #expect(asked)
        asked = watch.stopRequested()
        #expect(!asked)                                  // reported once
    }
}
