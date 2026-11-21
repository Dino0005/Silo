import Foundation
import Testing
@testable import SiloKit

struct SteamCompatibilityPageTests {
    @Test("The script carries the tools and both game lists, with nothing left to fill")
    func script() throws {
        let js = SteamCompatibilityPage.script(tools: [(name: "silo-proton", display: "Silo"), (name: "x", display: "A \"quoted\" tool")],
                                               windowsOnly: [1778820], windowsBuild: [391220, 1778820])
        #expect(!js.contains("__SILO_"))
        #expect(js.contains("S.version = \(SteamCompatibilityPage.version);"))
        #expect(js.contains(#"S.tools = [["silo-proton","Silo"],["x","A \"quoted\" tool"]];"#))
        #expect(js.contains("S.winOnly = new Set([1778820]);"))
        #expect(js.contains("S.win = new Set([391220,1778820]);"))
        // What the page relies on in Steam (measured 2026-11-20).
        for needle in ["g_PopupManager.GetPopups()", "SteamClient.Apps.SpecifyCompatTool(appid, select.value)",
                       "RegisterForAppDetails", "strCompatToolName", "#AppProperties_CompatibilityPage",
                       "#AppProperties_Compat_SelectTool", "#Settings_SteamPlay_DefaultToolEntry_Fallback",
                       "/\\/properties\\/general$/"] {
            #expect(js.contains(needle), "\(needle)")
        }
        #expect(SteamCompatibilityPage.probe.contains("version === \(SteamCompatibilityPage.version)"))
        #expect(SteamCompatibilityPage.pause(true).contains("pause(true)"))
    }

    @Test("Installed tools come with the name Steam shows, sorted by it")
    func toolList() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        func tool(_ dir: String, _ name: String, _ display: String?) throws {
            let shown = display.map { "\"display_name\" \"\($0)\"" } ?? ""
            _ = try tmp.write("\(dir)/compatibilitytool.vdf", """
                "compatibilitytools" { "compat_tools" { "\(name)" { "install_path" "." \(shown) } } }
                """)
        }
        try tool("silo-proton", "silo-proton", "Silo")
        try tool("cx", "crossover-26", "CrossOver 26")
        try tool("bare", "bare-tool", nil)
        _ = try tmp.write("notatool/readme.txt", "x")
        let list = SteamCompatMapping.installedToolList(in: tmp.url)
        #expect(list.map(\.name) == ["bare-tool", "crossover-26", "silo-proton"])
        #expect(list.map(\.display) == ["bare-tool", "CrossOver 26", "Silo"])
    }

    @Test("Both scripts carry the known app ids and ask Steam about any other game (one bought since Steam started)")
    func liveClassification() {
        let page = SteamCompatibilityPage.script(tools: [], windowsOnly: [1], windowsBuild: [1, 2], known: [1, 2, 3])
        let filters = SteamLibraryFilters.script(windowsOnly: [1], windowsBuild: [1, 2], known: [1, 2, 3])
        for js in [page, filters] {
            #expect(js.contains("S.known = new Set([1,2,3]);"))
            #expect(js.contains("S.classify = appid =>"))
            #expect(js.contains("SteamClient.Apps.RegisterForAppDetails(appid, finish)"))
            #expect(!js.contains("__SILO_"))
        }
        #expect(page.contains("await S.classify(appid);"))
        #expect(filters.contains("S.classify(this.appid).then("))
    }
}

