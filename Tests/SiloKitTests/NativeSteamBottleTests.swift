import Foundation
import Testing
@testable import SiloKit

@Suite("NativeSteamBottle")
struct NativeSteamBottleTests {
    /// A classic Steam bottle with a Windows client, plus a filled bridge folder.
    func setUp(_ tmp: TempDir, bridge: Bool = true) throws -> AppPaths {
        let paths = AppPaths(supportDir: tmp.url)
        try tmp.write("SteamBottle/drive_c/Program Files (x86)/Steam/steam.exe", "WINDOWS STEAM")
        try tmp.makeDir("SteamBottle/drive_c/windows/syswow64")
        if bridge {
            for file in NativeSteamBottle.bridgeFiles {
                try tmp.write("Runtimes/native-steam-bridge/\(file)", "bridge:\(file)")
            }
        }
        return paths
    }

    @Test("Without the bridge files nothing is cloned, and the missing ones are named")
    func needsBridge() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let paths = try setUp(tmp, bridge: false)
        try tmp.write("Runtimes/native-steam-bridge/steam.exe", "shim")
        let bottle = NativeSteamBottle(paths: paths, runner: SystemProcessRunner())
        await #expect(throws: NativeSteamBottle.Failure.bridgeMissing(Array(NativeSteamBottle.bridgeFiles.dropFirst()))) {
            try await bottle.ensureBottle()
        }
        #expect(!FileManager.default.fileExists(atPath: paths.nativeSteamBottle.path))
    }

    @Test("The first run clones the classic bottle and swaps in the stand-in client, keeping the real one")
    func clonesAndSwaps() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let paths = try setUp(tmp)
        let bottle = NativeSteamBottle(paths: paths, runner: SystemProcessRunner())
        try await bottle.ensureBottle()
        try await bottle.ensureBottle()   // idempotent: the kept original must stay the Windows client

        let steam = paths.nativeSteamBottle.appendingPathComponent("drive_c/Program Files (x86)/Steam")
        #expect(try String(contentsOf: steam.appendingPathComponent("steam.exe"), encoding: .utf8) == "bridge:steam.exe")
        #expect(try String(contentsOf: steam.appendingPathComponent(NativeSteamBottle.originalClientName),
                           encoding: .utf8) == "WINDOWS STEAM")
        #expect(try String(contentsOf: paths.nativeSteamBottle.appendingPathComponent(
            "drive_c/windows/syswow64/lsteamclient.dll"), encoding: .utf8) == "bridge:i386-windows/lsteamclient.dll")
        // The classic bottle is untouched.
        #expect(try String(contentsOf: paths.steamBottle.appendingPathComponent(
            "drive_c/Program Files (x86)/Steam/steam.exe"), encoding: .utf8) == "WINDOWS STEAM")
    }

    @Test("lsteamclient lands in the runtime as builtin modules of both ABIs plus the unix side")
    func stagesRuntime() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let paths = try setUp(tmp)
        let wine = tmp.url.appendingPathComponent("Runtimes/wine-x/bin/wine64")
        let bottle = NativeSteamBottle(paths: paths, runner: SystemProcessRunner())
        try bottle.stageRuntime(wine: wine)
        try bottle.stageRuntime(wine: wine)
        let lib = tmp.url.appendingPathComponent("Runtimes/wine-x/lib/wine")
        for (dir, file) in [("x86_64-windows", "lsteamclient.dll"), ("i386-windows", "lsteamclient.dll"),
                            ("x86_64-unix", "lsteamclient.so")] {
            #expect(try String(contentsOf: lib.appendingPathComponent("\(dir)/\(file)"), encoding: .utf8)
                    == "bridge:\(dir)/\(file)")
        }
    }

    @Test("The game is read from the appmanifest of the library its install dir belongs to")
    func steamAppFromManifest() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let manifest = try String(contentsOf: FixtureLoader.url("appmanifest_220.acf"), encoding: .utf8)
        try tmp.write("Lib/steamapps/appmanifest_220.acf", manifest)
        let install = try tmp.makeDir("Lib/steamapps/common/Half-Life 2")
        let app = try NativeSteamLauncher.steamApp(for: .init(appID: 220, installDir: install, executable: nil,
                                                              gameArguments: []))
        #expect(app.appID == 220)
        #expect(app.name == "Half-Life 2")
        #expect(app.libraryPath.standardizedFileURL.path == tmp.url.appendingPathComponent("Lib").standardizedFileURL.path)
        #expect(throws: NativeSteamLauncher.Failure.self) {
            try NativeSteamLauncher.steamApp(for: .init(appID: 9, installDir: install, executable: nil, gameArguments: []))
        }
    }
}
