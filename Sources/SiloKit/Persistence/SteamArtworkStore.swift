import Foundation

/// Keeps Steam tile artwork on disk, under `AppPaths.artworkDir`, one file per app ID.
///
/// The tile GUESSES its image URL from the app ID (`…/steam/apps/<id>/header.jpg`) rather than asking the
/// store — fast, and it's why opening the library makes no API calls. Two things follow from that, both
/// seen on-device: some apps have no `header.jpg` at all (a 404, while their store page shows artwork
/// fine, because the page uses the `header_image` the API returns), and with no network the tiles come up
/// blank, since they depend on URLSession's cache and images are evicted long before JSON is.
///
/// A file on disk fixes both. It also has to stay CURRENT: Steam rotates seasonal art, so downloading once
/// and stopping would freeze a game's cover forever — hence the refresh, bounded by `maxAge` so a library
/// opened repeatedly doesn't re-fetch everything each time.
///
/// Separate from `Covers/` on purpose: that holds images the user picked, this is a cache the app may
/// empty without losing anything.
public struct SteamArtworkStore: Sendable {
    // Computed (not stored): FileManager isn't Sendable, but the shared instance is fine to use.
    private var fileManager: FileManager { .default }
    private let dir: URL
    /// How long a stored image is trusted before the network is asked again. A day keeps rotating art
    /// reasonably fresh while making a second library open in the same session cost nothing.
    private let maxAge: TimeInterval

    public init(dir: URL, maxAge: TimeInterval = 24 * 60 * 60) {
        self.dir = dir
        self.maxAge = maxAge
    }

    private func file(for appID: Int) -> URL {
        dir.appendingPathComponent("\(appID).jpg", isDirectory: false)
    }

    /// The stored image, or nil if there isn't one. Shown immediately, before any network work.
    public func cached(appID: Int) -> URL? {
        let url = file(for: appID)
        return fileManager.fileExists(atPath: url.path) ? url : nil
    }

    /// Whether the stored copy is old enough to be worth re-fetching. No file at all counts as stale.
    public func isStale(appID: Int, now: Date = Date()) -> Bool {
        guard let modified = try? fileManager.attributesOfItem(atPath: file(for: appID).path)[.modificationDate]
                as? Date else { return true }
        return now.timeIntervalSince(modified) > maxAge
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

    /// nil for anything that isn't a 200 with a body — a 404 has to read as "no image", not as an image.
    private static func fetch(_ url: URL, session: URLSession) async -> Data? {
        guard let (data, response) = try? await session.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200,
              !data.isEmpty else { return nil }
        return data
    }
}
