import Foundation

/// A game's Silo settings, shown and changed in the "Silo" section of the Compatibility page inside Steam for macOS
/// (`SteamCompatibilityPage`), so a Windows game installed from Steam can be set up without opening Silo (user,
/// 2026-11-20). The page is the same `GameConfig` Silo's own settings sheet edits — never a copy:
/// - the guard hands the page the current values (`snapshotScript`) whenever `config.json` changes;
/// - the page queues each change (Steam's page can't write files); the guard drains the queue (`takeChanges`) every
///   couple of seconds and writes it with `ConfigStore.updateGame`, the field-scoped update Silo itself uses.
/// A launch from Steam reads `config.json`, so what the game runs with is always what both screens show.
public enum SteamGameSettings {
    /// The settings the page carries, by the key it uses for them.
    public enum Field: String, CaseIterable, Sendable {
        case graphics
    }

    /// The page's value of `field` for `config`.
    static func value(_ field: Field, of config: GameConfig) -> String {
        switch field {
        case .graphics: config.graphics.rawValue
        }
    }

    /// Sets `field` to `value`; false for a value that isn't valid (left unchanged).
    static func set(_ field: Field, to value: String, in config: inout GameConfig) -> Bool {
        switch field {
        case .graphics:
            guard let choice = GraphicsChoice(rawValue: value) else { return false }
            config.graphics = choice
        }
        return true
    }

    /// JavaScript that hands the page every saved game's values. A game without a saved config gets the defaults on
    /// the page (`GameConfig`'s). `learned` is the backend Automatic switched to (shown under the choice), when it
    /// still applies — the same rule as Play's (`learnedUnderRuntime` = the GPTK runtime in use).
    public static func snapshotScript(state: AppState) -> String {
        var games: [String: [String: String]] = [:]
        for config in state.games {
            var values: [String: String] = [:]
            for field in Field.allCases { values[field.rawValue] = value(field, of: config) }
            let learned = config.learnedUnderRuntime == state.backend.gptkRuntimeName ? config.learnedBackend : nil
            values["learned"] = learned?.displayName ?? ""
            games[String(config.appID)] = values
        }
        let data = (try? JSONSerialization.data(withJSONObject: games, options: [.sortedKeys])) ?? Data("{}".utf8)
        let json = String(data: data, encoding: .utf8) ?? "{}"
        return "String(!!(window.__siloCompat && window.__siloCompat.setSettings && window.__siloCompat.setSettings(\(json))))"
    }

    /// JavaScript that returns (as JSON) and clears the changes made on the page.
    public static let takeChanges =
        "JSON.stringify(window.__siloCompat && window.__siloCompat.takeChanges ? window.__siloCompat.takeChanges() : [])"

    public struct Change: Decodable, Sendable, Equatable {
        public let appid: Int
        public let key: String
        public let value: String
    }

    /// The changes in `takeChanges`' reply; anything unreadable is no change.
    public static func changes(fromReply reply: String) -> [Change] {
        guard let data = reply.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([Change].self, from: data)) ?? []
    }

    /// Applies the changes of one game, in order. Returns one line per applied change, for the log; an unknown key
    /// or invalid value is skipped.
    public static func apply(_ changes: [Change], to config: inout GameConfig) -> [String] {
        changes.compactMap { change in
            guard change.appid == config.appID, let field = Field(rawValue: change.key),
                  set(field, to: change.value, in: &config) else { return nil }
            return "settings \(change.appid): \(change.key) = \(change.value)"
        }
    }
}
