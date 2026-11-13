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
        let fake = FakeProcessRunner()
        let setup = NativeSteamSetup(paths: AppPaths(supportDir: tmp.url.appendingPathComponent("Silo")), runner: fake,
                                     home: tmp.url.appendingPathComponent("home"),
                                     siloApp: tmp.url.appendingPathComponent("Silo.app"), isSteamRunning: { false })
        return (setup, fake)
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

        // A game mapped to Silo's tool, another to a tool that isn't Silo's.
        _ = try tmp.write("home/Library/Application Support/Steam/config/config.vdf", """
        "InstallConfigStore"
        {
        \t"CompatToolMapping"
        \t{
        \t\t"544750"
        \t\t{
        \t\t\t"name"\t\t"silo"
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
}
