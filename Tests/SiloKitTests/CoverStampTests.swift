import Foundation
import Testing
@testable import SiloKit

/// The key a manual game's tile uses for its cover — both the cache's key and the `.task` id, so what it
/// has to get right is noticing that the FILE changed while its path didn't.
@Suite("Cover stamp")
@MainActor
struct CoverStampTests {

    @Test("the same file reads as the same stamp")
    func stableForAnUnchangedFile() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let cover = try tmp.write("cover.png", "pretend this is a PNG")
        #expect(ManualIconCache.coverStamp(cover) == ManualIconCache.coverStamp(cover))
        #expect(!ManualIconCache.coverStamp(cover).isEmpty)
    }

    @Test("a cover replaced at the same path reads as a different stamp")
    func changesWhenTheFileIsReplaced() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        // `CoverArtStore` names a cover after the game, so a second pick with the same extension
        // overwrites this very path — the case a path-only key would serve stale forever.
        let cover = try tmp.write("cover.png", "the first choice")
        let first = ManualIconCache.coverStamp(cover)
        try tmp.write("cover.png", "a second choice, of a different length entirely")
        #expect(ManualIconCache.coverStamp(cover) != first)
    }

    @Test("no cover, and a cover deleted from Finder, share one empty stamp")
    func emptyWithoutAFile() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        #expect(ManualIconCache.coverStamp(nil).isEmpty)
        #expect(ManualIconCache.coverStamp(tmp.url.appendingPathComponent("gone.png")).isEmpty)
    }
}
