import Foundation
import Testing
@testable import SiloKit

/// Tile artwork on disk: what makes the library draw with no network, and what covers the apps whose
/// guessed `header.jpg` doesn't exist.
@Suite("Steam artwork cache")
struct SteamArtworkStoreTests {

    private let fm = FileManager.default

    @Test("a saved image is served back, and an absent one reads as nil")
    func savedImageIsServed() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let store = SteamArtworkStore(dir: tmp.url.appendingPathComponent("Artwork"))
        #expect(store.cached(appID: 1778820) == nil)

        let saved = try #require(store.save(Data("JPEG".utf8), appID: 1778820))
        #expect(try String(contentsOf: saved, encoding: .utf8) == "JPEG")
        #expect(store.cached(appID: 1778820) != nil)
        // Per app ID, so two games never collide.
        #expect(store.cached(appID: 601150) == nil)
    }

    @Test("empty data is not stored — a failed download must not become a blank tile")
    func emptyDataIsRefused() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let store = SteamArtworkStore(dir: tmp.url.appendingPathComponent("Artwork"))
        #expect(store.save(Data(), appID: 1) == nil)
        #expect(store.cached(appID: 1) == nil)
    }

    @Test("staleness is by age; a missing file is always stale")
    func stalenessByAge() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let dir = tmp.url.appendingPathComponent("Artwork")
        let store = SteamArtworkStore(dir: dir, maxAge: 60)
        #expect(store.isStale(appID: 7))                     // nothing saved yet

        store.save(Data("JPEG".utf8), appID: 7)
        #expect(!store.isStale(appID: 7))                    // just written
        // An hour later, with a one-minute budget, it's worth asking the network again.
        #expect(store.isStale(appID: 7, now: Date().addingTimeInterval(3600)))
    }
}
