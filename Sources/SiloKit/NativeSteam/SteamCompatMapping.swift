import Foundation

/// Silo's compatibility tool as the default for every installed Windows game (user, 2026-11-13, after the tool was
/// tried game by game: SOULCALIBUR VI, TEKKEN 8, FATAL FURY, TLOU II, Spider-Man, UNCHARTED, RE Requiem).
///
/// Steam keeps each game's tool in `config/config.vdf` → `CompatToolMapping`. A game gets `SiloCompatTool.name` when it
/// has no tool, or one that is no longer installed (the old NotProton tools gave "OS Error 0" on Play); a game the user
/// mapped to another tool that exists keeps it. The guard applies it through Steam's own
/// `SteamClient.Apps.SpecifyCompatTool` in its SharedJSContext (`SteamCEFClient`) — Steam writes the file itself.
public enum SteamCompatMapping {
    /// Pure: the `CompatToolMapping` entries of a `config.vdf` text, app id → tool name.
    public static func mappings(configVDF text: String) -> [UInt32: String] {
        guard let root = try? KeyValuesParser().parse(text: text), let section = find("CompatToolMapping", in: root)
        else { return [:] }
        var result: [UInt32: String] = [:]
        for pair in section.pairs {
            if let id = UInt32(pair.key), let name = pair.value["name"]?.stringValue { result[id] = name }
        }
        return result
    }

    private static func find(_ key: String, in node: KVNode) -> KVNode? {
        if let hit = node[key] { return hit }
        for pair in node.pairs { if let hit = find(key, in: pair.value) { return hit } }
        return nil
    }

    /// Pure: the games to put on Silo's tool.
    public static func gamesToMap(windowsGames: Set<UInt32>, current: [UInt32: String],
                                  installedTools: Set<String>) -> [UInt32] {
        windowsGames.filter { id in
            guard let tool = current[id], !tool.isEmpty else { return true }
            return tool != SiloCompatTool.name && !installedTools.contains(tool)
        }.sorted()
    }

    /// The tool names under `compatibilitytools.d` (each tool's `compatibilitytool.vdf` names it).
    public static func installedTools(in toolsDir: URL, fileManager: FileManager = .default) -> Set<String> {
        var names: Set<String> = []
        for dir in (try? fileManager.contentsOfDirectory(at: toolsDir, includingPropertiesForKeys: nil)) ?? [] {
            guard let text = try? String(contentsOf: dir.appendingPathComponent("compatibilitytool.vdf"), encoding: .utf8),
                  let tools = (try? KeyValuesParser().parse(text: text)).flatMap({ find("compat_tools", in: $0) })
            else { continue }
            tools.pairs.forEach { names.insert($0.key) }
        }
        return names
    }

    /// JavaScript that maps `appIDs` to Silo's tool and answers how many it mapped.
    public static func script(appIDs: [UInt32]) -> String {
        "(() => { const ids = [\(appIDs.map(String.init).joined(separator: ","))]; "
            + "ids.forEach(id => SteamClient.Apps.SpecifyCompatTool(id, \"\(SiloCompatTool.name)\")); "
            + "return 'mapped ' + ids.length; })()"
    }
}
