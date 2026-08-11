import Foundation
import Testing
@testable import SiloKit

/// Covers are COPIED into Silo rather than referenced where the user found them, so an image taken off an
/// external drive keeps working. These pin that, plus the cleanup that stops Covers/ collecting orphans.
@Suite("Cover art store")
struct CoverArtStoreTests {

    private let fm = FileManager.default

    private func makeImage(_ url: URL, _ bytes: String) throws {
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        fm.createFile(atPath: url.path, contents: Data(bytes.utf8))
    }

    @Test("the chosen file is COPIED in, so the source can go away afterwards")
    func coverIsCopiedNotReferenced() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let store = CoverArtStore(coversDir: tmp.url.appendingPathComponent("Covers"))
        let id = UUID()
        // Stands in for an image on an external drive.
        let source = tmp.url.appendingPathComponent("Extreme Pro/art.png")
        try makeImage(source, "PNG")

        let name = try #require(store.store(source, for: id))
        #expect(name == "\(id.uuidString).png")

        // The drive goes away — the cover must not.
        try fm.removeItem(at: source.deletingLastPathComponent())
        let stored = try #require(store.url(named: name))
        #expect(try String(contentsOf: stored, encoding: .utf8) == "PNG")
    }

    @Test("a second choice REPLACES the first, whatever the extension")
    func secondChoiceReplacesTheFirst() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let covers = tmp.url.appendingPathComponent("Covers")
        let store = CoverArtStore(coversDir: covers)
        let id = UUID()

        let first = tmp.url.appendingPathComponent("a.png"); try makeImage(first, "FIRST")
        let second = tmp.url.appendingPathComponent("b.jpg"); try makeImage(second, "SECOND")
        _ = store.store(first, for: id)
        let name = try #require(store.store(second, for: id))

        #expect(name.hasSuffix(".jpg"))
        // Exactly ONE file for this game — the .png didn't linger alongside the .jpg.
        let mine = (try fm.contentsOfDirectory(atPath: covers.path)).filter { $0.hasPrefix(id.uuidString) }
        #expect(mine == [name])
    }

    @Test("a cover deleted from Finder resolves to nil — the tile falls back to the icon")
    func missingFileResolvesToNil() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let covers = tmp.url.appendingPathComponent("Covers")
        let store = CoverArtStore(coversDir: covers)
        let id = UUID()
        let source = tmp.url.appendingPathComponent("art.png"); try makeImage(source, "PNG")
        let name = try #require(store.store(source, for: id))

        try fm.removeItem(at: covers.appendingPathComponent(name))
        #expect(store.url(named: name) == nil)
        #expect(store.url(named: nil) == nil)
        #expect(store.url(named: "") == nil)
    }

    @Test("remove() clears this game's cover and leaves other games' alone")
    func removeIsScopedToTheGame() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let covers = tmp.url.appendingPathComponent("Covers")
        let store = CoverArtStore(coversDir: covers)
        let mine = UUID(), theirs = UUID()
        let source = tmp.url.appendingPathComponent("art.png"); try makeImage(source, "PNG")
        let mineName = try #require(store.store(source, for: mine))
        let theirsName = try #require(store.store(source, for: theirs))

        store.remove(for: mine)
        #expect(store.url(named: mineName) == nil)
        #expect(store.url(named: theirsName) != nil)
    }

    @Test("the file name round-trips through ManualGame's config, and its absence decodes fine")
    func fileNameRoundTrips() throws {
        let game = ManualGame(name: "Batman", executablePath: URL(fileURLWithPath: "/g/b.exe"),
                              coverArtFileName: "cover.png")
        let back = try JSONDecoder().decode(ManualGame.self, from: JSONEncoder().encode(game))
        #expect(back.coverArtFileName == "cover.png")

        // A config written before covers existed.
        let json = #"{"id":"\#(UUID().uuidString)","bottleID":"\#(UUID().uuidString)","name":"X","executablePath":"file:///g/x.exe","envFlags":{},"graphics":"auto","customArgs":[]}"#
        let legacy = try JSONDecoder().decode(ManualGame.self, from: Data(json.utf8))
        #expect(legacy.coverArtFileName == nil)
    }
}
