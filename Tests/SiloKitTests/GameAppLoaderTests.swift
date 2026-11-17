import Foundation
import Testing
@testable import SiloKit

@Suite("GameAppLoader — Wine's loader inside the game's app")
struct GameAppLoaderTests {
    /// A minimal thin 64-bit Mach-O: one `__TEXT` segment with an `__info_plist` section holding `plist`, padded.
    static func machO(plist: String, room: Int = 600) -> Data {
        var d = Data()
        func u32(_ v: UInt32) { var x = v.littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        func u64(_ v: UInt64) { var x = v.littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        func name(_ s: String) { var b = Array(s.utf8); b += Array(repeating: 0, count: 16 - b.count); d.append(contentsOf: b) }
        let headerSize = 32, commandSize = 72 + 80, contentOffset = headerSize + commandSize
        u32(0xfeed_facf); u32(0x0100_0007); u32(3); u32(2); u32(1); u32(UInt32(commandSize)); u32(0); u32(0)
        u32(0x19); u32(UInt32(commandSize)); name("__TEXT"); u64(0); u64(0); u64(0); u64(0); u32(5); u32(5); u32(1); u32(0)
        name("__info_plist"); name("__TEXT"); u64(0); u64(UInt64(room)); u32(UInt32(contentOffset)); u32(0); u32(0); u32(0)
        u32(0); u32(0); u32(0); u32(0)
        var body = Data(plist.utf8); body += Data(repeating: 0, count: room - body.count)
        d.append(body)
        d.append(Data("CODE".utf8))
        return d
    }

    static let wineloaderPlist = """
    <?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict>\
    <key>CFBundleIdentifier</key><string>com.codeweavers.CrossOver.wineloader</string>\
    <key>CFBundleShortVersionString</key><string>26.3</string><key>LSUIElement</key><true/></dict></plist>
    """

    private func runtime(_ root: URL, loader: String) throws -> URL {
        let unix = root.appendingPathComponent("lib/wine/x86_64-unix", isDirectory: true)
        try FileManager.default.createDirectory(at: unix.appendingPathComponent("D3DMetal.framework"),
                                                withIntermediateDirectories: true)
        try Self.machO(plist: Self.wineloaderPlist.replacingOccurrences(of: "26.3", with: loader))
            .write(to: unix.appendingPathComponent("wine"))
        try Data("ntdll".utf8).write(to: unix.appendingPathComponent("ntdll.so"))
        return unix
    }

    @Test("The loader's embedded plist gets the game's identity and Game Mode; kept keys stay, the rest goes")
    func rewritesEmbeddedPlist() throws {
        let original = Self.machO(plist: Self.wineloaderPlist)
        let out = try EmbeddedInfoPlist.rewrite(
            original, entries: EmbeddedInfoPlist.gameEntries(identifier: "com.mikael.silo.game.544750", name: "SC VI"))
        #expect(out.count == original.count)
        #expect(out.suffix(4) == Data("CODE".utf8))   // nothing outside the section moves
        let section = try EmbeddedInfoPlist.section(in: out)
        let bytes = out.subdata(in: section.contents)
        let length = Int(out.subdata(in: section.sizeFieldOffset..<section.sizeFieldOffset + 8)
            .withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) })
        let plist = try #require(PropertyListSerialization.propertyList(from: bytes.prefix(length), format: nil)
            as? [String: Any])
        #expect(plist["CFBundleIdentifier"] as? String == "com.mikael.silo.game.544750")
        #expect(plist["CFBundleName"] as? String == "SC VI")
        #expect(plist["LSApplicationCategoryType"] as? String == "public.app-category.games")
        #expect(plist["LSSupportsGameMode"] as? Bool == true)
        #expect(plist["CFBundleShortVersionString"] as? String == "26.3" && plist["LSUIElement"] as? Bool == true)
        #expect(throws: EmbeddedInfoPlist.Failure.self) { try EmbeddedInfoPlist.rewrite(Data("nope".utf8), entries: [:]) }
    }

    @Test("Executable names: file names only, each once, case-insensitively")
    func executables() {
        let urls = ["/g/Binaries/Win64/SoulcaliburVI.exe", "/g/soulcaliburvi.exe", "/g/Launcher.exe"]
            .map { URL(fileURLWithPath: $0) }
        #expect(GameAppLoader.executablesValue(urls) == "SoulcaliburVI.exe:Launcher.exe")
    }

    @Test("Staging: siblings symlinked, a private patched loader to sign, other files kept; idempotent once installed")
    func stages() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let unix = try runtime(tmp.url.appendingPathComponent("rt"), loader: "1.0")
        let macOS = tmp.url.appendingPathComponent("Game.app/Contents/MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        try Data("host".utf8).write(to: macOS.appendingPathComponent("SiloGameHost"))

        let staged = try GameAppLoader.stage(unixDir: unix, in: macOS, identifier: "com.mikael.silo.game.1", name: "G")
        let unsigned = try #require(staged.unsigned)
        #expect(staged.loader.lastPathComponent == "wine")
        #expect(try Data(contentsOf: unix.appendingPathComponent("wine")) == Self.machO(
            plist: Self.wineloaderPlist.replacingOccurrences(of: "26.3", with: "1.0")))   // runtime untouched
        #expect(try Data(contentsOf: unsigned) != Data(contentsOf: unix.appendingPathComponent("wine")))
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: macOS.appendingPathComponent("ntdll.so").path)
                == unix.appendingPathComponent("ntdll.so").path)
        #expect(FileManager.default.fileExists(atPath: macOS.appendingPathComponent("SiloGameHost").path))

        try GameAppLoader.install(staged, unixDir: unix, identifier: "com.mikael.silo.game.1", name: "G")
        #expect(FileManager.default.fileExists(atPath: staged.loader.path) && !FileManager.default.fileExists(atPath: unsigned.path))
        #expect(try GameAppLoader.stage(unixDir: unix, in: macOS, identifier: "com.mikael.silo.game.1", name: "G").unsigned == nil)
        // Another identity rebuilds.
        #expect(try GameAppLoader.stage(unixDir: unix, in: macOS, identifier: "com.mikael.silo.game.1", name: "H").unsigned != nil)
    }

    @Test("Another runtime repoints the siblings and rebuilds the loader")
    func restages() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let first = try runtime(tmp.url.appendingPathComponent("rt1"), loader: "1.0")
        let second = try runtime(tmp.url.appendingPathComponent("rt2"), loader: "2.0")
        try FileManager.default.removeItem(at: second.appendingPathComponent("D3DMetal.framework"))
        let macOS = tmp.url.appendingPathComponent("Game.app/Contents/MacOS", isDirectory: true)

        let one = try GameAppLoader.stage(unixDir: first, in: macOS, identifier: "i", name: "G")
        try GameAppLoader.install(one, unixDir: first, identifier: "i", name: "G")
        let two = try GameAppLoader.stage(unixDir: second, in: macOS, identifier: "i", name: "G")
        #expect(two.unsigned != nil)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: macOS.appendingPathComponent("ntdll.so").path)
                == second.appendingPathComponent("ntdll.so").path)
        #expect((try? FileManager.default.destinationOfSymbolicLink(
            atPath: macOS.appendingPathComponent("D3DMetal.framework").path)) == nil)
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
