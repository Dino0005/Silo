import Foundation
import Testing
@testable import SiloKit

@Suite("Native Steam launch")
struct NativeSteamLaunchTests {
    let dir = URL(fileURLWithPath: "/Volumes/Ext/SteamLibrary/steamapps/common/TEKKEN 8")

    @Test("Steam's launch-entry arguments become the app id and the exe inside the install dir")
    func parsesSteamArguments() throws {
        let r = try NativeSteamLaunchRequest.parse(["--appid", "1778820", "--exe", "TEKKEN 8.exe"],
                                                   workingDirectory: dir, environment: [:])
        #expect(r.appID == 1_778_820)
        #expect(r.executable?.path == "\(dir.path)/TEKKEN 8.exe")
        #expect(r.gameArguments.isEmpty)
    }

    @Test("Launch Options typed in Steam are passed to the game; Windows separators are turned around")
    func passesLaunchOptions() throws {
        let r = try NativeSteamLaunchRequest.parse(
            ["--appid", "2531310", "--exe", #"bin\tlou-ii.exe"#, "-dx12", "+fps_max", "60"],
            workingDirectory: dir, environment: [:])
        #expect(r.executable?.lastPathComponent == "tlou-ii.exe")
        #expect(r.executable?.deletingLastPathComponent().lastPathComponent == "bin")
        #expect(r.gameArguments == ["-dx12", "+fps_max", "60"])
    }

    @Test("A trailing flag without a value is dropped, and SteamAppId backs up a missing --appid")
    func toleratesOddInput() throws {
        let r = try NativeSteamLaunchRequest.parse(["--exe"], workingDirectory: dir,
                                                   environment: ["SteamAppId": "1778820"])
        #expect(r.appID == 1_778_820)
        #expect(r.executable == nil)
        #expect(throws: NativeSteamLaunchRequest.Failure.missingAppID) {
            try NativeSteamLaunchRequest.parse([], workingDirectory: dir, environment: [:])
        }
    }

    private func plan(bridge: NativeSteamBridge?, socket: URL? = nil) throws -> LaunchPlan {
        var backend = BackendConfig()
        backend.wineBinaryPath = URL(fileURLWithPath: "/w/bin/wine64")
        backend.gptkLibDirPath = URL(fileURLWithPath: "/g/lib/wine/x86_64-windows")
        var config = GameConfig(appID: 1_778_820)
        config.customArgs = ["-silo"]
        return try LaunchOrchestrator.makePlan(
            config: config, backend: backend, graphics: .gptk,
            gameExe: dir.appendingPathComponent("TEKKEN 8.exe"),
            prefix: URL(fileURLWithPath: "/b/SteamNative"), logURL: URL(fileURLWithPath: "/l.log"),
            altLoaderSocket: socket, steamBridge: bridge)
    }

    @Test("With the bridge, the stand-in steam.exe starts the game and lsteamclient is routed in")
    func bridgePlan() throws {
        let client = URL(fileURLWithPath: "/Users/u/Library/Application Support/Steam/Steam.AppBundle/Steam/Contents/MacOS")
        let p = try plan(bridge: NativeSteamBridge(clientInstallPath: client),
                         socket: URL(fileURLWithPath: "/tmp/s.sock"))
        #expect(p.arguments == [#"C:\Program Files (x86)\Steam\steam.exe"#, "\(dir.path)/TEKKEN 8.exe", "-silo"])
        #expect(p.environment["SILO_LSTEAMCLIENT"] == "1")
        #expect(p.environment["STEAM_COMPAT_CLIENT_INSTALL_PATH"] == client.path)
        #expect(p.environment["WINEDLLOVERRIDES"] == GraphicsBackend.gptk.dllOverrides + ";" + NativeSteamBridge.dllOverrides)
        #expect(p.environment["CX_ALT_LOADER_SOCKET"] == "/tmp/s.sock")
        #expect(p.environment["WINEPREFIX"] == "/b/SteamNative")
        #expect(p.currentDirectory.standardizedFileURL.path == dir.path)
    }

    @Test("Without the bridge the plan is exactly today's")
    func noBridge() throws {
        let p = try plan(bridge: nil)
        #expect(p.environment["SILO_LSTEAMCLIENT"] == nil)
        #expect(!(p.environment["WINEDLLOVERRIDES"] ?? "").contains("lsteamclient"))
        #expect(p.arguments.first == "\(dir.path)/TEKKEN 8.exe")
    }

    @Test("The default macOS client path is Steam's binaries folder in the user's Library")
    func defaultClientPath() {
        let home = URL(fileURLWithPath: "/Users/u")
        #expect(NativeSteamBridge.defaultClientInstallPath(home: home).path
                == "/Users/u/Library/Application Support/Steam/Steam.AppBundle/Steam/Contents/MacOS")
    }

    /// A PE file: the DOS stub, with Wine's marker at offset 64 when it is one of Wine's modules.
    private func pe(_ marker: String?) -> Data {
        var data = Data("MZ".utf8) + Data(repeating: 0, count: 62)
        data += Data((marker ?? "!This program cannot be run in DOS mode.").utf8)
        return data + Data(repeating: 0, count: 64)
    }

    @Test("Microsoft's VC++ DLLs in system32 are found by name; Wine builtins, placeholders and others are not")
    func nativeVCRuntime() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let sys = try tmp.makeDir("system32")
        for (name, marker) in [("msvcp140.dll", nil), ("MSVCP140_2.dll", nil), ("vcruntime140_1.dll", nil),
                               ("concrt140.dll", "Wine builtin DLL"), ("vcruntime140.dll", "Wine placeholder DLL"),
                               ("msvcrt.dll", nil), ("msvcp140.dll.bak", nil)] as [(String, String?)] {
            try pe(marker).write(to: sys.appendingPathComponent(name))
        }
        try Data("MZ".utf8).write(to: sys.appendingPathComponent("msvcp140_1.dll"))   // too short to tell: kept
        #expect(NativeSteamBridge.nativeVCRuntime(inSystem32: sys) == ["msvcp140", "msvcp140_1", "msvcp140_2", "vcruntime140_1"])
        #expect(NativeSteamBridge.nativeVCRuntime(inSystem32: tmp.url.appendingPathComponent("none")).isEmpty)
    }

    @Test("A game from macOS Steam loads Microsoft's VC++ runtime native-first, after the bridge's routing")
    func vcRuntimeRouting() throws {
        let bridge = NativeSteamBridge(clientInstallPath: URL(fileURLWithPath: "/c"),
                                       nativeVCRuntime: ["msvcp140", "msvcp140_2"])
        #expect(bridge.dllRouting == NativeSteamBridge.dllOverrides + ";msvcp140,msvcp140_2=n,b")
        #expect(NativeSteamBridge(clientInstallPath: URL(fileURLWithPath: "/c")).dllRouting == NativeSteamBridge.dllOverrides)
        let p = try plan(bridge: bridge)
        #expect(p.environment["WINEDLLOVERRIDES"]
                == GraphicsBackend.gptk.dllOverrides + ";" + NativeSteamBridge.dllOverrides + ";msvcp140,msvcp140_2=n,b")
    }

    @Test("Only .dylib files that exist directly in Steam's program folder are taken from STEAM_DYLD_INSERT_LIBRARIES")
    func overlayLibraries() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let macos = try tmp.makeDir("Steam/Contents/MacOS")
        try tmp.write("Steam/Contents/MacOS/steamloader.dylib", "x")
        try tmp.write("Steam/Contents/MacOS/gameoverlayrenderer.dylib", "x")
        try tmp.write("Steam/Contents/MacOS/sub/evil.dylib", "x")
        try tmp.write("elsewhere/evil.dylib", "x")
        let value = [macos.appendingPathComponent("steamloader.dylib").path,
                     macos.appendingPathComponent("gameoverlayrenderer.dylib").path,
                     macos.appendingPathComponent("missing.dylib").path,
                     macos.appendingPathComponent("sub/evil.dylib").path,
                     macos.appendingPathComponent("../../../elsewhere/evil.dylib").path,
                     tmp.url.appendingPathComponent("elsewhere/evil.dylib").path].joined(separator: ":")
        let libs = NativeSteamBridge.overlayLibraries(fromSteam: value, clientInstallPath: macos)
        #expect(libs.map(\.lastPathComponent) == ["steamloader.dylib", "gameoverlayrenderer.dylib"])
        #expect(NativeSteamBridge.overlayLibraries(fromSteam: nil, clientInstallPath: macos).isEmpty)
    }

    @Test("The bridge carries Steam's libraries to the runner and to the host; extra can't use the channel")
    func overlayPlan() throws {
        let libs = [URL(fileURLWithPath: "/S/MacOS/steamloader.dylib"), URL(fileURLWithPath: "/S/MacOS/gameoverlayrenderer.dylib")]
        let bridge = NativeSteamBridge(clientInstallPath: URL(fileURLWithPath: "/S/MacOS"), overlayLibraries: libs)
        let joined = "/S/MacOS/steamloader.dylib:/S/MacOS/gameoverlayrenderer.dylib"
        #expect(bridge.environment[NativeSteamBridge.overlayEnvKey] == joined)
        #expect(bridge.hostEnvironment == ["DYLD_INSERT_LIBRARIES": joined])
        let withSteam = NativeSteamBridge(clientInstallPath: URL(fileURLWithPath: "/S/MacOS"), overlayLibraries: libs,
                                          steamEnvironment: ["SteamOverlayGameId": "2531310", "Steam3Master": "127.0.0.1:1",
                                                             "SDL_JOYSTICK_HIDAPI_STEAMXBOX": "0", "HOME": "/Users/x"])
        #expect(withSteam.hostEnvironment == ["DYLD_INSERT_LIBRARIES": joined, "SteamOverlayGameId": "2531310",
                                              "Steam3Master": "127.0.0.1:1", "SDL_JOYSTICK_HIDAPI_STEAMXBOX": "0"])
        #expect(NativeSteamBridge(clientInstallPath: URL(fileURLWithPath: "/S")).hostEnvironment.isEmpty)
        #expect(try plan(bridge: bridge).environment[NativeSteamBridge.overlayEnvKey] == joined)
        // A user's extra can't smuggle a library in through the same key.
        var backend = BackendConfig()
        backend.wineBinaryPath = URL(fileURLWithPath: "/w/bin/wine64")
        var config = GameConfig(appID: 1)
        config.envFlags.extra = [NativeSteamBridge.overlayEnvKey: "/tmp/evil.dylib"]
        let p = try LaunchOrchestrator.makePlan(
            config: config, backend: backend, graphics: .gptk, gameExe: dir.appendingPathComponent("TEKKEN 8.exe"),
            prefix: URL(fileURLWithPath: "/b"), logURL: URL(fileURLWithPath: "/l.log"))
        #expect(p.environment[NativeSteamBridge.overlayEnvKey] == nil)
    }

    @Test("The runner turns the bridge's key into DYLD_INSERT_LIBRARIES and still strips a direct one")
    func runnerInjection() {
        let env = SystemProcessRunner.mergedEnvironment([NativeSteamBridge.overlayEnvKey: "/S/a.dylib"])
        #expect(env["DYLD_INSERT_LIBRARIES"] == "/S/a.dylib" && env[NativeSteamBridge.overlayEnvKey] == nil)
        #expect(SystemProcessRunner.mergedEnvironment(["DYLD_INSERT_LIBRARIES": "/x.dylib"])["DYLD_INSERT_LIBRARIES"] == nil)
        // An inherited key (not from Silo's own overrides) injects nothing.
        setenv(NativeSteamBridge.overlayEnvKey, "/tmp/inherited.dylib", 1); defer { unsetenv(NativeSteamBridge.overlayEnvKey) }
        let inherited = SystemProcessRunner.mergedEnvironment([:])
        #expect(inherited["DYLD_INSERT_LIBRARIES"] == nil && inherited[NativeSteamBridge.overlayEnvKey] == nil)
    }

    @Test("Every Wine command of the launch carries Steam's libraries, so winedevice.exe inherits them too")
    func librariesRunner() async throws {
        let fake = FakeProcessRunner()
        let runner = SteamLibrariesRunner(base: fake, libraries: "/S/steamloader.dylib")
        _ = try await runner.run(executable: URL(fileURLWithPath: "/w"), arguments: ["regedit"],
                                 environment: ["WINEPREFIX": "/b"], currentDirectory: nil)
        _ = try await runner.spawnDetached(executable: URL(fileURLWithPath: "/w"), arguments: ["steam.exe"],
                                           environment: [:], currentDirectory: nil, logURL: URL(fileURLWithPath: "/l"))
        #expect(fake.invocations.map { $0.environment[NativeSteamBridge.overlayEnvKey] } == ["/S/steamloader.dylib", "/S/steamloader.dylib"])
        #expect(fake.invocations.first?.environment["WINEPREFIX"] == "/b")
    }
}
