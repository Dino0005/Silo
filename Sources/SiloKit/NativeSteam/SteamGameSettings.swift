import Foundation

/// A game's Silo settings, shown and changed in the "Silo" section of the Compatibility page inside Steam for macOS
/// (`SteamCompatibilityPage`), so a Windows game installed from Steam can be set up without opening Silo (user,
/// 2026-11-20). The page is the same `GameConfig` Silo's own settings sheet edits — never a copy:
/// - the guard hands the page the current values (`snapshotScript`) whenever `config.json` changes;
/// - the page queues each change (Steam's page can't write files); the guard drains the queue (`takeChanges`) every
///   couple of seconds and writes it with `ConfigStore.updateGame`, the field-scoped update Silo itself uses.
/// A launch from Steam reads `config.json`, so what the game runs with is always what both screens show.
public enum SteamGameSettings {
    /// The settings the page carries, by the key it uses for them: the ones Silo's settings sheet has that make sense for a game started from Steam: not the launch options
    /// (Steam has its own, in General), the executable (Steam picks it), Steam presence or shared save folders (Silo's
    /// Windows Steam bottle only). Booleans travel as "1" / "0".
    public enum Field: String, CaseIterable, Sendable {
        case graphics, syncMode, advertiseAVX, metalHUD, metalFX, dxr, metalBackend, depthFix, disableHidraw
        case mediaFoundationNative, spiderMan2Fix, unchartedFix
        case dualSenseBluetoothAsWired, dualSenseRumbleOnActuators, dualSenseAsXInput
    }

    /// The page's value of `field` for `config`.
    static func value(_ field: Field, of config: GameConfig) -> String {
        let flags = config.envFlags
        func bit(_ on: Bool) -> String { on ? "1" : "0" }
        switch field {
        case .graphics: return config.graphics.rawValue
        case .syncMode: return flags.syncMode.rawValue
        case .advertiseAVX: return bit(flags.advertiseAVX)
        case .metalHUD: return bit(flags.metalHUD)
        case .metalFX: return bit(flags.metalFX)
        case .dxr: return bit(flags.dxr)
        case .metalBackend: return flags.metalBackend.rawValue
        case .depthFix: return bit(flags.depthFix)
        case .disableHidraw: return bit(flags.disableHidraw)
        case .mediaFoundationNative: return bit(flags.mediaFoundationNative)
        case .spiderMan2Fix: return bit(flags.spiderMan2Fix)
        case .unchartedFix: return bit(flags.unchartedFix)
        case .dualSenseBluetoothAsWired: return bit(flags.dualSenseBluetoothAsWired)
        case .dualSenseRumbleOnActuators: return bit(flags.dualSenseRumbleOnActuators)
        case .dualSenseAsXInput: return bit(flags.dualSenseAsXInput)
        }
    }

    /// Sets `field` to `value`; false for a value that isn't valid (left unchanged).
    static func set(_ field: Field, to value: String, in config: inout GameConfig) -> Bool {
        func bit() -> Bool? { value == "1" ? true : value == "0" ? false : nil }
        switch field {
        case .graphics:
            guard let choice = GraphicsChoice(rawValue: value) else { return false }
            config.graphics = choice
        case .syncMode:
            guard let mode = SyncMode(rawValue: value) else { return false }
            config.envFlags.syncMode = mode
        case .metalBackend:
            guard let choice = MetalBackendChoice(rawValue: value) else { return false }
            config.envFlags.metalBackend = choice
        case .advertiseAVX, .metalHUD, .metalFX, .dxr, .depthFix, .disableHidraw, .mediaFoundationNative, .spiderMan2Fix,
             .unchartedFix, .dualSenseBluetoothAsWired, .dualSenseRumbleOnActuators, .dualSenseAsXInput:
            guard let on = bit() else { return false }
            switch field {
            case .advertiseAVX: config.envFlags.advertiseAVX = on
            case .metalHUD: config.envFlags.metalHUD = on
            case .metalFX: config.envFlags.metalFX = on
            case .dxr: config.envFlags.dxr = on
            case .depthFix: config.envFlags.depthFix = on
            case .disableHidraw: config.envFlags.disableHidraw = on
            case .spiderMan2Fix: config.envFlags.spiderMan2Fix = on
            case .unchartedFix: config.envFlags.unchartedFix = on
            case .dualSenseBluetoothAsWired: config.envFlags.dualSenseBluetoothAsWired = on
            case .dualSenseRumbleOnActuators: config.envFlags.dualSenseRumbleOnActuators = on
            case .dualSenseAsXInput: config.envFlags.dualSenseAsXInput = on
            default: config.envFlags.mediaFoundationNative = on
            }
        }
        return true
    }

    private static func values(of config: GameConfig) -> [String: String] {
        var values: [String: String] = [:]
        for field in Field.allCases { values[field.rawValue] = value(field, of: config) }
        return values
    }

    /// JavaScript that hands the page every saved game's values, and the defaults a game without a saved config gets
    /// (`GameConfig`'s own). `learned` is the backend Automatic switched to (shown under the choice), when it still
    /// applies — the same rule as Play's (`learnedUnderRuntime` = the GPTK runtime in use). `mediaFoundation`: whether
    /// the Media Foundation bottle exists — the page offers its switch only then, like Silo's sheet.
    public static func snapshotScript(state: AppState, mediaFoundation: Bool) -> String {
        var games: [String: [String: String]] = [:]
        for config in state.games {
            var values = values(of: config)
            let learned = config.learnedUnderRuntime == state.backend.gptkRuntimeName ? config.learnedBackend : nil
            values["learned"] = learned?.displayName ?? ""
            games[String(config.appID)] = values
        }
        var defaults = values(of: AppState().config(for: 0))
        defaults["learned"] = ""
        let payload: [String: Any] = ["games": games, "defaults": defaults, "mediaFoundation": mediaFoundation]
        let data = (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])) ?? Data("{}".utf8)
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
