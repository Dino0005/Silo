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

    @Test("the game's own output can't cost it its icon — bytes that aren't UTF-8 included")
    func tolerantOfNonUTF8Output() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let log = tmp.url.appendingPathComponent("3764200.log")
        var bytes = Data("""
        ===== Silo launch @ 2026-09-04 00:19:54 =====
        exe   : /Users/x/bin/wine64
        args  : /Volumes/Games/RE requiem/re9.exe
        cwd   : /Volumes/Games/RE requiem
        ===== begin process output =====

        """.utf8)
        // What a game prints in a Windows codepage: "è" as CP1252, invalid on its own as UTF-8. One of
        // these anywhere in the file used to make the whole read — header included — return nothing.
        bytes.append(contentsOf: [0xE8, 0x0A])
        try bytes.write(to: log)
        let exe = try #require(ShortcutFinalize.loggedExecutable(logFile: log))
        #expect(exe.lastPathComponent == "re9.exe")
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
