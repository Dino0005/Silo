import Foundation
import Testing
@testable import SiloKit

@Suite("Steam library filters")
struct SteamLibraryFiltersTests {
    @Test("The script carries Silo's Windows list and version, and hooks Steam's platform getter and Apple button")
    func script() {
        let js = SteamLibraryFilters.script(windowsGames: [1_778_820, 570, 1_817_070])
        #expect(js.contains("S.win = new Set([570,1778820,1817070]);"))
        #expect(js.contains("S.version = \(SteamLibraryFilters.version);"))
        #expect(js.contains("'is_available_on_current_platform'"))
        #expect(js.contains("svg.SVGIcon_AppleLogo"))
        #expect(js.contains("Mostra solo i giochi macOS") && js.contains("Mostra solo i giochi Windows"))
        #expect(!js.contains("__SILO_"))
        #expect(SteamLibraryFilters.probe.contains("version === \(SteamLibraryFilters.version)"))
    }

    @Test("The debug-port marker goes next to steam_osx, only when that folder exists")
    func debugPortMarker() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let steam = try tmp.makeDir("Steam")
        #expect(!SteamLibraryFilters.enableDebugPort(steamRoot: steam))
        try tmp.makeDir("Steam/Steam.AppBundle/Steam/Contents/MacOS")
        #expect(SteamLibraryFilters.enableDebugPort(steamRoot: steam))
        #expect(FileManager.default.fileExists(atPath:
            steam.appendingPathComponent("Steam.AppBundle/Steam/Contents/MacOS/.cef-enable-remote-debugging").path))
        #expect(SteamLibraryFilters.enableDebugPort(steamRoot: steam))   // idempotent
    }

    @Test("The DevTools request evaluates with awaited, by-value results; replies are matched by id")
    func devToolsMessages() throws {
        let message = try SteamCEFClient.evaluateMessage(id: 3, expression: "1+1")
        let object = try #require(try JSONSerialization.jsonObject(with: Data(message.utf8)) as? [String: Any])
        let params = try #require(object["params"] as? [String: Any])
        #expect(object["method"] as? String == "Runtime.evaluate")
        #expect(params["awaitPromise"] as? Bool == true && params["returnByValue"] as? Bool == true)

        let ok = Data(#"{"id":3,"result":{"result":{"type":"string","value":"silo filters v1"}}}"#.utf8)
        #expect(try SteamCEFClient.result(of: ok, id: 3) == .init(value: "silo filters v1"))
        let other = Data(#"{"method":"Runtime.consoleAPICalled","params":{}}"#.utf8)
        #expect(try SteamCEFClient.result(of: other, id: 3) == nil)
        let thrown = Data(#"{"id":3,"result":{"result":{},"exceptionDetails":{"text":"Uncaught","exception":{"description":"ReferenceError: appStore is not defined"}}}}"#.utf8)
        #expect(throws: SteamCEFClient.Failure.exception("ReferenceError: appStore is not defined")) {
            try SteamCEFClient.result(of: thrown, id: 3)
        }
    }

    @Test("Every cached Windows game is on the Windows side, installed or not; a native Mac build is not")
    func windowsSide() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let steam = try tmp.makeDir("Steam")
        try FileManager.default.createDirectory(at: steam.appendingPathComponent("appcache"), withIntermediateDirectories: true)
        try AppInfoFixtures.cacheData([AppInfoFixtures.tekken, AppInfoFixtures.tlou, AppInfoFixtures.dualBuild])
            .write(to: steam.appendingPathComponent("appcache/appinfo.vdf"))
        let installer = NativeSteamInstaller(steamRoot: steam, backupDir: tmp.url, isSteamRunning: { true })
        #expect(try installer.windowsGameIDsInCache().sorted() == [1_778_820, 2_531_310])
    }
}
