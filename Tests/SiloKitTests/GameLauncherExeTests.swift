import Foundation
import Testing
@testable import SiloKit

/// The Last of Us Part II from macOS Steam (2026-11-10): `launcher.exe` starts `tlou-ii.exe`.
struct GameLauncherExeTests {
    /// Steam's Windows launch entries for TLOU II, in its order; the two `t2r-*` exes are no longer shipped.
    let entries = ["launcher.exe", "t2r-steam-release.exe", "t2r-steam-final-pgo-lto.exe", "tlou-ii.exe", "tlou-ii-l.exe"]

    private func install(_ tmp: TempDir, _ files: [String]) throws -> URL {
        for file in files { try tmp.write("TLOU/\(file)", "MZ") }
        return tmp.url.appendingPathComponent("TLOU")
    }

    @Test func aLauncherHandsOverToTheGameExesSteamListsAndShips() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let dir = try install(tmp, ["launcher.exe", "tlou-ii.exe", "tlou-ii-l.exe", "crs-handler.exe"])
        let owners = GameLauncherExe.windowOwners(
            forLauncher: dir.appendingPathComponent("launcher.exe"), installDir: dir, launchExecutables: entries)
        #expect(owners.map(\.lastPathComponent) == ["tlou-ii.exe", "tlou-ii-l.exe"])
        // The whitelist then names exactly those — never the launcher, which would take the host first.
        #expect(owners.map { AltLoaderWhitelist.exeName(for: $0.lastPathComponent) } == ["tlou-ii", "tlou-ii-l"])
    }

    @Test func aGameThatIsNotALauncherIsLeftAlone() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let dir = try install(tmp, ["tlou-ii.exe", "launcher.exe"])
        #expect(GameLauncherExe.windowOwners(
            forLauncher: dir.appendingPathComponent("tlou-ii.exe"), installDir: dir, launchExecutables: entries).isEmpty)
    }

    @Test func helpersOtherLaunchersAndDuplicatesAreSkipped() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let dir = try install(tmp, ["GameLauncher.exe", "bin/Game.exe", "redist/vcredist_x64.exe", "OtherLauncher.exe"])
        let owners = GameLauncherExe.windowOwners(
            forLauncher: dir.appendingPathComponent("GameLauncher.exe"), installDir: dir,
            launchExecutables: ["GameLauncher.exe", #"bin\Game.exe"#, "bin/Game.exe",
                                "redist/vcredist_x64.exe", "OtherLauncher.exe"])
        #expect(owners == [dir.appendingPathComponent("bin/Game.exe")])
    }

    @Test func noSiblingOnDiskKeepsTheLaunchAsItIs() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let dir = try install(tmp, ["launcher.exe"])
        #expect(GameLauncherExe.windowOwners(
            forLauncher: dir.appendingPathComponent("launcher.exe"), installDir: dir, launchExecutables: entries).isEmpty)
    }

    /// Steam's order, Windows entries only: Silo's own macOS entry 9000 never counts as a sibling.
    @Test func windowsLaunchesListsEveryWindowsEntryOfAPatchedGame() throws {
        var app = AppInfoFixtures.tlou
        _ = AppInfoPatcher.enableSiloLaunch(&app, shim: "../Silo Runtime/silo-launch")
        let data = AppInfoFixtures.cacheData([app])
        #expect(SteamAppInfo.windowsLaunches(appInfo: data, appID: 2_531_310).map(\.executable)
                == ["launcher.exe", "tlou-ii.exe"])
        #expect(SteamAppInfo.windowsLaunch(appInfo: data, appID: 2_531_310)?.executable == "launcher.exe")
    }
}
