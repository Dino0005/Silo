import Foundation
import Testing
@testable import SiloKit

struct NativeSteamSetupTests {
    /// A home with a Silo.app that carries the launcher and the Steam library, and a Steam folder.
    static func fixture(_ tmp: TempDir) throws -> (setup: NativeSteamSetup, fake: FakeProcessRunner) {
        _ = try tmp.write("Silo.app/Contents/Helpers/SiloSteamLauncher", "launcher")
        try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                              ofItemAtPath: tmp.url.appendingPathComponent("Silo.app/Contents/Helpers/SiloSteamLauncher").path)
        _ = try tmp.write("Silo.app/Contents/Helpers/silo-steam-hook.dylib", "hook")
        _ = try tmp.write("home/Library/Application Support/Steam/steamapps/libraryfolders.vdf", #""libraryfolders" { }"#)
        // macOS Steam installed — in this home's Applications, so the Mac's own /Applications plays no part.
        _ = try tmp.write("home/Applications/Steam.app/Contents/Info.plist", "")
        let fake = FakeProcessRunner()
        let setup = NativeSteamSetup(paths: AppPaths(supportDir: tmp.url.appendingPathComponent("Silo")), runner: fake,
                                     home: tmp.url.appendingPathComponent("home"),
                                     siloApp: tmp.url.appendingPathComponent("Silo.app"),
                                     systemApplicationsDir: tmp.url.appendingPathComponent("SystemApplications"),
                                     isSteamRunning: { false })
        return (setup, fake)
    }

    @Test("A moved Silo: every part that runs the old copy is found and pointed at this one; nothing when off")
    func movedSilo() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let (old, oldFake) = try Self.fixture(tmp)
        #expect(try await old.repointIfMoved().isEmpty)          // Steam for macOS off: nothing to repoint
        try await old.enable()
        // codesign is faked here: give "Steam (Silo)" the signature folder a real codesign leaves.
        let signature = old.launcherAppURL.appendingPathComponent("Contents/_CodeSignature")
        try FileManager.default.createDirectory(at: signature, withIntermediateDirectories: true)
        #expect(old.partsFromAnotherSilo().isEmpty)              // installed by this copy
        #expect(try await old.repointIfMoved().isEmpty)
        // On again with the launcher unchanged: its grant is kept (no reset), only asked for (a no-op when given).
        let resets = oldFake.invocations.filter { $0.executable.lastPathComponent == "tccutil" }.count
        try await old.enable()
        #expect(oldFake.invocations.filter { $0.executable.lastPathComponent == "tccutil" }.count == resets)
        // The tool still under its earlier id from an older Silo: rewritten, which removes the old one.
        _ = try tmp.write("home/Library/Application Support/Steam/compatibilitytools.d/silo/run", "# Written by Silo: old")
        #expect(old.partsFromAnotherSilo() == ["compatibility tool"])
        _ = try await old.repointIfMoved()
        #expect(old.partsFromAnotherSilo().isEmpty)

        // The same Silo dragged elsewhere (a new version in Applications, say).
        _ = try tmp.write("Applications/Silo.app/Contents/Helpers/SiloSteamLauncher", "launcher")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath:
            tmp.url.appendingPathComponent("Applications/Silo.app/Contents/Helpers/SiloSteamLauncher").path)
        _ = try tmp.write("Applications/Silo.app/Contents/Helpers/silo-steam-hook.dylib", "hook")
        let fake = FakeProcessRunner()
        let moved = NativeSteamSetup(paths: old.paths, runner: fake, home: old.home,
                                     siloApp: tmp.url.appendingPathComponent("Applications/Silo.app"),
                                     systemApplicationsDir: tmp.url.appendingPathComponent("SystemApplications"),
                                     isSteamRunning: { false })
        #expect(moved.partsFromAnotherSilo() == ["compatibility tool", "guard", "Steam (Silo)"])
        let done = try await moved.repointIfMoved()
        #expect(NativeSteamSetup.launcherRewritten(done))      // the hook's path changed: grant again
        try FileManager.default.createDirectory(at: signature, withIntermediateDirectories: true)
        #expect(moved.partsFromAnotherSilo().isEmpty)
        #expect(old.partsFromAnotherSilo() == ["compatibility tool", "guard", "Steam (Silo)"])
        #expect(fake.invocations.contains { $0.arguments.first == "bootstrap" })
    }

    @Test("Without macOS Steam the switch can't be turned on; Steam.app in either Applications or its client counts")
    func steamNotInstalled() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let (setup, _) = try Self.fixture(tmp)
        try FileManager.default.removeItem(at: setup.home.appendingPathComponent("Applications/Steam.app"))
        #expect(!setup.status().steamInstalled)
        await #expect(throws: NativeSteamSetup.Failure.steamNotInstalled) { try await setup.enable() }
        #expect(!setup.isEnabled)

        _ = try tmp.write("SystemApplications/Steam.app/Contents/Info.plist", "")        // Valve's installer
        #expect(setup.status().steamInstalled)
        try FileManager.default.removeItem(at: tmp.url.appendingPathComponent("SystemApplications/Steam.app"))
        _ = try tmp.write("home/Library/Application Support/Steam/Steam.AppBundle/Steam/Contents/MacOS/steam_osx", "")
        #expect(setup.status().steamInstalled)                                             // the downloaded client
    }

    @Test("On installs the launcher app, the tool, the launch script and the guard; Off removes all but protection")
    func onAndOff() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let (setup, fake) = try Self.fixture(tmp)
        try await setup.enable()
        var status = setup.status()
        #expect(status.enabled && status.launcherApp && status.tool && status.guardAgent)
        let script = setup.steamRoot.appendingPathComponent("steamapps/common/Silo Runtime/silo-launch")
        #expect(FileManager.default.fileExists(atPath: script.path))
        #expect(fake.invocations.contains { $0.executable.lastPathComponent == "codesign" })
        #expect(fake.invocations.contains { $0.arguments.first == "bootstrap" })
        // The rewritten launcher: its stale grant cleared, then it asks macOS for the grant (prompt + listed).
        #expect(fake.invocations.contains {
            $0.executable.lastPathComponent == "tccutil"
                && $0.arguments == ["reset", "Accessibility", SteamLauncherApp.bundleIdentifier]
        })
        #expect(fake.invocations.contains {
            $0.executable.lastPathComponent == "open"
                && $0.arguments == ["-n", setup.launcherAppURL.path, "--args", SteamLauncherApp.requestAccessFlag]
        })

        // A game mapped to Silo's tool, a redistributable mapped to its earlier id, a game on a tool that isn't Silo's.
        _ = try tmp.write("home/Library/Application Support/Steam/config/config.vdf", """
        "InstallConfigStore"
        {
        \t"CompatToolMapping"
        \t{
        \t\t"544750"
        \t\t{
        \t\t\t"name"\t\t"\(SiloCompatTool.name)"
        \t\t}
        \t\t"228980"
        \t\t{
        \t\t\t"name"\t\t"silo"
        \t\t}
        \t\t"10"
        \t\t{
        \t\t\t"name"\t\t"proton_9"
        \t\t}
        \t}
        }
        """)
        #expect(setup.status().gamesOnTool == 1)
        try await setup.disable()
        status = setup.status()
        #expect(!status.enabled && !status.launcherApp && !status.tool && status.gamesOnTool == 0)
        #expect(status.guardAgent)                                   // protection stays
        #expect(FileManager.default.fileExists(atPath: script.path)) // the protected games point at it
        let config = try String(contentsOf: setup.configVDF, encoding: .utf8)
        #expect(!config.contains("544750") && config.contains("proton_9"))
    }

    @Test("Off needs Steam closed")
    func offNeedsSteamClosed() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let setup = NativeSteamSetup(paths: AppPaths(supportDir: tmp.url), runner: FakeProcessRunner(),
                                     home: tmp.url, siloApp: tmp.url, isSteamRunning: { true })
        await #expect(throws: NativeSteamSetup.Failure.steamRunning) { try await setup.disable() }
    }

    @Test("Without a Silo.app there is nothing to install")
    func onNeedsTheApp() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let setup = NativeSteamSetup(paths: AppPaths(supportDir: tmp.url), runner: FakeProcessRunner(),
                                     home: tmp.url, siloApp: tmp.url.appendingPathComponent("none.app"), isSteamRunning: { false })
        await #expect(throws: NativeSteamSetup.Failure.notAnApp) { try await setup.enable() }
    }

    @Test("Protection is needed while any library is unplugged or holds a Windows game")
    func protection() {
        let a = URL(fileURLWithPath: "/a"), b = URL(fileURLWithPath: "/b")
        #expect(NativeSteamSetup.protectionNeeded(libraries: [a, b], windowsGamesInstalled: true, isReachable: { _ in true }))
        #expect(NativeSteamSetup.protectionNeeded(libraries: [a, b], windowsGamesInstalled: false, isReachable: { $0 == a }))
        #expect(!NativeSteamSetup.protectionNeeded(libraries: [a, b], windowsGamesInstalled: false, isReachable: { _ in true }))
    }

    @Test("Bottles go only with the switch off and Steam closed")
    func bottles() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let paths = AppPaths(supportDir: tmp.url.appendingPathComponent("Silo"))
        try FileManager.default.createDirectory(at: paths.nativeSteamBottle, withIntermediateDirectories: true)
        let open = NativeSteamSetup(paths: paths, runner: FakeProcessRunner(), home: tmp.url, siloApp: tmp.url,
                                    isSteamRunning: { true })
        #expect(throws: NativeSteamSetup.Failure.bottlesInUse) { try open.deleteBottles() }
        let closed = NativeSteamSetup(paths: paths, runner: FakeProcessRunner(), home: tmp.url, siloApp: tmp.url,
                                      isSteamRunning: { false })
        try closed.deleteBottles()
        #expect(!FileManager.default.fileExists(atPath: paths.nativeSteamBottle.path))
    }
}

struct SteamCompatMappingRemovalTests {
    @Test("Removing mappings keeps the rest of config.vdf byte for byte")
    func removal() {
        let text = "\"S\"\n{\n\t\"CompatToolMapping\"\n\t{\n\t\t\"1\"\n\t\t{\n\t\t\t\"name\"\t\t\"silo\"\n\t\t\t\"priority\"\t\t\"250\"\n\t\t}\n\t\t\"2\"\n\t\t{\n\t\t\t\"name\"\t\t\"keep\"\n\t\t}\n\t\t\"3\"\n\t\t{\n\t\t\t\"name\"\t\t\"silo-proton\"\n\t\t}\n\t}\n\t\"Other\"\t\t\"x\"\n}\n"
        let expected = "\"S\"\n{\n\t\"CompatToolMapping\"\n\t{\n\t\t\"2\"\n\t\t{\n\t\t\t\"name\"\t\t\"keep\"\n\t\t}\n\t}\n\t\"Other\"\t\t\"x\"\n}\n"
        #expect(SteamCompatMapping.removingMappings(to: ["silo", "silo-proton"], in: text) == expected)
        #expect(SteamCompatMapping.removingMappings(to: ["none"], in: text) == text)
        #expect(SteamCompatMapping.removingMappings(to: ["silo"], in: "no section") == "no section")
    }
}

@MainActor
struct NativeSteamSettingsModelTests {
    @Test("The switch turns everything on, and off asks to quit Steam while it runs")
    func toggles() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let (setup, _) = try NativeSteamSetupTests.fixture(tmp)
        let model = NativeSteamSettingsModel(setup: setup)
        #expect(!model.status.enabled)
        await model.setEnabled(true)
        #expect(model.status.enabled && model.status.launcherApp && !model.isWorking)

        let running = NativeSteamSetup(paths: setup.paths, runner: FakeProcessRunner(), home: setup.home,
                                       siloApp: setup.siloApp, isSteamRunning: { true })
        let blocked = NativeSteamSettingsModel(setup: running)
        await blocked.setEnabled(false)
        #expect(blocked.message == "Quit Steam first." && blocked.status.enabled)
    }

    @Test("The status says whether the configured Wine has the bridge; nothing while no Wine is set up")
    func wineBridge() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let (setup, _) = try NativeSteamSetupTests.fixture(tmp)
        #expect(setup.status().wineBridge == nil)                      // no config.json yet
        let wine = tmp.url.appendingPathComponent("Silo/Runtimes/wine-cx/bin/wine64")
        _ = try tmp.write("Silo/Runtimes/wine-cx/bin/wine64", "")
        var state = AppState(); state.backend.wineBinaryPath = wine
        try await ConfigStore(paths: setup.paths).save(state)
        #expect(setup.status().wineBridge == false)                    // an older runtime: no bridge
        for file in NativeSteamBottle.bridgeFiles {
            _ = try tmp.write(file == "steam.exe" ? "Silo/Runtimes/wine-cx/share/silo/native-steam/steam.exe"
                                                  : "Silo/Runtimes/wine-cx/lib/wine/\(file)", "x")
        }
        #expect(setup.status().wineBridge == true)
    }
}
