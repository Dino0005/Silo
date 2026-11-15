import Foundation
import Testing
@testable import SiloKit

@Suite("Steam Cloud for macOS-Steam launches: one save folder per game in SteamBottle")
struct SteamCloudSavesTests {
    static func rule(_ root: String, _ path: String) -> BinaryKVEntry {
        BinaryKVEntry("0", .map([BinaryKVEntry("root", .string(root)), BinaryKVEntry("path", .string(path)),
                                 BinaryKVEntry("pattern", .string("*.sav"))]))
    }

    @Test("The folders come from the rules' first path component; Documents and placeholders are left out")
    func foldersFromRules() {
        let rules = [
            Self.rule("WinAppDataLocal", "TEKKEN 8/Saved/SaveGames/{64BitSteamID}"),
            Self.rule("gameinstall", "CotW/Saved/SaveGames/{64BitSteamID}"),
            Self.rule("WinAppDataLocal", "CotW/Saved/SaveGames/{64BitSteamID}"),
            Self.rule("WinAppDataLocal", "CotW/Saved/Config"),                         // same folder once
            Self.rule("WinSavedGames", "Uncharted Legacy of Thieves Collection/users/{Steam3AccountId}/"),
            Self.rule("WinMyDocuments", "Marvel's Spider-Man Remastered/{64BitSteamID}/"),  // Mac Documents: shared
            Self.rule("WinAppDataRoaming", "{64BitSteamID}/saves"),                     // placeholder first
        ]
        #expect(SteamCloudSaves.folders(savefiles: rules) == [
            SharedSaveFolder(root: .appDataLocal, name: "TEKKEN 8"),
            SharedSaveFolder(root: .appDataLocal, name: "CotW"),
            SharedSaveFolder(root: .savedGames, name: "Uncharted Legacy of Thieves Collection"),
        ])
        #expect(SteamCloudSaves.folders(savefiles: nil).isEmpty)
    }

    @Test("Windows-only cloud entries become all-platform; an all-platform cache is left alone")
    func remoteCachePlatforms() {
        let cache = """
        "1778820"
        {
        \t"ChangeNumber"\t\t"4"
        \t"TEKKEN 8/Saved/SaveGames/7656/a.sav"
        \t{
        \t\t"root"\t\t"4"
        \t\t"platformstosync2"\t\t"1"
        \t}
        \t"TEKKEN 8/Saved/SaveGames/7656/b.sav"
        \t{
        \t\t"platformstosync2"\t\t"-1"
        \t}
        }
        """
        let fixed = SteamCloudSaves.allPlatforms(remoteCache: cache)
        #expect(fixed == cache.replacingOccurrences(of: "\"platformstosync2\"\t\t\"1\"", with: "\"platformstosync2\"\t\t\"-1\""))
        #expect(fixed.flatMap { SteamCloudSaves.allPlatforms(remoteCache: $0) } == nil)
        #expect(fixed?.contains("\"root\"\t\t\"4\"") == true)
    }

    /// Two prefixes with a Wine user, as the bottles have.
    static func bottles(_ tmp: TempDir) throws -> (native: URL, classic: URL) {
        _ = try tmp.write("SteamNative/drive_c/users/crossover/AppData/Local/.keep", "")
        _ = try tmp.write("SteamBottle/drive_c/users/crossover/AppData/Local/.keep", "")
        return (tmp.url.appendingPathComponent("SteamNative"), tmp.url.appendingPathComponent("SteamBottle"))
    }

    @Test("Classic side has saves: the native copy goes to the backup and becomes a link")
    func classicWins() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let (native, classic) = try Self.bottles(tmp)
        _ = try tmp.write("SteamBottle/drive_c/users/crossover/AppData/Local/TEKKEN 8/save.sav", "classic")
        _ = try tmp.write("SteamNative/drive_c/users/crossover/AppData/Local/TEKKEN 8/save.sav", "native")
        let backup = tmp.url.appendingPathComponent("Backup")
        let folder = [SharedSaveFolder(root: .appDataLocal, name: "TEKKEN 8")]
        let lines = SharedSaveLinker().linkToCanonical(folder, bottle: native, canonical: classic, backupDir: backup)
        #expect(lines.count == 1 && lines[0].contains("moved to"))
        let link = native.appendingPathComponent("drive_c/users/crossover/AppData/Local/TEKKEN 8/save.sav")
        #expect(try String(contentsOf: link, encoding: .utf8) == "classic")
        #expect(try String(contentsOf: backup.appendingPathComponent("SteamNative/AppData/Local/TEKKEN 8/save.sav"),
                           encoding: .utf8) == "native")
        // Again: already linked, nothing to do.
        #expect(SharedSaveLinker().linkToCanonical(folder, bottle: native, canonical: classic, backupDir: backup).isEmpty)
    }

    @Test("Classic side empty: the native copy becomes the classic one, then a link")
    func nativeAdopted() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let (native, classic) = try Self.bottles(tmp)
        _ = try tmp.write("SteamNative/drive_c/users/crossover/Saved Games/Uncharted/u.sav", "native")
        let backup = tmp.url.appendingPathComponent("Backup")
        let folder = [SharedSaveFolder(root: .savedGames, name: "Uncharted")]
        let lines = SharedSaveLinker().linkToCanonical(folder, bottle: native, canonical: classic, backupDir: backup)
        #expect(lines.count == 1 && lines[0].contains("became"))
        #expect(try String(contentsOf: classic.appendingPathComponent("drive_c/users/crossover/Saved Games/Uncharted/u.sav"),
                           encoding: .utf8) == "native")
        #expect(try String(contentsOf: native.appendingPathComponent("drive_c/users/crossover/Saved Games/Uncharted/u.sav"),
                           encoding: .utf8) == "native")
        #expect(!FileManager.default.fileExists(atPath: backup.path))
    }

    @Test("The classic folders are backed up once, before the first cloud launch")
    func backupOnce() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let (_, classic) = try Self.bottles(tmp)
        _ = try tmp.write("SteamBottle/drive_c/users/crossover/AppData/Local/CotW/g.sav", "v1")
        let backup = tmp.url.appendingPathComponent("Backup/2492040")
        let folder = [SharedSaveFolder(root: .appDataLocal, name: "CotW")]
        #expect(SharedSaveLinker().backUpOnce(folder, canonical: classic, backupDir: backup))
        _ = try tmp.write("SteamBottle/drive_c/users/crossover/AppData/Local/CotW/g.sav", "v2")
        #expect(!SharedSaveLinker().backUpOnce(folder, canonical: classic, backupDir: backup))
        #expect(try String(contentsOf: backup.appendingPathComponent("AppData/Local/CotW/g.sav"), encoding: .utf8) == "v1")
    }
}
