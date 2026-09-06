import Foundation
import Testing
@testable import SiloKit

/// Picking the executable a shortcut takes its icon from.
@Suite("Shortcut icon source")
struct ShortcutIconTests {

    @Test("the executable is read from the launch log's header, arguments and all")
    func readsExecutableFromLog() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let log = try tmp.write("3764200.log", """
        ===== Silo launch @ 2026-09-04 00:19:54 =====
        exe   : /Users/x/Runtimes/wine-crossover-26.3/bin/wine64
        args  : /Volumes/Extreme Pro/SteamLibrary/steamapps/common/RE requiem/re9.exe
        cwd   : /Volumes/Extreme Pro/SteamLibrary/steamapps/common/RE requiem
        env   :
        """)
        let exe = try #require(ShortcutFinalize.loggedExecutable(logFile: log))
        // The game's exe, not wine64 — the `exe :` line names the loader, `args :` names the game.
        #expect(exe.lastPathComponent == "re9.exe")
        #expect(exe.path.hasSuffix("RE requiem/re9.exe"))
    }

    @Test("launch options after the executable are not taken for part of the path")
    func stripsLaunchOptions() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let log = try tmp.write("2492040.log", """
        ===== Silo launch @ 2026-09-04 00:19:54 =====
        exe   : /Users/x/bin/wine64
        args  : /Volumes/Games/Fatal Fury/CotW.exe -d3d11
        cwd   : /Volumes/Games/Fatal Fury
        """)
        let exe = try #require(ShortcutFinalize.loggedExecutable(logFile: log))
        #expect(exe.lastPathComponent == "CotW.exe")
    }

    @Test("a log without an args line yields nothing rather than a wrong guess")
    func missingArgsLineIsNil() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let log = try tmp.write("1.log", "===== Silo launch =====\nexe   : /bin/wine64\n")
        #expect(ShortcutFinalize.loggedExecutable(logFile: log) == nil)
        #expect(ShortcutFinalize.loggedExecutable(
            logFile: tmp.url.appendingPathComponent("absent.log")) == nil)
    }
}
