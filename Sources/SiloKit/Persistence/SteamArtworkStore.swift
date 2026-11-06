import Foundation

/// Keeps Steam tile artwork on disk, under `AppPaths.artworkDir`, one file per app ID.
///
/// The tile GUESSES its image URL from the app ID (`…/steam/apps/<id>/header.jpg`) rather than asking the
/// store — fast, and it's why opening the library makes no API calls. Two things follow from that, both
/// seen on-device: some apps have no `header.jpg` at all (a 404, while their store page shows artwork
/// fine, because the page uses the `header_image` the API returns), and with no network the tiles come up
/// blank, since they depend on URLSession's cache and images are evicted long before JSON is.
///
/// A file on disk fixes both, and it is fetched once: only when it isn't there.
///
/// An earlier version refreshed it every 24 hours on the grounds that "Steam rotates seasonal art". That
/// was true of the wrong image. The tile asks for the GUESSED `…/apps/<id>/header.jpg` first — the base
/// art, which doesn't rotate — and reaches for the API's `header_image` only on a 404. The seasonal one is
/// the API's, and that's what the game's detail page shows, straight from the API. So the tile was
/// re-downloading an identical file daily.
///
/// To force a new copy — the developer redid the base art, say — delete the file: absence is the one
/// condition that triggers a download.
///
/// Separate from `Covers/` on purpose: that holds images the user picked, this is a cache the app may
/// empty without losing anything.
public struct SteamArtworkStore: Sendable {
    // Computed (not stored): FileManager isn't Sendable, but the shared instance is fine to use.
    private var fileManager: FileManager { .default }
    private let dir: URL

    public init(dir: URL) {
        self.dir = dir
    }

    private func file(for appID: Int) -> URL {
        dir.appendingPathComponent("\(appID).jpg", isDirectory: false)
    }

    /// The stored image, or nil if there isn't one. Shown immediately, before any network work.
    public func cached(appID: Int) -> URL? {
        let url = file(for: appID)
        return fileManager.fileExists(atPath: url.path) ? url : nil
    }

    /// Whether there's no stored copy — the only case in which the network is asked. See the type's note:
    /// the image kept here is the base art, which doesn't change on a schedule, so age is no reason to refetch.
    public func isMissing(appID: Int) -> Bool {
        !fileManager.fileExists(atPath: file(for: appID).path)
    }

    @discardableResult
    public func save(_ data: Data, appID: Int) -> URL? {
        guard !data.isEmpty else { return nil }
        do {
            try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
            try data.write(to: file(for: appID), options: .atomic)
            return file(for: appID)
        } catch {
            return nil          // a cache that can't be written is a missing image, not a failure
        }
    }

    /// Fetch and store the artwork, returning the file — or nil, leaving any existing file untouched.
    ///
    /// Tries the guessed URL first, since that's the one that works for nearly every app and costs no API
    /// call. Only if it doesn't resolve does it ask the store for the real `header_image`: one request, for
    /// the few apps that need it, and the answer lands on disk so it isn't asked again.
    public func refresh(appID: Int, guessed: URL?, store: SteamStoreClient,
                        session: URLSession = .shared) async -> URL? {
        if let guessed, let data = await Self.fetch(guessed, session: session) {
            return save(data, appID: appID)
        }
        guard let details = await store.details(appID: appID),
              let real = details.headerImageURL, real != guessed,
              let data = await Self.fetch(real, session: session) else { return nil }
        return save(data, appID: appID)
    }

    // MARK: Portrait (2:3) covers, for the Portrait tile style

    private func portraitFile(for appID: Int) -> URL {
        dir.appendingPathComponent("\(appID)-portrait.jpg", isDirectory: false)
    }

    /// The stored portrait cover, or nil. Kept next to the header, under its own name.
    public func cachedPortrait(appID: Int) -> URL? {
        let url = portraitFile(for: appID)
        return fileManager.fileExists(atPath: url.path) ? url : nil
    }

    /// The CDN's portrait cover: the `_2x` (600×900) first, then the plain 300×450 — the same images the Steam
    /// client caches, but reachable for games that aren't in the bottle's Steam account (a manual game tied
    /// to an app ID). Stored once; nil when neither exists (newer apps only have hashed asset URLs).
    public func refreshPortrait(appID: Int, session: URLSession = .shared) async -> URL? {
        for name in ["library_600x900_2x.jpg", "library_600x900.jpg"] {
            guard let url = URL(string: "https://cdn.cloudflare.steamstatic.com/steam/apps/\(appID)/\(name)"),
                  let data = await Self.fetch(url, session: session) else { continue }
            do {
                try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
                try data.write(to: portraitFile(for: appID), options: .atomic)
                return portraitFile(for: appID)
            } catch {
                return nil
            }
        }
        return nil
    }

    /// nil for anything that isn't a 200 with a body — a 404 has to read as "no image", not as an image.
    private static func fetch(_ url: URL, session: URLSession) async -> Data? {
        guard let (data, response) = try? await session.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200,
              !data.isEmpty else { return nil }
        return data
    }
}
