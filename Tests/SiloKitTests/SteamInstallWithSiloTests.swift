import Foundation
import Testing
@testable import SiloKit

@Suite("SteamInstallWithSilo")
struct SteamInstallWithSiloTests {
    @Test("The script gives Silo's tool to Windows-only games without one, and gives Steam its install function back")
    func script() {
        let js = SteamInstallWithSilo.script()
        #expect(js.contains("S.version = \(SteamInstallWithSilo.version);"))
        #expect(js.contains("S.tool = '\(SiloCompatTool.name)';"))
        #expect(js.contains("SteamClient.Apps.SpecifyCompatTool(o.appid, S.tool)"))
        #expect(js.contains("d.strCompatToolName) continue;"))           // a tool the user chose stays
        #expect(js.contains("SteamClient.Installs.OpenInstallWizard = S.orig"))
        #expect(!js.contains("__SILO_"))
        #expect(SteamInstallWithSilo.probe.contains("version === \(SteamInstallWithSilo.version)"))
        #expect(SteamInstallWithSilo.pause(true).contains("pause(true)"))
    }

    @Test("Queued requests are read back as unique app ids; junk is no request")
    func requests() {
        #expect(SteamInstallWithSilo.requests(fromReply: "[480,2531310,480]") == [480, 2_531_310])
        #expect(SteamInstallWithSilo.requests(fromReply: "[]").isEmpty)
        #expect(SteamInstallWithSilo.requests(fromReply: "undefined").isEmpty)
        #expect(SteamInstallWithSilo.requests(fromReply: "[-1, 1e12]").isEmpty)
    }

    @Test("The restart question names the game and the library, in the user's language")
    func prompt() {
        let it = SteamInstallWithSilo.restartPrompt(gameName: "Spacewar", library: "Extreme Pro", italian: true)
        #expect(it.message.contains("Per installare Spacewar con Silo") && it.message.contains("“Extreme Pro”"))
        #expect(it.ok == "Riavvia Steam" && it.cancel == "Annulla")
        let en = SteamInstallWithSilo.restartPrompt(gameName: "Spacewar", library: "Extreme Pro", italian: false)
        #expect(en.ok == "Restart Steam" && en.message.hasPrefix("To install Spacewar with Silo"))
    }

    @Test("The dialog's AppleScript escapes quotes and returns the button pressed, or nothing when cancelled")
    func dialog() {
        let args = SteamInstallWithSilo.dialogArguments((message: #"Say "hi" \ now"#, ok: "OK", cancel: "No"))
        let source = stride(from: 1, to: args.count, by: 2).map { args[$0] }.joined(separator: "\n")
        #expect(source.contains(#"display dialog "Say \"hi\" \\ now""#))
        #expect(source.contains(#"buttons {"No", "OK"} default button "OK" cancel button "No""#))
        #expect(source.hasPrefix("try\nbutton returned of") && source.hasSuffix("on error\n\"\"\nend try"))
        #expect(stride(from: 0, to: args.count, by: 2).allSatisfy { args[$0] == "-e" })
    }

    @Test("Only unprotected Windows games need Silo's Install: not protected ones, not Mac builds")
    func needingSilo() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let steam = try tmp.makeDir("Steam")
        try FileManager.default.createDirectory(at: steam.appendingPathComponent("appcache"), withIntermediateDirectories: true)
        var protected = AppInfoFixtures.tekken
        _ = AppInfoPatcher.protectWindowsInstall(&protected)
        try AppInfoFixtures.cacheData([protected, AppInfoFixtures.tlou, AppInfoFixtures.dualBuild])
            .write(to: steam.appendingPathComponent("appcache/appinfo.vdf"))
        let installer = NativeSteamInstaller(steamRoot: steam, backupDir: tmp.url.appendingPathComponent("bk"),
                                             isSteamRunning: { true })   // readable while Steam runs
        #expect(try installer.windowsGamesNeedingSilo() == [2_531_310])
    }
}
