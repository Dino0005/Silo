import Foundation
import Testing
@testable import SiloKit

@Suite("Native Steam protection of installed Windows games")
struct NativeSteamGuardTests {
    /// A Windows-only game with a redistributable depot, an OS-less depot and a launch entry.
    var tekken: AppInfoCache.App { AppInfoFixtures.tekken }

    @Test("A Windows-only game gets macos on common and on every Windows depot, and its change number pinned")
    func protectsWindowsOnly() throws {
        var app = tekken
        let result = AppInfoPatcher.protectWindowsInstall(&app)
        #expect(result.changes.contains("common.oslist += macos"))
        #expect(result.changes.contains("depot 228989.oslist += macos"))
        #expect(app.info.map("common")?.string("oslist") == "windows,macos")
        #expect(app.info.map("depots")?.map("228989")?.map("config")?.string("oslist") == "windows,macos")
        #expect(app.info.map("depots")?.map("1778821")?.map("config") == nil)   // no oslist = every platform already
        #expect(app.changeNumber == AppInfoPatcher.pinnedChangeNumber)
        // Nothing else: no launch entry, no cloud rule.
        #expect(app.info.map("config")?.map("launch")?.map(AppInfoPatcher.entryKey) == nil)
        #expect(app.info.map("ufs") == tekken.info.map("ufs"))
        // Idempotent.
        let again = AppInfoPatcher.protectWindowsInstall(&app)
        #expect(!again.changed)
    }

    @Test("A native Mac build and an app without an oslist are left alone")
    func leavesOthersAlone() {
        var dual = AppInfoFixtures.dualBuild
        let dualResult = AppInfoPatcher.protectWindowsInstall(&dual)
        #expect(!dualResult.changed)
        var noOS = AppInfoCache.App(appID: 7, header: AppInfoFixtures.header(), root: [BinaryKVEntry("appinfo", .map([
            BinaryKVEntry("common", .map([BinaryKVEntry("name", .string("Any"))])),
            BinaryKVEntry("depots", .map([BinaryKVEntry("8", AppInfoFixtures.depot("windows"))])),
        ]))])
        let noOSResult = AppInfoPatcher.protectWindowsInstall(&noOS)
        #expect(!noOSResult.changed)
    }

    @Test("A game Silo already enabled is re-protected after Steam refreshed one of its depots")
    func reprotectsEnabled() {
        var app = tekken
        _ = AppInfoPatcher.enableSiloLaunch(&app, shim: "../Silo Runtime/silo-launch")
        app.info.editMap("depots") { depots in
            depots.editMap("228989") { depot in depot.editMap("config") { $0.setString("oslist", "windows") } }
        }
        let result = AppInfoPatcher.protectWindowsInstall(&app)
        #expect(result.changes.contains("depot 228989.oslist += macos"))
    }

    @Test("Every installed game in every library is swept; uninstalled ones and a running Steam are not touched")
    func sweepsInstalledGames() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let steam = try tmp.makeDir("Steam")
        let external = try tmp.makeDir("External/SteamLibrary")
        try tmp.write("Steam/steamapps/libraryfolders.vdf", """
            "libraryfolders"
            {
              "0" { "path" "\(steam.path)" "apps" { } }
              "1" { "path" "\(external.path)" "apps" { "1778820" "1" } }
            }
            """)
        try tmp.write("External/SteamLibrary/steamapps/appmanifest_1778820.acf", "\"AppState\" { }")
        try tmp.write("External/SteamLibrary/steamapps/appmanifest_203160.acf", "\"AppState\" { }")
        try FileManager.default.createDirectory(at: steam.appendingPathComponent("appcache"), withIntermediateDirectories: true)
        let cacheURL = steam.appendingPathComponent("appcache/appinfo.vdf")
        try AppInfoFixtures.cacheData([tekken, AppInfoFixtures.tlou, AppInfoFixtures.dualBuild]).write(to: cacheURL)
        let original = try Data(contentsOf: cacheURL)

        let busy = NativeSteamInstaller(steamRoot: steam, backupDir: tmp.url.appendingPathComponent("bk"),
                                        isSteamRunning: { true })
        #expect(throws: NativeSteamInstaller.Failure.steamRunning) { try busy.protectInstalledWindowsGames() }
        #expect(try Data(contentsOf: cacheURL) == original)

        let installer = NativeSteamInstaller(steamRoot: steam, backupDir: tmp.url.appendingPathComponent("bk"),
                                             isSteamRunning: { false })
        #expect(installer.installedAppIDs() == [203_160, 1_778_820])
        let changed = try installer.protectInstalledWindowsGames()
        #expect(Array(changed.keys) == [1_778_820])
        let cache = try AppInfoCache(contentsOf: cacheURL)
        #expect(try cache.app(1_778_820)?.info.map("common")?.string("oslist") == "windows,macos")
        #expect(try cache.app(2_531_310)?.root == AppInfoFixtures.tlou.root)        // not installed
        #expect(try cache.app(203_160)?.root == AppInfoFixtures.dualBuild.root)     // native Mac build
        #expect(try Data(contentsOf: installer.originalBackupURL) == original)
        // Second run: nothing to do, the file isn't rewritten.
        let stamp = try FileManager.default.attributesOfItem(atPath: cacheURL.path)[.modificationDate] as? Date
        #expect(try installer.protectInstalledWindowsGames().isEmpty)
        #expect(try FileManager.default.attributesOfItem(atPath: cacheURL.path)[.modificationDate] as? Date == stamp)
    }

    @Test("The guard protects when it starts with Steam closed and on every Steam exit, never while it runs")
    func watchEdges() {
        var watch = NativeSteamGuard.Watch()
        let samples = [false, false, true, true, false].map { watch.shouldProtect(steamRunning: $0) }
        #expect(samples == [true, false, false, false, true])   // start with Steam closed; then the quit edge
        var startedWithSteam = NativeSteamGuard.Watch()
        let fromRunning = [true, false].map { startedWithSteam.shouldProtect(steamRunning: $0) }
        #expect(fromRunning == [false, true])
    }

    @Test("The LaunchAgent runs this Silo binary's guard at login, kept alive, logging into Silo's logs")
    func launchAgent() throws {
        let data = try NativeSteamGuard.launchAgentPlist(siloExecutable: URL(fileURLWithPath: "/A/Silo.app/Contents/MacOS/Silo"),
                                                         logURL: URL(fileURLWithPath: "/L/native-steam-guard.log"))
        let plist = try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        #expect(plist["Label"] as? String == NativeSteamGuard.label)
        #expect(plist["ProgramArguments"] as? [String] == ["/A/Silo.app/Contents/MacOS/Silo", "--native-steam-guard"])
        #expect(plist["RunAtLoad"] as? Bool == true)
        #expect(plist["KeepAlive"] as? Bool == true)
        #expect(plist["StandardOutPath"] as? String == "/L/native-steam-guard.log")
        #expect(NativeSteamGuard.launchAgentURL(home: URL(fileURLWithPath: "/Users/x")).path
                == "/Users/x/Library/LaunchAgents/com.mikael.silo.native-steam-guard.plist")
    }
}
