import Foundation

/// Rich, public Steam-store metadata for a game's detail view (description, developer, genres, art,
/// minimum system requirements incl. disk space, Metacritic, capabilities).
/// Fetched on demand (only when a detail view opens — keeps within the store API's rate limits).
public struct SteamStoreDetails: Sendable, Equatable {
    public let appID: Int
    public let shortDescription: String?
    public let developers: [String]
    public let publishers: [String]
    public let genres: [String]
    public let headerImageURL: URL?
    public let releaseDate: String?
    /// Minimum PC requirements as readable text (the source of disk-size info before install).
    public let minimumRequirements: String?
    /// The storage line pulled out of the minimum requirements, e.g. "50 GB available space".
    public let diskSpace: String?
    /// Metacritic score (0–100), when the store provides one.
    public let metacritic: Int?
}

/// Fetches `SteamStoreDetails` from the public `store.steampowered.com/api/appdetails` endpoint
/// (no key required). One app per request.
public struct SteamStoreClient: Sendable {
    private let session: URLSession
    public init(session: URLSession = .shared) { self.session = session }

    public func details(appID: Int) async -> SteamStoreDetails? {
        guard let url = URL(string: "https://store.steampowered.com/api/appdetails?appids=\(appID)&l=\(Self.steamLanguageCode)"),
              (try? DownloadGuard.requireHTTPS(url)) != nil,   // https-only, consistent with every other fetch
              let (data, _) = try? await session.data(from: url) else { return nil }
        return Self.parse(data, appID: appID)
    }

    /// Steam's store API takes its own language names (e.g. "italian", not "it"). Only English/Italian are
    /// distinguished here — Silo's own UI localization is EN/IT only (see Resources/*.lproj), so there's no
    /// broader language list to map from yet.
    static var steamLanguageCode: String {
        (Locale.preferredLanguages.first?.hasPrefix("it") ?? false) ? "italian" : "english"
    }

    /// Parse the `{ "<key>": { "success": true, "data": { … } } }` response.
    ///
    /// **The key is no longer the app id that was asked for (measured 2026-09-25).** Steam now answers
    /// under a different id for every game in the library — `appids=1817070` (Spider-Man Remastered) comes
    /// back keyed `"2083110"`, Tekken 8 `1778820` → `"4536150"`, and so on for all seven tested — so a
    /// lookup by `String(appID)` found nothing and every detail sheet came up empty, seasonal header
    /// included. The entry is identified instead by `data.steam_appid`, which still carries the id that was
    /// requested. An entry keyed by the id itself is still accepted (the old shape, and what the API may
    /// return again).
    static func parse(_ data: Data, appID: Int) -> SteamStoreDetails? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let entries = json.values.compactMap { $0 as? [String: Any] }
            .filter { $0["success"] as? Bool == true }
        let matching = entries.first { ($0["data"] as? [String: Any])?["steam_appid"] as? Int == appID }
            ?? (json[String(appID)] as? [String: Any]).flatMap { $0["success"] as? Bool == true ? $0 : nil }
        guard let d = matching?["data"] as? [String: Any] else { return nil }
        let genres = (d["genres"] as? [[String: Any]])?.compactMap { $0["description"] as? String } ?? []
        // `pc_requirements` is a dict when present, or an empty array when the store lists none.
        let minRaw = (d["pc_requirements"] as? [String: Any])?["minimum"] as? String
        let minText = minRaw.map(stripHTML).flatMap { $0.isEmpty ? nil : $0 }
        return SteamStoreDetails(
            appID: appID,
            shortDescription: (d["short_description"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
            developers: d["developers"] as? [String] ?? [],
            publishers: d["publishers"] as? [String] ?? [],
            genres: genres,
            headerImageURL: (d["header_image"] as? String).flatMap { URL(string: $0) },
            releaseDate: (d["release_date"] as? [String: Any])?["date"] as? String,
            minimumRequirements: minText,
            diskSpace: minText.flatMap(diskSpace),
            metacritic: (d["metacritic"] as? [String: Any])?["score"] as? Int)
    }

    /// Pull the storage requirement out of the minimum-requirements text (the disk-size signal).
    static func diskSpace(in requirements: String) -> String? {
        guard let line = requirements.split(separator: "\n").first(where: {
            let l = $0.lowercased()
            return l.contains("storage") || l.contains("hard drive") || l.contains("available space")
        }) else { return nil }
        let value = line.firstIndex(of: ":").map { String(line[line.index(after: $0)...]) } ?? String(line)
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Convert Steam's requirements HTML (`<ul><li><strong>OS:</strong> …`) into readable lines.
    static func stripHTML(_ html: String) -> String {
        var s = html
        for tag in ["<br>", "<br/>", "<br />", "</li>", "</p>", "</ul>"] {
            s = s.replacingOccurrences(of: tag, with: "\n", options: .caseInsensitive)
        }
        s = s.replacingOccurrences(of: "<li>", with: "• ", options: .caseInsensitive)
        s = s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        for (entity, char) in ["&amp;": "&", "&lt;": "<", "&gt;": ">", "&nbsp;": " ", "&quot;": "\"", "&#39;": "'"] {
            s = s.replacingOccurrences(of: entity, with: char)
        }
        var lines = s.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if lines.first?.lowercased() == "minimum:" { lines.removeFirst() }   // redundant with the section header
        return lines.joined(separator: "\n")
    }
}
