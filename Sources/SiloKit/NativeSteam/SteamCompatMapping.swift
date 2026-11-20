import Foundation

/// Silo's compatibility tool as the default for every installed Windows game (user, 2026-11-13, after the tool was
/// tried game by game: SOULCALIBUR VI, TEKKEN 8, FATAL FURY, TLOU II, Spider-Man, UNCHARTED, RE Requiem).
///
/// Steam keeps each game's tool in `config/config.vdf` → `CompatToolMapping`. A game gets `SiloCompatTool.name` when it
/// has no tool, or one that is no longer installed (the old NotProton tools gave "OS Error 0" on Play); a game the user
/// mapped to another tool that exists keeps it. The guard applies it through Steam's own
/// `SteamClient.Apps.SpecifyCompatTool` in its SharedJSContext (`SteamCEFClient`) — Steam writes the file itself.
public enum SteamCompatMapping {
    /// Apps Steam installs next to the games that aren't games: Steamworks Common Redistributables. Mapped like the
    /// games (Proton does the same; the tool does nothing for its install scripts) but not counted as one.
    public static let notGames: Set<UInt32> = [228980]

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
            names.formUnion(toolNames(inToolDir: dir))
        }
        return names
    }

    /// The tools in `compatibilitytools.d`, as (name, name Steam shows), sorted by the name shown — the choices of
    /// Silo's Compatibility page (`SteamCompatibilityPage`).
    public static func installedToolList(in toolsDir: URL, fileManager: FileManager = .default) -> [(name: String, display: String)] {
        var list: [String: String] = [:]
        for dir in (try? fileManager.contentsOfDirectory(at: toolsDir, includingPropertiesForKeys: nil)) ?? [] {
            guard let text = try? String(contentsOf: dir.appendingPathComponent("compatibilitytool.vdf"), encoding: .utf8),
                  let tools = (try? KeyValuesParser().parse(text: text)).flatMap({ find("compat_tools", in: $0) })
            else { continue }
            for pair in tools.pairs { list[pair.key] = pair.value["display_name"]?.stringValue ?? pair.key }
        }
        return list.map { (name: $0.key, display: $0.value) }
            .sorted { ($0.display.localizedLowercase, $0.name) < ($1.display.localizedLowercase, $1.name) }
    }

    /// The names one tool folder declares.
    static func toolNames(inToolDir dir: URL) -> Set<String> {
        guard let text = try? String(contentsOf: dir.appendingPathComponent("compatibilitytool.vdf"), encoding: .utf8),
              let tools = (try? KeyValuesParser().parse(text: text)).flatMap({ find("compat_tools", in: $0) })
        else { return [] }
        return Set(tools.pairs.map(\.key))
    }

    /// Pure: `config.vdf` text without the `CompatToolMapping` entries whose tool is in `tools` — everything else
    /// byte for byte. Steam must be closed when the result is written (it rewrites the file on exit).
    public static func removingMappings(to tools: Set<String>, in text: String) -> String {
        let chars = Array(text.unicodeScalars)
        guard let sectionKey = text.range(of: "\"CompatToolMapping\"") else { return text }
        var i = text.unicodeScalars.distance(from: text.unicodeScalars.startIndex, to: sectionKey.upperBound)
        func skipSpace() { while i < chars.count, chars[i].properties.isWhitespace { i += 1 } }
        func quoted() -> String? {
            guard i < chars.count, chars[i] == "\"" else { return nil }
            var value = String.UnicodeScalarView(); i += 1
            while i < chars.count, chars[i] != "\"" {
                if chars[i] == "\\", i + 1 < chars.count { i += 1 }
                value.append(chars[i]); i += 1
            }
            i += 1
            return String(value)
        }
        // The end of the `{ … }` block starting at `i`.
        func blockEnd() -> Int? {
            var depth = 0, inQuote = false, j = i
            while j < chars.count {
                let c = chars[j]
                if inQuote { if c == "\\" { j += 1 } else if c == "\"" { inQuote = false } }
                else if c == "\"" { inQuote = true }
                else if c == "{" { depth += 1 }
                else if c == "}" { depth -= 1; if depth == 0 { return j + 1 } }
                j += 1
            }
            return nil
        }
        skipSpace()
        guard i < chars.count, chars[i] == "{", let sectionEnd = blockEnd() else { return text }
        i += 1
        var cuts: [Range<Int>] = []
        while true {
            // An entry runs from the start of its line (indentation included) to the end of its block's line.
            var lineStart = i
            skipSpace()
            guard i < sectionEnd - 1, chars[i] == "\"" else { break }
            while lineStart < i, chars[lineStart] == "\n" || chars[lineStart] == "\r" { lineStart += 1 }
            guard quoted() != nil else { break }
            skipSpace()
            guard i < chars.count, chars[i] == "{", let end = blockEnd() else { break }
            let body = String(String.UnicodeScalarView(chars[i..<end]))
            i = end
            let name = (try? KeyValuesParser().parse(text: "\"x\" " + body))?["x"]?["name"]?.stringValue
            if let name, tools.contains(name) {
                var stop = end
                while stop < chars.count, chars[stop] == " " || chars[stop] == "\t" { stop += 1 }
                if stop < chars.count, chars[stop] == "\r" { stop += 1 }
                if stop < chars.count, chars[stop] == "\n" { stop += 1 }
                cuts.append(lineStart..<stop)
                i = stop
            }
        }
        guard !cuts.isEmpty else { return text }
        var out = String.UnicodeScalarView(), from = 0
        for cut in cuts { out.append(contentsOf: chars[from..<cut.lowerBound]); from = cut.upperBound }
        out.append(contentsOf: chars[from...])
        return String(out)
    }

    /// JavaScript that maps `appIDs` to Silo's tool and answers how many it mapped.
    public static func script(appIDs: [UInt32]) -> String {
        "(() => { const ids = [\(appIDs.map(String.init).joined(separator: ","))]; "
            + "ids.forEach(id => SteamClient.Apps.SpecifyCompatTool(id, \"\(SiloCompatTool.name)\")); "
            + "return 'mapped ' + ids.length; })()"
    }
}
