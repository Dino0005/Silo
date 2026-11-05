import Foundation

/// Which kind of game the Library shows — the toolbar's filter menu. Persisted by its raw value
/// (`@AppStorage`), so never rename a case's raw string.
public enum LibraryKindFilter: String, CaseIterable, Identifiable, Sendable {
    case all
    case steam
    case nonSteam

    public var id: String { rawValue }
}

/// One tile in the Library grid: a Steam game or a manual (non-Steam) one. Lets the two kinds share a
/// single alphabetical order instead of all Steam games first and the manual ones after.
public enum LibraryEntry: Sendable, Hashable, Identifiable {
    case steam(SteamApp)
    case manual(ManualGame)

    public var id: String {
        switch self {
        case .steam(let game): "steam-\(game.appID)"
        case .manual(let game): "manual-\(game.id.uuidString)"
        }
    }

    public var name: String {
        switch self {
        case .steam(let game): game.name
        case .manual(let game): game.name
        }
    }

    /// The entries the filter lets through, both kinds merged and sorted by name (case- and
    /// locale-aware, the same comparison the Steam and manual lists already use on their own).
    /// Ties fall back to `id` so equal names keep a stable order between redraws.
    public static func merged(steam: [SteamApp], manual: [ManualGame],
                              filter: LibraryKindFilter) -> [LibraryEntry] {
        var entries: [LibraryEntry] = []
        if filter != .nonSteam { entries += steam.map(LibraryEntry.steam) }
        if filter != .steam { entries += manual.map(LibraryEntry.manual) }
        return entries.sorted { lhs, rhs in
            switch lhs.name.localizedCaseInsensitiveCompare(rhs.name) {
            case .orderedAscending: true
            case .orderedDescending: false
            case .orderedSame: lhs.id < rhs.id
            }
        }
    }
}
