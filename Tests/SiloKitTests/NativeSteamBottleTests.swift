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
            try await bottle.ensureBottle(source: bottle.bridgeSource(wine: nil))
        }
        #expect(!FileManager.default.fileExists(atPath: paths.nativeSteamBottle.path))
    }

    @Test("The first run clones the classic bottle and swaps in the stand-in client, keeping the real one")
    func clonesAndSwaps() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let paths = try setUp(tmp)
        let bottle = NativeSteamBottle(paths: paths, runner: SystemProcessRunner())
        let source = bottle.bridgeSource(wine: nil)
        #expect(source == .devFolder(paths.nativeSteamBridgeDir))
        try await bottle.ensureBottle(source: source)
        try await bottle.ensureBottle(source: source)   // idempotent: the kept original must stay the Windows client

        let steam = paths.nativeSteamBottle.appendingPathComponent("drive_c/Program Files (x86)/Steam")
        #expect(try String(contentsOf: steam.appendingPathComponent("steam.exe"), encoding: .utf8) == "bridge:steam.exe")
        #expect(try String(contentsOf: steam.appendingPathComponent(NativeSteamBottle.originalClientName),
                           encoding: .utf8) == "WINDOWS STEAM")
        #expect(try String(contentsOf: paths.nativeSteamBottle.appendingPathComponent(
            "drive_c/windows/syswow64/lsteamclient.dll"), encoding: .utf8) == "bridge:i386-windows/lsteamclient.dll")
        #expect(try String(contentsOf: steam.appendingPathComponent("lsteamclient.dll"), encoding: .utf8)
                == "bridge:x86_64-windows/lsteamclient.dll")
        #expect(try String(contentsOf: steam.appendingPathComponent("lsteamclient.so"), encoding: .utf8)
                == "bridge:x86_64-unix/lsteamclient.so")
        // The classic bottle is untouched.
        #expect(try String(contentsOf: paths.steamBottle.appendingPathComponent(
            "drive_c/Program Files (x86)/Steam/steam.exe"), encoding: .utf8) == "WINDOWS STEAM")
    }

    @Test("The Media Foundation variant clones the classic MF bottle into SteamNativeMF, with the same bridge")
    func mediaFoundationVariant() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let paths = try setUp(tmp)
        try tmp.write("SteamBottleMF/drive_c/Program Files (x86)/Steam/steam.exe", "WINDOWS STEAM")
        try tmp.write("SteamBottleMF/drive_c/windows/system32/mfplat.dll", "native MF")
        let bottle = NativeSteamBottle(paths: paths, runner: SystemProcessRunner(), mediaFoundation: true)
        #expect(bottle.prefix == paths.nativeSteamBottleMF && bottle.sourcePrefix == paths.steamBottleMF)
        try await bottle.ensureBottle(source: bottle.bridgeSource(wine: nil))
        let mf = paths.nativeSteamBottleMF
        #expect(try String(contentsOf: mf.appendingPathComponent("drive_c/windows/system32/mfplat.dll"),
                           encoding: .utf8) == "native MF")
        #expect(try String(contentsOf: mf.appendingPathComponent("drive_c/Program Files (x86)/Steam/steam.exe"),
                           encoding: .utf8) == "bridge:steam.exe")
        #expect(!FileManager.default.fileExists(atPath: paths.nativeSteamBottle.path))   // the normal one untouched
    }

    @Test("macOS Steam uses the MF bottle only when it is built and current — the clone's own marker wins once made")
    func mediaFoundationReady() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let paths = try setUp(tmp)
        #expect(!NativeSteamLauncher.mediaFoundationReady(paths: paths, currentRuntime: "wine-cx-26.3.0"))
        try tmp.write("SteamBottleMF/drive_c/windows/system32/mfplat.dll", "native MF")
        try tmp.write("SteamBottleMF/.silo-media-foundation", "wine-cx-26.3.0")
        #expect(NativeSteamLauncher.mediaFoundationReady(paths: paths, currentRuntime: "wine-cx-26.3.0"))
        #expect(!NativeSteamLauncher.mediaFoundationReady(paths: paths, currentRuntime: "wine-crossover-26.3"))
        // Once cloned, the clone is what's checked.
        try tmp.write("SteamNativeMF/drive_c/windows/system32/mfplat.dll", "native MF")
        try tmp.write("SteamNativeMF/.silo-media-foundation", "wine-older")
        #expect(!NativeSteamLauncher.mediaFoundationReady(paths: paths, currentRuntime: "wine-cx-26.3.0"))
    }

    @Test("A runtime built with the bridge is preferred, and supplies the bottle's copies")
    func runtimeSource() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let paths = try setUp(tmp)
        let wine = tmp.url.appendingPathComponent("Runtimes/wine-x/bin/wine64")
        let bottle = NativeSteamBottle(paths: paths, runner: SystemProcessRunner())
        // Missing one file: still the development folder.
        try tmp.write("Runtimes/wine-x/lib/wine/x86_64-windows/lsteamclient.dll", "runtime:x64")
        try tmp.write("Runtimes/wine-x/lib/wine/i386-windows/lsteamclient.dll", "runtime:i386")
        try tmp.write("Runtimes/wine-x/lib/wine/x86_64-unix/lsteamclient.so", "runtime:so")
        #expect(bottle.bridgeSource(wine: wine) == .devFolder(paths.nativeSteamBridgeDir))

        try tmp.write("Runtimes/wine-x/share/silo/native-steam/steam.exe", "runtime:steam")
        let source = bottle.bridgeSource(wine: wine)
        #expect(source == .runtime(tmp.url.appendingPathComponent("Runtimes/wine-x")))
        try await bottle.ensureBottle(source: source)

        let steam = paths.nativeSteamBottle.appendingPathComponent("drive_c/Program Files (x86)/Steam")
        #expect(try String(contentsOf: steam.appendingPathComponent("steam.exe"), encoding: .utf8) == "runtime:steam")
        #expect(try String(contentsOf: steam.appendingPathComponent("lsteamclient.dll"), encoding: .utf8) == "runtime:x64")
        #expect(try String(contentsOf: steam.appendingPathComponent("lsteamclient.so"), encoding: .utf8) == "runtime:so")
        #expect(try String(contentsOf: paths.nativeSteamBottle.appendingPathComponent(
            "drive_c/windows/syswow64/lsteamclient.dll"), encoding: .utf8) == "runtime:i386")
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
