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

    @Test("a copy is fetched only when missing — age alone never triggers a download")
    func fetchedOnlyWhenMissing() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let dir = tmp.url.appendingPathComponent("Artwork")
        let store = SteamArtworkStore(dir: dir)
        #expect(store.isMissing(appID: 7))                   // nothing saved yet

        store.save(Data("JPEG".utf8), appID: 7)
        #expect(!store.isMissing(appID: 7))                  // on disk now, and stays that way

        // Deleting the file is how a user forces a fresh copy: it reads as missing again.
        try FileManager.default.removeItem(at: try #require(store.cached(appID: 7)))
        #expect(store.isMissing(appID: 7))
    }
}
