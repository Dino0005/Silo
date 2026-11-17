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
    @Test("Restoring puts Steam's own entry back from an untouched cache, only for the given ids")
    func restoresOriginal() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let (steam, _, _) = try fakeSteam(tmp)
        let cacheURL = steam.appendingPathComponent("appcache/appinfo.vdf")
        let pristine = tmp.url.appendingPathComponent("pristine.vdf")
        try FileManager.default.copyItem(at: cacheURL, to: pristine)
        let installer = NativeSteamInstaller(steamRoot: steam, backupDir: tmp.url.appendingPathComponent("bk"),
                                             isSteamRunning: { false })
        try installer.patch([.init(appID: 1_778_820), .init(appID: 2_531_310)])
        #expect(try installer.restoreOriginal([2_531_310, 42], from: pristine) == [2_531_310])
        let cache = try AppInfoCache(contentsOf: cacheURL)
        #expect(try cache.app(2_531_310)?.root == AppInfoFixtures.tlou.root)
        #expect(try cache.app(1_778_820)?.info.map("config")?.map("launch")?.map("9000") != nil)   // still enabled
        let busy = NativeSteamInstaller(steamRoot: steam, backupDir: tmp.url.appendingPathComponent("bk"),
                                        isSteamRunning: { true })
        #expect(throws: NativeSteamInstaller.Failure.steamRunning) { try busy.restoreOriginal([1_778_820], from: pristine) }
    }

    @Test("New games go to the first reachable external library, else Steam's own folder")
    func defaultLibrary() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let (steam, external, _) = try fakeSteam(tmp)
        let installer = NativeSteamInstaller(steamRoot: steam, backupDir: tmp.url.appendingPathComponent("bk"),
                                             isSteamRunning: { false })
        #expect(installer.defaultGameLibrary() == external)
        try FileManager.default.removeItem(at: external)
        #expect(installer.defaultGameLibrary() == steam)
    }

    @Test("prepareInstall writes a placeholder manifest in the chosen library and protects + enables the game")
    func preparesInstall() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let (steam, external, missing) = try fakeSteam(tmp)
        let cacheURL = steam.appendingPathComponent("appcache/appinfo.vdf")
        let installer = NativeSteamInstaller(steamRoot: steam, backupDir: tmp.url.appendingPathComponent("bk"),
                                             isSteamRunning: { false })
        let outcome = try installer.prepareInstall(1_778_820, in: external)
        let manifest = external.appendingPathComponent("steamapps/appmanifest_1778820.acf")
        guard case .prepared(let url, let changes) = outcome else { Issue.record("not prepared: \(outcome)"); return }
        #expect(url == manifest)
        #expect(changes.contains("launch 9000 -> ../Silo Runtime/silo-launch"))
        // Steam's own parser shape: Silo's manifest decoder reads it back as "update required", nothing on disk.
        let app = try AppManifestDecoder().decode(text: String(contentsOf: manifest, encoding: .utf8),
                                                  libraryPath: external)
        #expect(app.appID == 1_778_820 && app.name == "TEKKEN 8" && app.installDir == "TEKKEN 8")
        #expect(app.sizeOnDisk == 0)
        let cache = try AppInfoCache(contentsOf: cacheURL)
        #expect(try cache.app(1_778_820)?.info.map("common")?.string("oslist") == "windows,macos")
        #expect(try cache.app(2_531_310)?.root == AppInfoFixtures.tlou.root)        // untouched
        // Already there (in any library): nothing written, the existing one is reported.
        #expect(try installer.prepareInstall(1_778_820, in: steam) == .alreadyInLibrary(manifest))
        #expect(!FileManager.default.fileExists(atPath: steam.appendingPathComponent("steamapps/appmanifest_1778820.acf").path))
        #expect(throws: NativeSteamInstaller.Failure.libraryUnreachable(missing)) {
            try installer.prepareInstall(2_531_310, in: missing)
        }
        #expect(throws: NativeSteamInstaller.Failure.notInCache(42)) { try installer.prepareInstall(42, in: external) }
    }

    @Test("prepareInstall falls back to the app id for a nameless entry and refuses Mac games and a running Steam")
    func prepareInstallEdges() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let (steam, external, _) = try fakeSteam(tmp)
        try AppInfoFixtures.cacheData([AppInfoFixtures.tlou, AppInfoFixtures.dualBuild])
            .write(to: steam.appendingPathComponent("appcache/appinfo.vdf"))
        let installer = NativeSteamInstaller(steamRoot: steam, backupDir: tmp.url.appendingPathComponent("bk"),
                                             isSteamRunning: { false })
        #expect(throws: NativeSteamInstaller.Failure.notAWindowsGame(203_160)) {
            try installer.prepareInstall(203_160, in: external)
        }
        try installer.prepareInstall(2_531_310, in: external)
        let text = try String(contentsOf: external.appendingPathComponent("steamapps/appmanifest_2531310.acf"),
                              encoding: .utf8)
        #expect(text.contains("\"name\"\t\t\"App 2531310\"") && text.contains("\"installdir\"\t\t\"App 2531310\""))
        let busy = NativeSteamInstaller(steamRoot: steam, backupDir: tmp.url.appendingPathComponent("bk"),
                                        isSteamRunning: { true })
        #expect(throws: NativeSteamInstaller.Failure.steamRunning) { try busy.prepareInstall(2_531_310, in: external) }
    }

    @Test("Quotes and backslashes in a game's name are escaped in the manifest")
    func placeholderEscapes() {
        let text = NativeSteamInstaller.placeholderManifest(appID: 1, name: #"A "B" \ C"#, installDir: "D")
        #expect(text.contains("\"name\"\t\t\"A \\\"B\\\" \\\\ C\""))
    }
}
