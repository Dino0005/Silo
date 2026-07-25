import Foundation
import Testing
@testable import SiloKit

@Suite("DiscoveryEngine")
struct DiscoveryEngineTests {

    /// Build a temp Steam tree with the given manifests under `<root>/steamapps`.
    private func makeSteamRoot(_ tmp: TempDir, named: String, manifests: [String]) throws -> URL {
        let root = try tmp.makeDir(named)
        for fixture in manifests {
            try tmp.write("\(named)/steamapps/\(fixture)", try FixtureLoader.text(fixture))
        }
        return root
    }

    @Test("Discovers games from the primary library, sorted by name")
    func primaryLibrary() async throws {
        let tmp = try TempDir()
        let steamRoot = try makeSteamRoot(tmp, named: "Steam",
                                          manifests: ["appmanifest_220.acf", "appmanifest_570.acf"])
        let apps = try await DiscoveryEngine().discoverGames(steamRoot: steamRoot)
        #expect(apps.map(\.name) == ["Dota 2", "Half-Life 2"])     // alphabetical
        #expect(apps.first(where: { $0.appID == 220 })?.libraryPath == steamRoot)
    }

    @Test("Includes additional libraries from libraryfolders.vdf")
    func additionalLibraries() async throws {
        let tmp = try TempDir()
        let steamRoot = try makeSteamRoot(tmp, named: "Steam", manifests: ["appmanifest_220.acf"])
        let secondRoot = try makeSteamRoot(tmp, named: "Lib2", manifests: ["appmanifest_570.acf"])

        let vdf = """
        "libraryfolders"
        {
            "0" { "path" "\(steamRoot.path)" "apps" { "220" "1" } }
            "1" { "path" "\(secondRoot.path)" "apps" { "570" "1" } }
        }
        """
        try tmp.write("Steam/steamapps/libraryfolders.vdf", vdf)

        let apps = try await DiscoveryEngine().discoverGames(steamRoot: steamRoot)
        #expect(Set(apps.map(\.appID)) == [220, 570])
        #expect(apps.first(where: { $0.appID == 570 })?.libraryPath.standardizedFileURL == secondRoot.standardizedFileURL)
    }

    @Test("A Windows-style library path (X:\\SteamLibrary) resolves through the bottle's dosdevices symlink")
    func windowsDriveLibrary() async throws {
        let tmp = try TempDir()
        let steamRoot = try makeSteamRoot(tmp, named: "bottle/drive_c/Program Files (x86)/Steam",
                                          manifests: ["appmanifest_220.acf"])
        let bottlePrefix = tmp.url.appendingPathComponent("bottle")
        // The real external volume the "X:" drive points at, with a SteamLibrary folder on it.
        let externalVolume = try tmp.makeDir("ExternalSSD")
        let libRoot = try makeSteamRoot(tmp, named: "ExternalSSD/SteamLibrary", manifests: ["appmanifest_570.acf"])
        try FileManager.default.createDirectory(
            at: bottlePrefix.appendingPathComponent("dosdevices"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            atPath: bottlePrefix.appendingPathComponent("dosdevices/x:").path,
            withDestinationPath: externalVolume.path)

        let vdf = """
        "libraryfolders"
        {
            "0" { "path" "\(steamRoot.path)" "apps" { "220" "1" } }
            "1" { "path" "X:\\\\SteamLibrary" "apps" { "570" "1" } }
        }
        """
        try tmp.write("bottle/drive_c/Program Files (x86)/Steam/steamapps/libraryfolders.vdf", vdf)

        let apps = try await DiscoveryEngine().discoverGames(steamRoot: steamRoot, bottlePrefix: bottlePrefix)
        #expect(Set(apps.map(\.appID)) == [220, 570])
        #expect(apps.first(where: { $0.appID == 570 })?.libraryPath.standardizedFileURL == libRoot.standardizedFileURL)
    }

    @Test("A Windows-style library path is silently skipped when no bottlePrefix is supplied (back-compat)")
    func windowsDriveLibraryWithoutPrefix() async throws {
        let tmp = try TempDir()
        let steamRoot = try makeSteamRoot(tmp, named: "Steam", manifests: ["appmanifest_220.acf"])
        let vdf = """
        "libraryfolders"
        {
            "0" { "path" "\(steamRoot.path)" "apps" { "220" "1" } }
            "1" { "path" "X:\\\\SteamLibrary" "apps" { "570" "1" } }
        }
        """
        try tmp.write("Steam/steamapps/libraryfolders.vdf", vdf)

        let apps = try await DiscoveryEngine().discoverGames(steamRoot: steamRoot)
        #expect(apps.map(\.appID) == [220])   // the X: entry can't be resolved without a prefix — skipped
    }

    @Test("an oversized libraryfolders.vdf is skipped (not slurped into memory); its extra libraries are ignored")
    func oversizedLibraryFoldersSkipped() async throws {
        let tmp = try TempDir()
        let steamRoot = try makeSteamRoot(tmp, named: "Steam", manifests: ["appmanifest_220.acf"])
        let secondRoot = try makeSteamRoot(tmp, named: "Lib2", manifests: ["appmanifest_570.acf"])
        let vdf = """
        "libraryfolders"
        {
            "0" { "path" "\(steamRoot.path)" "apps" { "220" "1" } }
            "1" { "path" "\(secondRoot.path)" "apps" { "570" "1" } }
        }
        """ + String(repeating: "\n", count: 150_000)   // pad the VDF past the cap below (whitespace is ignored)
        try tmp.write("Steam/steamapps/libraryfolders.vdf", vdf)

        // Cap between the small primary manifest and the padded VDF: the VDF is over-cap, so it's not read.
        let apps = try await DiscoveryEngine(maxManifestBytes: 100_000).discoverGames(steamRoot: steamRoot)
        #expect(apps.map(\.appID) == [220])   // only the primary library — the oversized VDF's extra lib is ignored
    }

    @Test("Skips malformed manifests without failing the scan")
    func skipsMalformed() async throws {
        let tmp = try TempDir()
        let steamRoot = try makeSteamRoot(tmp, named: "Steam",
                                          manifests: ["appmanifest_220.acf", "appmanifest_malformed.acf"])
        let apps = try await DiscoveryEngine().discoverGames(steamRoot: steamRoot)
        #expect(apps.map(\.appID) == [220])
    }

    @Test("Throws libraryUnreadable when the primary steamapps exists but can't be listed")
    func unreadablePrimaryLibrary() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let steamRoot = try makeSteamRoot(tmp, named: "Steam", manifests: ["appmanifest_220.acf"])
        let steamapps = steamRoot.appendingPathComponent("steamapps")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: steamapps.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: steamapps.path)
        }
        await #expect(throws: DiscoveryEngine.DiscoveryError.libraryUnreadable(steamapps)) {
            try await DiscoveryEngine().discoverGames(steamRoot: steamRoot)
        }
    }

    @Test("Throws when the steamapps directory is missing")
    func missingSteamapps() async throws {
        let tmp = try TempDir()
        let steamRoot = try tmp.makeDir("EmptySteam")
        await #expect(throws: DiscoveryEngine.DiscoveryError.self) {
            try await DiscoveryEngine().discoverGames(steamRoot: steamRoot)
        }
    }

    @Test("Excludes shared system packages (Steamworks Common Redistributables, LastOwner 0)")
    func excludesRedistributables() async throws {
        let tmp = try TempDir()
        // A real owned game (220) alongside the auto-installed redistributables package (228980).
        let steamRoot = try makeSteamRoot(tmp, named: "Steam",
            manifests: ["appmanifest_220.acf", "appmanifest_228980.acf"])
        let apps = try await DiscoveryEngine().discoverGames(steamRoot: steamRoot)
        #expect(apps.map(\.appID) == [220])                       // 228980 hidden — not a game
        #expect(!apps.contains { $0.name == "Steamworks Common Redistributables" })
    }

    @Test("228980 is excluded even when Steam wrote a real SteamID64 to LastOwner instead of 0 (observed in practice)")
    func excludesRedistributablesEvenWithRealLastOwner() {
        let real = SteamApp(appID: 228980, name: "Steamworks Common Redistributables",
                             installDir: "Steamworks Shared", stateFlags: .init(rawValue: 4), sizeOnDisk: 142_521_834,
                             lastOwner: 76_561_199_838_832_905, libraryPath: URL(fileURLWithPath: "/x"))
        #expect(real.isSharedSystemApp)
    }
}
