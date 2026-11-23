import Foundation
import Testing
@testable import SiloKit

@Suite("Native Steam protection of installed Windows games")
struct NativeSteamGuardTests {
    /// A Windows-only game with a redistributable depot, an OS-less depot and a launch entry.
    var tekken: AppInfoCache.App { AppInfoFixtures.tekken }

    @Test("A Windows-only game gets macos on common and on every Windows depot, its change number untouched")
    func protectsWindowsOnly() throws {
        var app = tekken
        let result = AppInfoPatcher.protectWindowsInstall(&app)
        #expect(result.changes.contains("common.oslist += macos"))
        #expect(result.changes.contains("depot 228989.oslist += macos"))
        #expect(app.info.map("common")?.string("oslist") == "windows,macos")
        #expect(app.info.map("common")?.string("osextended") == "macos64")   // no red 32-bit banner
        #expect(app.info.map("depots")?.map("228989")?.map("config")?.string("oslist") == "windows,macos")
        #expect(app.info.map("depots")?.map("1778821")?.map("config") == nil)   // no oslist = every platform already
        #expect(app.changeNumber == tekken.changeNumber)
        // Nothing else: no launch entry, no cloud rule.
        #expect(app.info.map("config")?.map("launch")?.map(AppInfoPatcher.entryKey) == nil)
        #expect(app.info.map("ufs") == tekken.info.map("ufs"))
        // Idempotent.
        let again = AppInfoPatcher.protectWindowsInstall(&app)
        #expect(!again.changed)
    }

    @Test("A game protected before osextended existed gets macos64 on the next pass, and nothing else")
    func upgradesOlderProtection() {
        var app = tekken
        app.info.editMap("common") { $0.setString("oslist", "windows,macos") }
        app.info.editMap("depots") { depots in
            depots.editMap("228989") { depot in depot.editMap("config") { $0.setString("oslist", "windows,macos") } }
        }
        let result = AppInfoPatcher.protectWindowsInstall(&app)
        #expect(result.changes.first == "common.osextended += macos64")
        #expect(!result.changes.contains("common.oslist += macos"))
    }

    @Test("A Mac-only launch entry counts as a native Mac build even without a Mac depot")
    func nativeByLaunchEntry() {
        var app = AppInfoCache.App(appID: 220, header: AppInfoFixtures.header(), root: [BinaryKVEntry("appinfo", .map([
            BinaryKVEntry("common", .map([BinaryKVEntry("oslist", .string("windows,macos,linux"))])),
            BinaryKVEntry("config", .map([BinaryKVEntry("launch", .map([
                BinaryKVEntry("0", AppInfoFixtures.launch("hl2.exe", os: "windows")),
                BinaryKVEntry("1", AppInfoFixtures.launch("hl2_osx", os: "macos")),
            ]))])),
            BinaryKVEntry("depots", .map([BinaryKVEntry("221", AppInfoFixtures.depot(nil))])),
        ]))])
        let result = AppInfoPatcher.protectWindowsInstall(&app)
        #expect(!result.changed)
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

    @Test("A protected-only game gets Silo's launch entry on the next pass (Play would exec the .exe otherwise)")
    func protectedGameGetsLaunchEntry() throws {
        var app = tekken
        _ = AppInfoPatcher.protectWindowsInstall(&app)
        #expect(app.info.map("config")?.map("launch")?.map(AppInfoPatcher.entryKey) == nil)
        let result = AppInfoPatcher.enableSiloLaunch(&app, shim: "../Silo Runtime/silo-launch")
        #expect(result.changes.contains("launch 9000 -> ../Silo Runtime/silo-launch"))
        #expect(app.info.map("config")?.map("launch")?.map("9000")?.string("arguments") == "--appid 1778820 --exe \"TEKKEN 8.exe\"")
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
                == "/Users/x/Library/LaunchAgents/io.github.dino0005.silo.native-steam-guard.plist")
    }

    // MARK: - Restart after a Silo update

    @Test("The guard restarts once its binary has been replaced and left alone for a few seconds")
    func restartsAfterUpdate() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let old = NativeSteamGuard.BinaryIdentity(inode: 1, size: 100, modified: now.addingTimeInterval(-86_400))
        let new = NativeSteamGuard.BinaryIdentity(inode: 2, size: 120, modified: now.addingTimeInterval(-30))
        #expect(NativeSteamGuard.shouldRestartForUpdate(started: old, now: new, at: now))
        // Same file: keep running.
        #expect(!NativeSteamGuard.shouldRestartForUpdate(started: old, now: old, at: now))
        // Mid-update: the file is missing, or still being written.
        #expect(!NativeSteamGuard.shouldRestartForUpdate(started: old, now: nil, at: now))
        let fresh = NativeSteamGuard.BinaryIdentity(inode: 2, size: 120, modified: now.addingTimeInterval(-1))
        #expect(!NativeSteamGuard.shouldRestartForUpdate(started: old, now: fresh, at: now))
        // Unknown at start (couldn't read it): never restart on a guess.
        #expect(!NativeSteamGuard.shouldRestartForUpdate(started: nil, now: new, at: now))
    }

    @Test("A replaced file reads as a different identity")
    func identityOfAReplacedFile() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let url = tmp.url.appendingPathComponent("Silo")
        try Data("v1".utf8).write(to: url)
        let first = try #require(NativeSteamGuard.BinaryIdentity.of(url))
        #expect(NativeSteamGuard.BinaryIdentity.of(url) == first)
        try FileManager.default.removeItem(at: url)
        #expect(NativeSteamGuard.BinaryIdentity.of(url) == nil)
        try Data("version 2".utf8).write(to: url)
        #expect(NativeSteamGuard.BinaryIdentity.of(url) != first)
    }
}
