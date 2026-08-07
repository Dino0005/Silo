import Foundation
import Testing
@testable import SiloKit

/// The MF bottle is a clone, so a game played on both sides ends up with two separate save sets. These
/// cover the linker that prevents that — and, above all, that it never destroys a populated directory.
@Suite("Shared saves")
struct SharedSaveLinkerTests {

    private let fm = FileManager.default

    /// Build a prefix with a Windows user profile, and return its user dir.
    @discardableResult
    private func makePrefix(_ url: URL, user: String) throws -> URL {
        let dir = url.appendingPathComponent("drive_c/users/\(user)", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        // Windows' shared profile — present in every real prefix and never the user.
        try fm.createDirectory(at: url.appendingPathComponent("drive_c/users/Public"),
                               withIntermediateDirectories: true)
        return dir
    }

    private func local(_ user: URL, _ name: String) -> URL {
        user.appendingPathComponent("AppData/Local/\(name)", isDirectory: true)
    }

    // MARK: - the user directory is discovered, not assumed

    @Test("the Windows user dir is found whatever it's called, and Public is never it")
    func userDirIsDiscovered() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let linker = SharedSaveLinker()

        // CrossOver-derived runtime.
        let cx = tmp.url.appendingPathComponent("CX")
        try makePrefix(cx, user: "crossover")
        #expect(linker.windowsUserDir(inPrefix: cx)?.lastPathComponent == "crossover")

        // Plain Wine names it after the macOS user — the case a hard-coded "crossover" would break on.
        let plain = tmp.url.appendingPathComponent("Plain")
        try makePrefix(plain, user: "dinoguidone")
        #expect(linker.windowsUserDir(inPrefix: plain)?.lastPathComponent == "dinoguidone")

        // Never booted.
        #expect(linker.windowsUserDir(inPrefix: tmp.url.appendingPathComponent("Nope")) == nil)
    }

    // MARK: - the three outcomes

    @Test("an absent folder is linked, and the target is created when it doesn't exist yet")
    func absentFolderIsLinked() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let canonical = tmp.url.appendingPathComponent("SteamBottle")
        let mf = tmp.url.appendingPathComponent("SteamBottleMF")
        let canonicalUser = try makePrefix(canonical, user: "crossover")
        try makePrefix(mf, user: "crossover")

        let folder = SharedSaveFolder(root: .appDataLocal, name: "CotW")
        let blocked = SharedSaveLinker().ensure([folder], mfPrefix: mf, canonicalPrefix: canonical)
        #expect(blocked.isEmpty)

        // Target created (the brand-new-profile case), and the MF side is a link to it.
        #expect(fm.fileExists(atPath: local(canonicalUser, "CotW").path))
        let mfUser = try #require(SharedSaveLinker().windowsUserDir(inPrefix: mf))
        let destination = try fm.destinationOfSymbolicLink(atPath: local(mfUser, "CotW").path)
        #expect(URL(fileURLWithPath: destination).resolvingSymlinksInPath()
                == local(canonicalUser, "CotW").resolvingSymlinksInPath())
    }

    @Test("an already-correct link is left alone (the hand-made links keep working untouched)")
    func correctLinkIsUntouched() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let canonical = tmp.url.appendingPathComponent("SteamBottle")
        let mf = tmp.url.appendingPathComponent("SteamBottleMF")
        let canonicalUser = try makePrefix(canonical, user: "crossover")
        let mfUser = try makePrefix(mf, user: "crossover")

        // Exactly the shape of the links made by hand: an absolute symlink into the normal bottle.
        let target = local(canonicalUser, "SoulcaliburVI")
        try fm.createDirectory(at: target, withIntermediateDirectories: true)
        fm.createFile(atPath: target.appendingPathComponent("save.dat").path, contents: Data("S".utf8))
        let link = local(mfUser, "SoulcaliburVI")
        try fm.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: link, withDestinationURL: target)

        let folder = SharedSaveFolder(root: .appDataLocal, name: "SoulcaliburVI")
        #expect(SharedSaveLinker().ensure([folder], mfPrefix: mf, canonicalPrefix: canonical).isEmpty)
        // Still a link, still pointing at the same place, save still there.
        let destination = try fm.destinationOfSymbolicLink(atPath: link.path)
        #expect(URL(fileURLWithPath: destination).resolvingSymlinksInPath()
                == target.resolvingSymlinksInPath())
        #expect(fm.fileExists(atPath: target.appendingPathComponent("save.dat").path))
    }

    @Test("a POPULATED directory on the MF side is refused, never deleted")
    func populatedDirectoryIsNeverDestroyed() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let canonical = tmp.url.appendingPathComponent("SteamBottle")
        let mf = tmp.url.appendingPathComponent("SteamBottleMF")
        try makePrefix(canonical, user: "crossover")
        let mfUser = try makePrefix(mf, user: "crossover")

        // Saves that exist ONLY here. Silo cannot know whether they're copied anywhere else.
        let real = local(mfUser, "CotW")
        try fm.createDirectory(at: real, withIntermediateDirectories: true)
        fm.createFile(atPath: real.appendingPathComponent("save.dat").path, contents: Data("MF".utf8))

        let folder = SharedSaveFolder(root: .appDataLocal, name: "CotW")
        let blocked = SharedSaveLinker().ensure([folder], mfPrefix: mf, canonicalPrefix: canonical)
        #expect(blocked == [folder])
        // Untouched: still a real directory, save still readable.
        let attributes = try fm.attributesOfItem(atPath: real.path)
        #expect(attributes[.type] as? FileAttributeType == .typeDirectory)
        #expect(try String(contentsOf: real.appendingPathComponent("save.dat"), encoding: .utf8) == "MF")
    }

    @Test("an EMPTY directory is replaced by the link — there is nothing to lose")
    func emptyDirectoryIsReplaced() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let canonical = tmp.url.appendingPathComponent("SteamBottle")
        let mf = tmp.url.appendingPathComponent("SteamBottleMF")
        try makePrefix(canonical, user: "crossover")
        let mfUser = try makePrefix(mf, user: "crossover")
        try fm.createDirectory(at: local(mfUser, "CotW"), withIntermediateDirectories: true)

        let folder = SharedSaveFolder(root: .appDataLocal, name: "CotW")
        #expect(SharedSaveLinker().ensure([folder], mfPrefix: mf, canonicalPrefix: canonical).isEmpty)
        let attributes = try fm.attributesOfItem(atPath: local(mfUser, "CotW").path)
        #expect(attributes[.type] as? FileAttributeType == .typeSymbolicLink)
    }

    // MARK: - the record survives a runtime change

    @Test("root + name resolves against WHATEVER user dir each prefix has")
    func recordSurvivesARuntimeChange() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let canonical = tmp.url.appendingPathComponent("SteamBottle")
        let mf = tmp.url.appendingPathComponent("SteamBottleMF")
        // Both prefixes re-booted under a plain Wine build: the profile is now the macOS user name.
        let canonicalUser = try makePrefix(canonical, user: "dinoguidone")
        try makePrefix(mf, user: "dinoguidone")

        let folder = SharedSaveFolder(root: .appDataLocal, name: "CotW")
        #expect(SharedSaveLinker().ensure([folder], mfPrefix: mf, canonicalPrefix: canonical).isEmpty)
        #expect(fm.fileExists(atPath: local(canonicalUser, "CotW").path))
    }

    // MARK: - config round-trip

    @Test("sharedSaveFolders round-trips, and an unknown root drops just that entry")
    func configDecodeIsLossyNotFatal() throws {
        let config = GameConfig(appID: 1, sharedSaveFolders: [
            SharedSaveFolder(root: .appDataLocal, name: "CotW"),
            SharedSaveFolder(root: .documentsMyGames, name: "Whatever"),
        ])
        let data = try JSONEncoder().encode(config)
        let back = try JSONDecoder().decode(GameConfig.self, from: data)
        #expect(back.sharedSaveFolders == config.sharedSaveFolders)

        // A root written by some future build. The entry goes; the config does NOT.
        let json = #"{"appID":2,"sharedSaveFolders":[{"root":"appDataLocal","name":"CotW"},{"root":"martianDrive","name":"X"}]}"#
        let salvaged = try JSONDecoder().decode(GameConfig.self, from: Data(json.utf8))
        #expect(salvaged.sharedSaveFolders.map(\.name) == ["CotW"])
        #expect(salvaged.appID == 2)
    }
}
