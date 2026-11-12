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

    @Test("The launcher app is a background agent whose script runs Silo --start-steam")
    func launcherApp() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let launcher = SteamLauncherApp(siloExecutable: URL(fileURLWithPath: "/Apps/Si'lo.app/Contents/MacOS/Silo"))
        #expect(launcher.infoPlist().contains("<key>LSUIElement</key><true/>"))
        #expect(launcher.infoPlist().contains("<key>CFBundleExecutable</key><string>launcher</string>"))
        #expect(launcher.launchScript().contains("exec '/Apps/Si'\\''lo.app/Contents/MacOS/Silo' --start-steam"))
        let app = try launcher.write(into: tmp.url)
        #expect(app.lastPathComponent == "Steam (Silo).app")
        let script = app.appendingPathComponent("Contents/MacOS/launcher")
        #expect(FileManager.default.isExecutableFile(atPath: script.path))
    }
}
