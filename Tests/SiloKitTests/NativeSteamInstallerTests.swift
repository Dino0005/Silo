import Foundation
import Testing
@testable import SiloKit

@Suite("NativeSteamInstaller")
struct NativeSteamInstallerTests {
    /// A fake macOS Steam folder: a library list naming one extra library that exists and one that doesn't,
    /// and an appinfo cache holding TEKKEN 8 and The Last of Us Part II.
    func fakeSteam(_ tmp: TempDir) throws -> (steam: URL, external: URL, missing: URL) {
        let steam = try tmp.makeDir("Steam")
        let external = try tmp.makeDir("External/SteamLibrary")
        let missing = tmp.url.appendingPathComponent("Unplugged/SteamLibrary")
        try tmp.write("Steam/steamapps/libraryfolders.vdf", """
            "libraryfolders"
            {
              "0" { "path" "\(steam.path)" "apps" { } }
              "1" { "path" "\(external.path)" "apps" { "1778820" "1" } }
              "2" { "path" "\(missing.path)" "apps" { } }
            }
            """)
        try FileManager.default.createDirectory(at: steam.appendingPathComponent("appcache"),
                                                withIntermediateDirectories: true)
        try AppInfoFixtures.cacheData([AppInfoFixtures.tekken, AppInfoFixtures.tlou])
            .write(to: steam.appendingPathComponent("appcache/appinfo.vdf"))
        return (steam, external, missing)
    }

    @Test("The launcher hands Steam's arguments to Silo's headless mode, quoting the path")
    func launcherScript() {
        let script = NativeSteamInstaller.launcherScript(
            siloExecutable: URL(fileURLWithPath: "/Applications/Dino's Silo.app/Contents/MacOS/Silo"))
        #expect(script.hasPrefix("#!/bin/bash\n"))
        #expect(script.contains("exec '/Applications/Dino'\\''s Silo.app/Contents/MacOS/Silo' --steam-launch \"$@\""))
        #expect(NativeSteamInstaller.launcherRelativePath == "../Silo Runtime/silo-launch")
    }

    @Test("The launcher lands, executable, in every reachable library; an unplugged one is reported")
    func installsInEveryLibrary() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let (steam, external, missing) = try fakeSteam(tmp)
        let installer = NativeSteamInstaller(steamRoot: steam, backupDir: tmp.url.appendingPathComponent("bk"),
                                             isSteamRunning: { false })
        let result = try installer.installLauncher(siloExecutable: URL(fileURLWithPath: "/S/Silo"))
        #expect(result.installed.map(\.path).sorted() == [
            "\(external.path)/steamapps/common/Silo Runtime/silo-launch",
            "\(steam.path)/steamapps/common/Silo Runtime/silo-launch",
        ].sorted())
        #expect(result.unreachable.map(\.path) == [missing.path])
        #expect(!FileManager.default.fileExists(atPath: missing.path))
        let perms = try FileManager.default.attributesOfItem(atPath: result.installed[0].path)[.posixPermissions] as? Int
        #expect(perms == 0o755)
    }

    @Test("Nothing is written while Steam runs")
    func refusesWhileSteamRuns() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let (steam, _, _) = try fakeSteam(tmp)
        let before = try Data(contentsOf: steam.appendingPathComponent("appcache/appinfo.vdf"))
        let installer = NativeSteamInstaller(steamRoot: steam, backupDir: tmp.url.appendingPathComponent("bk"),
                                             isSteamRunning: { true })
        #expect(throws: NativeSteamInstaller.Failure.steamRunning) {
            try installer.patch([.init(appID: 1_778_820)])
        }
        #expect(try Data(contentsOf: steam.appendingPathComponent("appcache/appinfo.vdf")) == before)
        #expect(!FileManager.default.fileExists(atPath: tmp.url.appendingPathComponent("bk").path))
    }

    @Test("Patching backs up Steam's original once, edits only the requested games, and skips unknown ones")
    func patches() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let (steam, _, _) = try fakeSteam(tmp)
        let cacheURL = steam.appendingPathComponent("appcache/appinfo.vdf")
        let original = try Data(contentsOf: cacheURL)
        let installer = NativeSteamInstaller(steamRoot: steam, backupDir: tmp.url.appendingPathComponent("bk"),
                                             isSteamRunning: { false })
        let results = try installer.patch([
            .init(appID: 1_778_820, cloudUserFolderFromHome: "B/drive_c/users/crossover"),
            .init(appID: 42),
        ])
        #expect(results[1_778_820]?.changed == true)
        #expect(results[42] == nil)
        #expect(try Data(contentsOf: installer.originalBackupURL) == original)

        let cache = try AppInfoCache(contentsOf: cacheURL)
        let tekken = try #require(try cache.app(1_778_820))
        #expect(tekken.info.map("config")?.map("launch")?.map("9000")?.string("executable") == "../Silo Runtime/silo-launch")
        #expect(tekken.info.map("ufs")?.map("rootoverrides")?.map("0")?.string("addpath") == "B/drive_c/users/crossover/AppData/Local")
        #expect(tekken.changeNumber == AppInfoFixtures.tekken.changeNumber)   // Steam's own number is kept
        #expect(try cache.app(2_531_310)?.root == AppInfoFixtures.tlou.root)   // not requested, untouched

        // A second run keeps the FIRST backup — Steam's untouched cache — not the already-patched one.
        try installer.patch([.init(appID: 2_531_310)])
        #expect(try Data(contentsOf: installer.originalBackupURL) == original)
        #expect(try AppInfoCache(contentsOf: cacheURL).app(2_531_310)?.info.map("config")?.map("launch")?.map("9000") != nil)
    }
}
