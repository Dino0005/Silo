import Foundation
import Testing
@testable import SiloKit

struct SteamCompatMappingTests {
    static let config = """
    "InstallConfigStore"
    {
        "Software" { "Valve" { "Steam"
        {
            "CompatToolMapping"
            {
                "544750" { "name" "silo" "config" "" "priority" "250" }
                "1817070" { "name" "notproton-silo-26.3.0" "config" "" "priority" "250" }
                "2492040" { "name" "silo-proton" "config" "" "priority" "250" }
                "601150" { "name" "" "config" "" "priority" "250" }
            }
        } } }
    }
    """

    @Test("Reads Steam's per-game tool mappings")
    func readsMappings() {
        let m = SteamCompatMapping.mappings(configVDF: Self.config)
        #expect(m[544750] == "silo" && m[1817070] == "notproton-silo-26.3.0" && m[2492040] == "silo-proton")
        #expect(m[601150] == "")
        #expect(SteamCompatMapping.mappings(configVDF: "not a vdf {").isEmpty)
    }

    @Test("Unmapped games and games on a missing tool go to Silo; another installed tool is the user's choice")
    func choosesGames() {
        let ids = SteamCompatMapping.gamesToMap(
            windowsGames: [544750, 1817070, 2492040, 601150, 1971870],
            current: SteamCompatMapping.mappings(configVDF: Self.config),
            installedTools: ["silo", "silo-proton"])
        #expect(ids == [601150, 1817070, 1971870])
    }

    @Test("Tool names come from each tool's compatibilitytool.vdf")
    func installedTools() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        _ = try tmp.write("tools/a/compatibilitytool.vdf",
                          #""compatibilitytools" { "compat_tools" { "silo" { "display_name" "Silo" } } }"#)
        _ = try tmp.write("tools/b/readme.txt", "no tool here")
        #expect(SteamCompatMapping.installedTools(in: tmp.url.appendingPathComponent("tools")) == ["silo"])
    }

    @Test("The script maps every id through Steam's own call")
    func script() {
        let js = SteamCompatMapping.script(appIDs: [601150, 1971870])
        #expect(js.contains("[601150,1971870]") && js.contains(#"SpecifyCompatTool(id, "silo")"#))
    }
}
