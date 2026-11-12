import Foundation
import Testing
@testable import SiloKit

@Suite("GameAppLoader — Wine's loader inside the game's app")
struct GameAppLoaderTests {
    private func runtime(_ root: URL, loader: String) throws -> URL {
        let unix = root.appendingPathComponent("lib/wine/x86_64-unix", isDirectory: true)
        try FileManager.default.createDirectory(at: unix.appendingPathComponent("D3DMetal.framework"),
                                                withIntermediateDirectories: true)
        try Data(loader.utf8).write(to: unix.appendingPathComponent("wine"))
        try Data("ntdll".utf8).write(to: unix.appendingPathComponent("ntdll.so"))
        return unix
    }

    @Test("Executable names: file names only, each once, case-insensitively")
    func executables() {
        let urls = ["/g/Binaries/Win64/SoulcaliburVI.exe", "/g/soulcaliburvi.exe", "/g/Launcher.exe"]
            .map { URL(fileURLWithPath: $0) }
        #expect(GameAppLoader.executablesValue(urls) == "SoulcaliburVI.exe:Launcher.exe")
    }

    @Test("The loader is linked into the bundle with every sibling symlinked; other files stay")
    func stages() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let unix = try runtime(tmp.url.appendingPathComponent("rt"), loader: "loader-1")
        let macOS = tmp.url.appendingPathComponent("Game.app/Contents/MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        try Data("host".utf8).write(to: macOS.appendingPathComponent("SiloGameHost"))

        let loader = try GameAppLoader.stage(unixDir: unix, in: macOS)
        #expect(loader.lastPathComponent == "wine")
        #expect(try String(contentsOf: loader, encoding: .utf8) == "loader-1")
        let a = try FileManager.default.attributesOfItem(atPath: loader.path)[.systemFileNumber] as? Int
        let b = try FileManager.default.attributesOfItem(atPath: unix.appendingPathComponent("wine").path)[.systemFileNumber] as? Int
        #expect(a == b)   // a hard link, not a copy
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: macOS.appendingPathComponent("ntdll.so").path)
                == unix.appendingPathComponent("ntdll.so").path)
        #expect(try FileManager.default.destinationOfSymbolicLink(
            atPath: macOS.appendingPathComponent("D3DMetal.framework").path)
                == unix.appendingPathComponent("D3DMetal.framework").path)
        #expect(FileManager.default.fileExists(atPath: macOS.appendingPathComponent("SiloGameHost").path))
        // Idempotent.
        #expect(try GameAppLoader.stage(unixDir: unix, in: macOS) == loader)
    }

    @Test("Another runtime replaces the loader and repoints the siblings")
    func restages() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let first = try runtime(tmp.url.appendingPathComponent("rt1"), loader: "loader-1")
        let second = try runtime(tmp.url.appendingPathComponent("rt2"), loader: "loader-2")
        try FileManager.default.removeItem(at: second.appendingPathComponent("D3DMetal.framework"))
        let macOS = tmp.url.appendingPathComponent("Game.app/Contents/MacOS", isDirectory: true)

        try GameAppLoader.stage(unixDir: first, in: macOS)
        let loader = try GameAppLoader.stage(unixDir: second, in: macOS)
        #expect(try String(contentsOf: loader, encoding: .utf8) == "loader-2")
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: macOS.appendingPathComponent("ntdll.so").path)
                == second.appendingPathComponent("ntdll.so").path)
        #expect((try? FileManager.default.destinationOfSymbolicLink(
            atPath: macOS.appendingPathComponent("D3DMetal.framework").path)) == nil)   // gone with the old runtime
    }

    @Test("A game app declares the loader as its executable, has its own identifier and the games category")
    func gameAppPlist() {
        let plist = GameHostBundle(name: "SOULCALIBUR VI", id: "544750",
                                   executable: GameAppLoader.loaderName, idPrefix: GameHostBundle.gameAppIDPrefix)
            .infoPlist()
        #expect(plist.contains("<key>CFBundleExecutable</key><string>wine</string>"))
        #expect(plist.contains("<string>com.mikael.silo.game.544750</string>"))
        #expect(plist.contains("public.app-category.games") && plist.contains("LSSupportsGameMode"))
        // The host keeps its own.
        let host = GameHostBundle(name: "SOULCALIBUR VI", id: "544750").infoPlist()
        #expect(host.contains("<key>CFBundleExecutable</key><string>SiloGameHost</string>"))
        #expect(host.contains("<string>com.mikael.silo.host.544750</string>"))
    }

    @Test("Every command of the launch carries the game app's variables with Steam's libraries")
    func runnerEnvironment() async throws {
        let fake = FakeProcessRunner()
        let runner = SteamLibrariesRunner(base: fake, libraries: "/A/silo-game-loader.dylib:/S/steamloader.dylib",
                                          extraEnvironment: [GameAppLoader.loaderEnvKey: "/H/Game.app/Contents/MacOS/wine",
                                                             GameAppLoader.executablesEnvKey: "Game.exe"])
        _ = try await runner.run(executable: URL(fileURLWithPath: "/w"), arguments: ["regedit"],
                                 environment: ["WINEPREFIX": "/b"], currentDirectory: nil)
        let env = try #require(fake.invocations.first?.environment)
        #expect(env[GameAppLoader.loaderEnvKey] == "/H/Game.app/Contents/MacOS/wine")
        #expect(env[GameAppLoader.executablesEnvKey] == "Game.exe")
        #expect(env[NativeSteamBridge.overlayEnvKey] == "/A/silo-game-loader.dylib:/S/steamloader.dylib")
        #expect(env["WINEPREFIX"] == "/b")
    }
}
