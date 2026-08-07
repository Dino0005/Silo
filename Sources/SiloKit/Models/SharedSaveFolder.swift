import Foundation

/// One save directory shared between the normal Steam bottle and the Media Foundation bottle.
///
/// Stored as ROOT + NAME rather than an absolute path, deliberately. The Windows user directory inside a
/// prefix is named after whoever booted it: `crossover` for a CrossOver-derived runtime, the macOS user
/// name for a plain Wine build. Switching runtimes therefore creates a DIFFERENT user profile, and an
/// absolute path captured under the old one would point at nothing. Resolving root + name against the
/// user directory found at the time keeps the record valid across that switch.
public struct SharedSaveFolder: Codable, Sendable, Hashable, Identifiable {

    /// Where under the Windows user profile the folder lives. Games in this library keep saves in
    /// `AppData\Local`; the others are here because the picker (part 2) offers them and different games
    /// choose differently.
    public enum Root: String, Codable, Sendable, CaseIterable {
        case appDataLocal, appDataRoaming, documentsMyGames, savedGames

        /// Path relative to the Windows user directory (e.g. `drive_c/users/crossover`).
        public var relativePath: String {
            switch self {
            case .appDataLocal:     "AppData/Local"
            case .appDataRoaming:   "AppData/Roaming"
            case .documentsMyGames: "Documents/My Games"
            case .savedGames:       "Saved Games"
            }
        }
    }

    public var id: String { "\(root.rawValue)/\(name)" }
    public let root: Root
    /// Directory name as it appears on disk (e.g. `CotW`, `SoulcaliburVI`). Never a path.
    public let name: String

    public init(root: Root, name: String) {
        self.root = root
        self.name = name
    }

    /// Tolerant decode of `root`: a RAW STRING, never the enum. A strict decode of an unknown case throws,
    /// and that throw propagates out of `AppState` — `ConfigStore.load()` falls back to the .bak, fails
    /// again, and hands back a FRESH AppState with every per-game setting gone. A folder whose root this
    /// build doesn't recognise is dropped by the array decoder instead (see `GameConfig`).
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let raw = try c.decodeIfPresent(String.self, forKey: .root),
              let parsed = Root(rawValue: raw) else {
            throw DecodingError.dataCorruptedError(forKey: .root, in: c,
                                                   debugDescription: "unknown shared-save root")
        }
        root = parsed
        name = try c.decode(String.self, forKey: .name)
    }
}
