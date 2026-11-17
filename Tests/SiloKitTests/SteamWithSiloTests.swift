import Foundation
import Testing
@testable import SiloKit

@Suite("Steam with Silo — the launcher app and Steam's environment")
struct SteamWithSiloTests {
    @Test("Steam's client gets Silo's library; the compatibility layer only when asked")
    func environment() {
        let hook = URL(fileURLWithPath: "/A/Silo.app/Contents/Helpers/silo-steam-hook.dylib")
        let tools = URL(fileURLWithPath: "/S/compatibilitytools.d")
        #expect(SteamWithSilo.environment(hook: hook, compat: false, toolsDir: tools)
                == [NativeSteamBridge.overlayEnvKey: hook.path])
        let compat = SteamWithSilo.environment(hook: hook, compat: true, toolsDir: tools)
        #expect(compat["SILO_STEAM_COMPAT"] == "1" && compat["STEAM_EXTRA_COMPAT_TOOLS_PATHS"] == tools.path)
    }

    @Test("The launcher app: a background agent with the compiled launcher and the library's path")
    func launcherApp() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let binary = tmp.url.appendingPathComponent("SiloSteamLauncher")
        try Data("bin".utf8).write(to: binary)
        let hook = URL(fileURLWithPath: "/A/Silo.app/Contents/Helpers/silo-steam-hook.dylib")
        let launcher = SteamLauncherApp(launcher: binary, hook: hook)
        #expect(launcher.infoPlist().contains("<key>LSUIElement</key><true/>"))
        #expect(launcher.infoPlist().contains("<key>CFBundleExecutable</key><string>launcher</string>"))
        let app = try launcher.write(into: tmp.url.appendingPathComponent("Apps"))
        #expect(app.lastPathComponent == "Steam (Silo).app")
        #expect(FileManager.default.isExecutableFile(atPath: app.appendingPathComponent("Contents/MacOS/launcher").path))
        #expect(try String(contentsOf: app.appendingPathComponent("Contents/Resources/silo-steam-hook"), encoding: .utf8)
                == hook.path + "\n")
        #expect(SteamLauncherApp(appBundle: tmp.url) == nil)   // no Silo.app parts there
        // Unsigned → not current; once signed (a _CodeSignature folder) and unchanged → current; changed → not.
        let apps = tmp.url.appendingPathComponent("Apps")
        #expect(!launcher.isCurrent(in: apps))
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents/_CodeSignature"),
                                                withIntermediateDirectories: true)
        #expect(launcher.isCurrent(in: apps))
        try Data("bin2".utf8).write(to: binary)
        #expect(!launcher.isCurrent(in: apps))
    }
}

@Suite("SystemProcessRunner.spawnIndependent")
struct SpawnIndependentTests {
    @Test("Spawns detached in its own session, output to the log, in the given directory")
    func spawns() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let log = tmp.url.appendingPathComponent("out.log")
        let pid = try await SystemProcessRunner().spawnIndependent(
            executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "pwd; echo \"$SILO_T\""],
            environment: ["SILO_T": "ok"], currentDirectory: tmp.url, logURL: log)
        #expect(pid > 0)
        for _ in 0..<50 where !((try? String(contentsOf: log, encoding: .utf8)) ?? "").contains("ok") {
            try await Task.sleep(for: .milliseconds(50))
        }
        let out = try String(contentsOf: log, encoding: .utf8)
        #expect(out.contains("ok"))
        #expect(out.contains(tmp.url.lastPathComponent))
    }
}

@Suite("SiloCompatTool — Silo as a macOS Steam compatibility tool")
struct SiloCompatToolTests {
    @Test("Writes the tool in Steam's format; the run script hands games to Silo --steam-launch")
    func writes() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let tool = SiloCompatTool(siloExecutable: URL(fileURLWithPath: "/Apps/Si'lo.app/Contents/MacOS/Silo"))
        // The tool under its earlier id, written by Silo, goes; someone else's tool with that id would stay.
        _ = try tmp.write("compatibilitytools.d/silo/run", "#!/bin/sh\n# Written by Silo: old\n")
        let dir = try tool.write(steamRoot: tmp.url)
        #expect(dir.path.hasSuffix("compatibilitytools.d/silo-proton"))
        #expect(!FileManager.default.fileExists(atPath: tmp.url.appendingPathComponent("compatibilitytools.d/silo").path))
        let vdf = try String(contentsOf: dir.appendingPathComponent("compatibilitytool.vdf"), encoding: .utf8)
        #expect(vdf.contains("\"from_oslist\" \"windows\"") && vdf.contains("\"to_oslist\" \"macos\""))
        #expect(try String(contentsOf: dir.appendingPathComponent("toolmanifest.vdf"), encoding: .utf8)
            .contains("\"commandline\" \"/run %verb%\""))
        let run = dir.appendingPathComponent("run")
        #expect(FileManager.default.isExecutableFile(atPath: run.path))
        let script = try String(contentsOf: run, encoding: .utf8)
        #expect(script.contains("exec '/Apps/Si'\\''lo.app/Contents/MacOS/Silo' --steam-launch --appid \"$STEAM_COMPAT_APP_ID\""))
        #expect(script.contains("*iscriptevaluator.exe) exit 0"))
    }

    @Test("The bridge keeps Steam's own variables, the virtual-pad description included (the launcher decides)")
    func keepsSteamVariables() {
        let bridge = NativeSteamBridge(clientInstallPath: URL(fileURLWithPath: "/S"), steamEnvironment: [
            "SteamVirtualGamepadInfo": "/x.txt", "SteamAppId": "544750", "HOME": "/Users/x",
        ])
        #expect(bridge.steamEnvironment == ["SteamVirtualGamepadInfo": "/x.txt", "SteamAppId": "544750"])
    }
}

struct SteamOverlayFixTests {
    @Test("The overlay fix goes right after Steam's overlay, and only when the overlay is injected")
    func placement() {
        let loader = URL(fileURLWithPath: "/S/steamloader.dylib"), overlay = URL(fileURLWithPath: "/S/gameoverlayrenderer.dylib")
        let game = URL(fileURLWithPath: "/A/silo-game-loader.dylib"), fix = URL(fileURLWithPath: "/A/silo-overlay-fix.dylib")
        #expect(SteamOverlayFix.adding(fix, to: [game, loader, overlay]) == [game, loader, overlay, fix])
        #expect(SteamOverlayFix.adding(fix, to: [game, loader]) == [game, loader])
        #expect(SteamOverlayFix.adding(nil, to: [loader, overlay]) == [loader, overlay])
    }
}
