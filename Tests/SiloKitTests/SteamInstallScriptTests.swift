import Foundation
import Testing
@testable import SiloKit

@Suite("SteamInstallScript")
struct SteamInstallScriptTests {
    /// The Last of Us Part II's install-script.vdf (2026-11-10), signature shortened.
    static let tlou = #"""
        "InstallScript"
        {
        	"Run Process"
        	{
        		"PlayStation SDK 3.50"
        		{
        			"Process 1"		"%INSTALLDIR%\\install_pspc_sdk_runtime.bat"
        			"Command 1"		"quiet"
        			"NoCleanUp"		"1"
        		}
        	}
        	"Run Process On Uninstall"
        	{
        		"DeletePSOs"
        		{
        			"Process 1"		"cmd.exe"
        			"Command 1"		"/C rmdir /S /Q \"%INSTALLDIR%\\psolibs\""
        		}
        	}
        }
        "kvsignatures"
        {
        	"InstallScript"		"2ab0af22"
        }
        """#

    @Test("Only Run Process steps are read; the uninstall ones are ignored")
    func parsesTLOU() throws {
        let script = try SteamInstallScript.parse(text: Self.tlou)
        #expect(script.steps == [.init(name: "PlayStation SDK 3.50", commands: [
            .init(process: #"%INSTALLDIR%\install_pspc_sdk_runtime.bat"#, arguments: "quiet")])])
    }

    @Test("A batch file runs through cmd /c with the install dir as a DOS path; msi through msiexec")
    func wineArguments() {
        let dir = URL(fileURLWithPath: "/Volumes/SSD/common/The Last of Us Part II")
        #expect(SteamInstallScript.wineArguments(
            for: .init(process: #"%INSTALLDIR%\install_pspc_sdk_runtime.bat"#, arguments: "quiet"), installDir: dir)
            == ["cmd", "/c", #"Z:\Volumes\SSD\common\The Last of Us Part II\install_pspc_sdk_runtime.bat"#, "quiet"])
        #expect(SteamInstallScript.wineArguments(
            for: .init(process: #"%installdir%\redist\x.msi"#, arguments: #"/qn TARGET="%ROOTDRIVE%\A B""#), installDir: dir)
            == ["msiexec", "/i", #"Z:\Volumes\SSD\common\The Last of Us Part II\redist\x.msi"#, "/qn", #"TARGET=C:\A B"#])
        #expect(SteamInstallScript.wineArguments(for: .init(process: "setup.exe", arguments: ""), installDir: dir)
            == ["setup.exe"])
    }

    @Test("Command lines split on spaces, quoted parts kept together")
    func splits() {
        #expect(SteamInstallScript.splitArguments(#"  /a "b c"  d"" "" "#) == ["/a", "b c", "d", ""])
        #expect(SteamInstallScript.splitArguments("") == [])
    }

    @Test("Each step runs once: a success is recorded, a failure is retried at most once more")
    func runsOnce() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        try tmp.write("game/install-script.vdf", Self.tlou)
        let prefix = try tmp.makeDir("bottle")
        let game = tmp.url.appendingPathComponent("game")
        let wine = URL(fileURLWithPath: "/r/bin/wine64")
        let fake = FakeProcessRunner()
        let runner = SteamInstallScriptRunner(runner: fake)

        fake.queueResult(ProcessResult(exitCode: 3))
        #expect(await runner.run(appID: 7, installDir: game, prefix: prefix, wine: wine)
                == [.ran(step: "PlayStation SDK 3.50", exitCode: 3)])
        let call = try #require(fake.lastInvocation)
        #expect(call.executable == wine && call.arguments.prefix(2) == ["cmd", "/c"])
        #expect(call.environment["WINEPREFIX"] == prefix.path && call.environment["WINEMSYNC"] == "1")
        #expect(call.currentDirectory == game)

        #expect(await runner.run(appID: 7, installDir: game, prefix: prefix, wine: wine)
                == [.ran(step: "PlayStation SDK 3.50", exitCode: 0)])
        #expect(await runner.run(appID: 7, installDir: game, prefix: prefix, wine: wine)
                == [.skipped(step: "PlayStation SDK 3.50")])
        #expect(fake.invocations.count == 2)
        // Per game: another app id with the same script still runs.
        #expect(await runner.run(appID: 8, installDir: game, prefix: prefix, wine: wine)
                == [.ran(step: "PlayStation SDK 3.50", exitCode: 0)])

        // Two failures: given up, no third attempt.
        fake.queueResult(ProcessResult(exitCode: 1)); fake.queueResult(ProcessResult(exitCode: 1))
        _ = await runner.run(appID: 9, installDir: game, prefix: prefix, wine: wine)
        _ = await runner.run(appID: 9, installDir: game, prefix: prefix, wine: wine)
        #expect(await runner.run(appID: 9, installDir: game, prefix: prefix, wine: wine)
                == [.skipped(step: "PlayStation SDK 3.50")])
    }

    @Test("A game without an install script runs nothing")
    func noScript() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let fake = FakeProcessRunner()
        #expect(await SteamInstallScriptRunner(runner: fake).run(
            appID: 1, installDir: try tmp.makeDir("game"), prefix: try tmp.makeDir("b"),
            wine: URL(fileURLWithPath: "/w")).isEmpty)
        #expect(fake.invocations.isEmpty)
    }

    @Test("The script runs under the game's Sync setting, so the game's wineserver accepts it")
    func followsSyncMode() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        try tmp.write("game/install-script.vdf", Self.tlou)
        let prefix = try tmp.makeDir("bottle")
        let fake = FakeProcessRunner()
        _ = await SteamInstallScriptRunner(runner: fake).run(
            appID: 7, installDir: tmp.url.appendingPathComponent("game"), prefix: prefix,
            wine: URL(fileURLWithPath: "/r/bin/wine64"), syncMode: .none)
        let call = try #require(fake.lastInvocation)
        #expect(call.environment["WINEMSYNC"] == nil && call.environment["WINEESYNC"] == nil)
    }
}
