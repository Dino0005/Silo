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
