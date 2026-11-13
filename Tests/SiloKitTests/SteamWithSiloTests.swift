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
