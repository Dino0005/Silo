import Foundation
import Testing
@testable import SiloKit

/// The picker's list: what it offers, in what order, and — the part that matters — which entries it flags
/// as already having saves on both sides.
@Suite("Shared save candidates")
struct SharedSaveCandidatesTests {

    private let fm = FileManager.default

    @discardableResult
    private func makeUser(_ prefix: URL) throws -> URL {
        let dir = prefix.appendingPathComponent("drive_c/users/crossover", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @discardableResult
    private func makeFolder(_ user: URL, _ root: String, _ name: String,
                            file: String? = nil, modified: Date? = nil) throws -> URL {
        let dir = user.appendingPathComponent("\(root)/\(name)", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        if let file {
            fm.createFile(atPath: dir.appendingPathComponent(file).path, contents: Data("x".utf8))
        }
        if let modified {
            try fm.setAttributes([.modificationDate: modified], ofItemAtPath: dir.path)
        }
        return dir
    }

    @Test("both roots are listed, newest first")
    func listsBothRootsNewestFirst() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let canonical = tmp.url.appendingPathComponent("SteamBottle")
        let mf = tmp.url.appendingPathComponent("SteamBottleMF")
        let canonicalUser = try makeUser(canonical)
        try makeUser(mf)

        // Names the filter does NOT exclude — what gets dropped is covered by the exclusion tests below.
        let old = Date(timeIntervalSince1970: 1_000_000)
        let recent = Date(timeIntervalSince1970: 2_000_000)
        try makeFolder(canonicalUser, "AppData/Local", "TEKKEN 8", modified: old)
        try makeFolder(canonicalUser, "AppData/Local", "CotW", modified: recent)
        try makeFolder(canonicalUser, "AppData/Roaming", "MK1", modified: old)

        let list = SharedSaveCandidates().candidates(mfPrefix: mf, canonicalPrefix: canonical)
        #expect(Set(list.map(\.folder.name)) == ["TEKKEN 8", "CotW", "MK1"])
        // The folder a game just wrote to is the one being looked for, so it leads.
        #expect(list.first?.folder.name == "CotW")
        #expect(list.contains { $0.folder.root == .appDataRoaming })
    }

    @Test("presence says which bottle each folder is in")
    func presenceIsReported() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let canonical = tmp.url.appendingPathComponent("SteamBottle")
        let mf = tmp.url.appendingPathComponent("SteamBottleMF")
        let canonicalUser = try makeUser(canonical)
        let mfUser = try makeUser(mf)

        try makeFolder(canonicalUser, "AppData/Local", "OnlySteam")
        try makeFolder(mfUser, "AppData/Local", "OnlyMF")
        try makeFolder(canonicalUser, "AppData/Local", "Shared")
        try makeFolder(mfUser, "AppData/Local", "Shared")

        let list = SharedSaveCandidates().candidates(mfPrefix: mf, canonicalPrefix: canonical)
        let byName = Dictionary(uniqueKeysWithValues: list.map { ($0.folder.name, $0.presence) })
        #expect(byName["OnlySteam"] == .canonicalOnly)
        #expect(byName["OnlyMF"] == .mediaFoundationOnly)
        #expect(byName["Shared"] == .both)
    }

    @Test("REAL content on both sides is flagged divergent; an existing symlink is not")
    func divergenceIsFlagged() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let canonical = tmp.url.appendingPathComponent("SteamBottle")
        let mf = tmp.url.appendingPathComponent("SteamBottleMF")
        let canonicalUser = try makeUser(canonical)
        let mfUser = try makeUser(mf)

        // Played on both sides — two save sets, and Silo must not merge them. The two files must really
        // DIFFER: `makeFolder(file:)` writes identical bytes, which is the cloned-bottle case and reads as
        // not divergent (see `identicalCopiesAreNotDivergent`).
        let mk1Canonical = try makeFolder(canonicalUser, "AppData/Local", "MK1")
        fm.createFile(atPath: mk1Canonical.appendingPathComponent("save.dat").path,
                      contents: Data("canonical".utf8))
        let mk1MF = try makeFolder(mfUser, "AppData/Local", "MK1")
        fm.createFile(atPath: mk1MF.appendingPathComponent("save.dat").path, contents: Data("mf".utf8))

        // Already linked by hand: the MF side IS the canonical one, so there is nothing to reconcile.
        let target = try makeFolder(canonicalUser, "AppData/Local", "SoulcaliburVI", file: "save.dat")
        let link = mfUser.appendingPathComponent("AppData/Local/SoulcaliburVI")
        try fm.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: link, withDestinationURL: target)

        // Present on both sides but EMPTY on the MF side — nothing to lose, so not divergent.
        try makeFolder(canonicalUser, "AppData/Local", "Tekken8", file: "save.dat")
        try makeFolder(mfUser, "AppData/Local", "Tekken8")

        let list = SharedSaveCandidates().candidates(mfPrefix: mf, canonicalPrefix: canonical)
        let byName = Dictionary(uniqueKeysWithValues: list.map { ($0.folder.name, $0) })
        #expect(byName["MK1"]?.divergent == true)
        #expect(byName["SoulcaliburVI"]?.divergent == false)
        #expect(byName["SoulcaliburVI"]?.presence == .both)
        #expect(byName["Tekken8"]?.divergent == false)
    }

    @Test("identical copies are NOT flagged divergent — the freshly-cloned-bottle case")
    func identicalCopiesAreNotDivergent() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let canonical = tmp.url.appendingPathComponent("SteamBottle")
        let mf = tmp.url.appendingPathComponent("SteamBottleMF")
        let canonicalUser = try makeUser(canonical)
        let mfUser = try makeUser(mf)

        // Cloned: same contents on both sides.
        try makeFolder(canonicalUser, "AppData/Local", "SoulcaliburVI", file: "save.dat")
        try makeFolder(mfUser, "AppData/Local", "SoulcaliburVI", file: "save.dat")
        // Played on both sides: genuinely different.
        let a = try makeFolder(canonicalUser, "AppData/Local", "MK1")
        fm.createFile(atPath: a.appendingPathComponent("save.dat").path, contents: Data("A".utf8))
        let b = try makeFolder(mfUser, "AppData/Local", "MK1")
        fm.createFile(atPath: b.appendingPathComponent("save.dat").path, contents: Data("B".utf8))

        let list = SharedSaveCandidates().candidates(mfPrefix: mf, canonicalPrefix: canonical)
        let byName = Dictionary(uniqueKeysWithValues: list.map { ($0.folder.name, $0) })
        #expect(byName["SoulcaliburVI"]?.divergent == false)
        #expect(byName["SoulcaliburVI"]?.presence == .both)
        #expect(byName["MK1"]?.divergent == true)
    }

    @Test("infrastructure folders are dropped — the list reads as the game list")
    func noiseFoldersAreExcluded() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let canonical = tmp.url.appendingPathComponent("SteamBottle")
        let mf = tmp.url.appendingPathComponent("SteamBottleMF")
        let canonicalUser = try makeUser(canonical)
        try makeUser(mf)

        // The real contents of this library's AppData\Local.
        for name in ["Temp", "CEF", "Steam", "Microsoft", "UnrealEngine"] {
            try makeFolder(canonicalUser, "AppData/Local", name)
        }
        for name in ["SoulcaliburVI", "CotW", "TEKKEN 8"] {
            try makeFolder(canonicalUser, "AppData/Local", name)
        }
        try makeFolder(canonicalUser, "AppData/Roaming", "Microsoft")

        let list = SharedSaveCandidates().candidates(mfPrefix: mf, canonicalPrefix: canonical)
        #expect(Set(list.map(\.folder.name)) == ["SoulcaliburVI", "CotW", "TEKKEN 8"])
        // Roaming held only Microsoft, so that section disappears entirely.
        #expect(!list.contains { $0.folder.root == .appDataRoaming })
    }

    @Test("matching is case-insensitive (neither Wine nor Steam is consistent)")
    func exclusionIsCaseInsensitive() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let canonical = tmp.url.appendingPathComponent("SteamBottle")
        let mf = tmp.url.appendingPathComponent("SteamBottleMF")
        let canonicalUser = try makeUser(canonical)
        try makeUser(mf)
        try makeFolder(canonicalUser, "AppData/Local", "TEMP")
        try makeFolder(canonicalUser, "AppData/Local", "unrealengine")
        try makeFolder(canonicalUser, "AppData/Local", "CotW")

        let list = SharedSaveCandidates().candidates(mfPrefix: mf, canonicalPrefix: canonical)
        #expect(list.map(\.folder.name) == ["CotW"])
    }

    @Test("an ALREADY-CHOSEN folder is listed even when its name is excluded")
    func chosenFolderSurvivesTheFilter() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let canonical = tmp.url.appendingPathComponent("SteamBottle")
        let mf = tmp.url.appendingPathComponent("SteamBottleMF")
        let canonicalUser = try makeUser(canonical)
        try makeUser(mf)
        try makeFolder(canonicalUser, "AppData/Local", "Steam")
        try makeFolder(canonicalUser, "AppData/Local", "CotW")

        // Suppose a later release adds a name that turns out to be wrong, and someone had already chosen
        // that folder. It must NOT vanish from the picker — that would read as the saves being gone.
        let chosen = SharedSaveFolder(root: .appDataLocal, name: "Steam")
        let list = SharedSaveCandidates().candidates(
            mfPrefix: mf, canonicalPrefix: canonical, keeping: [chosen])
        #expect(Set(list.map(\.folder.name)) == ["Steam", "CotW"])

        // Same folder, NOT chosen: filtered as usual.
        let without = SharedSaveCandidates().candidates(mfPrefix: mf, canonicalPrefix: canonical)
        #expect(without.map(\.folder.name) == ["CotW"])
    }

    @Test("a prefix that was never booted yields an empty list instead of failing")
    func unbootedPrefixIsEmpty() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let list = SharedSaveCandidates().candidates(
            mfPrefix: tmp.url.appendingPathComponent("A"),
            canonicalPrefix: tmp.url.appendingPathComponent("B"))
        #expect(list.isEmpty)
    }
}
