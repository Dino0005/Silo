import Foundation
import Testing
@testable import SiloKit

struct LegacyIdentifiersTests {
    private static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()

    @Test("Every identifier Silo writes starts with the fork's own; upstream's is gone from the app and the hook")
    func identifiers() throws {
        #expect(Silo.bundleID == "io.github.dino0005.silo")
        for id in [GameHostBundle.bundleIDPrefix, GameHostBundle.gameAppIDPrefix, GameShortcut.bundleIDPrefix,
                   SteamLauncherApp.bundleIdentifier, NativeSteamGuard.label] {
            #expect(id.hasPrefix(Silo.bundleID + "."), "\(id)")
        }
        // The files the Swift constants can't reach spell the same identifiers.
        let template = try String(contentsOf: Self.root.appendingPathComponent("Resources/Info.plist.template"), encoding: .utf8)
        #expect(template.contains("<string>\(Silo.bundleID)</string>"))
        #expect(template.contains("<string>\(Silo.bundleID).deeplink</string>"))
        let shortcuts = try String(contentsOf: Self.root.appendingPathComponent("Scripts/steam-hook/shortcuts.m"), encoding: .utf8)
        #expect(shortcuts.contains("@\"\(GameHostBundle.gameAppIDPrefix)\"") && shortcuts.contains("@\"\(GameHostBundle.bundleIDPrefix)\""))
        let activation = try String(contentsOf: Self.root.appendingPathComponent("Scripts/steam-hook/activation.m"), encoding: .utf8)
        #expect(activation.contains("@\"\(GameHostBundle.gameAppIDPrefix)\""))
        for text in [template, shortcuts, activation] { #expect(!text.contains(LegacyIdentifiers.appID)) }
    }

    @Test("The old preferences are copied once; a key the new domain has wins")
    func preferences() throws {
        let suite = "silo-test-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("portrait", forKey: "libraryTileStyle")
        let legacy: [String: Any] = ["onboardingDone": true, "libraryTileStyle": "icons", "libraryKindFilter": "steam"]
        #expect(LegacyIdentifiers.migratePreferences(into: defaults, legacy: legacy) == ["libraryKindFilter", "onboardingDone"])
        #expect(defaults.bool(forKey: "onboardingDone"))
        #expect(defaults.string(forKey: "libraryTileStyle") == "portrait")
        // Never again, even if the old domain still has more.
        #expect(LegacyIdentifiers.migratePreferences(into: defaults, legacy: ["other": 1]).isEmpty)
        #expect(defaults.object(forKey: "other") == nil)
    }

    @Test("Nothing to copy: the migration is still marked done")
    func noLegacyPreferences() throws {
        let suite = "silo-test-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(LegacyIdentifiers.migratePreferences(into: defaults, legacy: nil).isEmpty)
        #expect(LegacyIdentifiers.migratePreferences(into: defaults, legacy: ["onboardingDone": true]).isEmpty)
    }

    @Test("The old guard is stopped and removed, and the old launcher's grant cleared; without its file, only stopped")
    func retireGuard() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let without = FakeProcessRunner()
        #expect(await !LegacyIdentifiers.retireGuard(home: tmp.url, runner: without))
        #expect(without.invocations.map(\.arguments) == [["bootout", "gui/\(getuid())/com.mikael.silo.native-steam-guard"]])
        let runner = FakeProcessRunner()
        let agent = try tmp.write("Library/LaunchAgents/com.mikael.silo.native-steam-guard.plist", "<plist/>")
        let ours = try tmp.write("Library/LaunchAgents/\(NativeSteamGuard.label).plist", "<plist/>")
        #expect(await LegacyIdentifiers.retireGuard(home: tmp.url, runner: runner))
        #expect(!FileManager.default.fileExists(atPath: agent.path))
        #expect(FileManager.default.fileExists(atPath: ours.path))
        #expect(runner.invocations.map(\.arguments) == [
            ["bootout", "gui/\(getuid())/com.mikael.silo.native-steam-guard"],
            ["reset", "Accessibility", "com.mikael.silo.steam-launcher"],
        ])
    }

    private static let gpu = "16777235_419"

    /// A Metal cache pair `<folder>/com.apple.metal/<gpu>/<name>.data` (+ `.list`) whose data is `size` bytes.
    @discardableResult
    private func cache(_ tmp: TempDir, _ folder: String, _ name: String = "functions", size: Int, gpu: String = gpu) throws -> URL {
        let dir = try tmp.makeDir("\(folder)/com.apple.metal/\(gpu)")
        let data = dir.appendingPathComponent("\(name).data")
        try Data(repeating: 7, count: size).write(to: data)
        try Data("list \(size)".utf8).write(to: dir.appendingPathComponent("\(name).list"))
        return data
    }

    private func size(_ tmp: TempDir, _ path: String) -> Int? {
        ((try? FileManager.default.attributesOfItem(atPath: tmp.url.appendingPathComponent(path).path))?[.size] as? NSNumber)?.intValue
    }

    @Test("Each game's fullest old shader cache goes into its new host and game folders; the old folders go")
    func metalCachesMigrate() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let host = GameHostBundle.bundleIDPrefix, game = GameHostBundle.gameAppIDPrefix
        try cache(tmp, "com.mikael.silo.host.1778820", size: 855)
        try cache(tmp, "com.mikael.silo.game.1778820", size: 502)
        try cache(tmp, "com.mikael.silo.game.1778820", "libraries", size: 30, gpu: "32024")
        try cache(tmp, "\(game)1778820", size: 323)          // rebuilt since the rename, smaller: replaced
        try cache(tmp, "com.mikael.silo.game.2492040", size: 14)
        try cache(tmp, "\(game)2492040", size: 1130)         // already fuller: kept
        _ = try tmp.makeDir("com.mikael.silo.host.480/com.apple.metal/\(Self.gpu)")   // nothing in it
        // Not a game's: never touched.
        try cache(tmp, "com.mikael.silo.hosttest", size: 9)
        try cache(tmp, "com.mikael.silo", size: 9)
        try cache(tmp, "com.other.app", size: 9)

        let written = LegacyIdentifiers.migrateMetalCaches(cacheRoot: tmp.url)
        #expect(written == [
            "\(host)1778820/\(Self.gpu)/functions.data", "\(host)1778820/32024/libraries.data",
            "\(game)1778820/\(Self.gpu)/functions.data", "\(game)1778820/32024/libraries.data",
            "\(host)2492040/\(Self.gpu)/functions.data",
        ])
        #expect(size(tmp, "\(game)1778820/com.apple.metal/\(Self.gpu)/functions.data") == 855)
        #expect(size(tmp, "\(host)1778820/com.apple.metal/\(Self.gpu)/functions.data") == 855)
        #expect(size(tmp, "\(game)1778820/com.apple.metal/\(Self.gpu)/functions.list") == "list 855".utf8.count)
        #expect(size(tmp, "\(game)1778820/com.apple.metal/32024/libraries.data") == 30)
        #expect(size(tmp, "\(game)2492040/com.apple.metal/\(Self.gpu)/functions.data") == 1130)
        for gone in ["com.mikael.silo.host.1778820", "com.mikael.silo.game.1778820", "com.mikael.silo.game.2492040",
                     "com.mikael.silo.host.480"] {
            #expect(!FileManager.default.fileExists(atPath: tmp.url.appendingPathComponent(gone).path), "\(gone)")
        }
        for kept in ["com.mikael.silo.hosttest", "com.mikael.silo", "com.other.app"] {
            #expect(FileManager.default.fileExists(atPath: tmp.url.appendingPathComponent(kept).path), "\(kept)")
        }
        // Done: a second start finds nothing to do.
        #expect(LegacyIdentifiers.migrateMetalCaches(cacheRoot: tmp.url).isEmpty)
    }

    @Test("A cache a running game holds is left alone, and the old folder kept for the next start")
    func metalCacheInUse() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let game = GameHostBundle.gameAppIDPrefix
        try cache(tmp, "com.mikael.silo.game.1778820", size: 502)
        let held = try cache(tmp, "\(game)1778820", size: 323)
        // O_CLOEXEC: a process another test spawns meanwhile must not inherit the descriptor (and the lock with it).
        let fd = open(held.path, O_RDONLY | O_CLOEXEC)
        #expect(flock(fd, LOCK_EX) == 0)   // as Metal does while the game runs
        #expect(LegacyIdentifiers.isHeld(held))

        let first = LegacyIdentifiers.migrateMetalCaches(cacheRoot: tmp.url)
        #expect(first == ["\(GameHostBundle.bundleIDPrefix)1778820/\(Self.gpu)/functions.data"])
        #expect(size(tmp, "\(game)1778820/com.apple.metal/\(Self.gpu)/functions.data") == 323)
        #expect(FileManager.default.fileExists(atPath: tmp.url.appendingPathComponent("com.mikael.silo.game.1778820").path))

        close(fd)   // the game quit
        #expect(!LegacyIdentifiers.isHeld(held))
        #expect(LegacyIdentifiers.migrateMetalCaches(cacheRoot: tmp.url) == ["\(game)1778820/\(Self.gpu)/functions.data"])
        #expect(size(tmp, "\(game)1778820/com.apple.metal/\(Self.gpu)/functions.data") == 502)
        #expect(!FileManager.default.fileExists(atPath: tmp.url.appendingPathComponent("com.mikael.silo.game.1778820").path))
    }

    @Test("No cache folder at all: nothing happens")
    func noMetalCaches() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        #expect(LegacyIdentifiers.migrateMetalCaches(cacheRoot: tmp.url.appendingPathComponent("missing")).isEmpty)
    }

    @Test("An earlier Silo's host, game app and shortcut bundles are still Silo's to replace")
    func legacyBundlesAreOurs() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        func bundle(_ name: String, _ id: String) throws -> URL {
            _ = try tmp.write("\(name).app/Contents/Info.plist", """
                <?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict>\
                <key>CFBundleIdentifier</key><string>\(id)</string></dict></plist>
                """)
            return tmp.url.appendingPathComponent("\(name).app")
        }
        #expect(GameHostBundle.isHostBundle(at: try bundle("h", "com.mikael.silo.host.1778820")))
        #expect(GameHostBundle.isHostBundle(at: try bundle("g", "com.mikael.silo.game.1778820")))
        #expect(GameShortcut.isSiloShortcut(at: try bundle("s", "com.mikael.silo.shortcut.steam-440")))
        #expect(!GameHostBundle.isHostBundle(at: try bundle("x", "com.mikael.silo")))
        #expect(!GameShortcut.isSiloShortcut(at: try bundle("y", "com.other.shortcut.steam-440")))
    }
}
