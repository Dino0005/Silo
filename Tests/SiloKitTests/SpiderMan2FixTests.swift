import Foundation
import Testing
@testable import SiloKit

/// The Spider-Man 2 fix (`SpiderMan2Fix`): Silo's amd_ags_x64.dll carrier for macprotips' T-pose fix, synced into
/// the game's folder before each launch. Verified on device 2026-11-22 (M3 Pro, GPTK, Metal 3).
@Suite("Spider-Man 2 fix")
struct SpiderMan2FixTests {
    /// Counts shader builds; an actor so the `@Sendable` builder closure can bump it.
    actor Builds {
        var count = 0
        func bump() { count += 1 }
    }

    /// A minimal PE: "MZ", e_lfanew = 0x80, "PE\0\0", TimeDateStamp, SizeOfImage.
    static func pe(stamp: UInt32, image: UInt32) -> Data {
        var bytes = [UInt8](repeating: 0, count: 0x200)
        bytes[0] = 0x4d; bytes[1] = 0x5a
        func put(_ value: UInt32, at offset: Int) {
            for i in 0..<4 { bytes[offset + i] = UInt8((value >> (8 * UInt32(i))) & 0xff) }
        }
        put(0x80, at: 0x3c)
        put(0x0000_4550, at: 0x80)
        put(stamp, at: 0x80 + 8)
        put(image, at: 0x80 + 24 + 56)
        return Data(bytes)
    }

    let original = Data("MZ the game's own AGS".utf8)
    let carrier = Data("MZ".utf8) + SpiderMan2Fix.marker + Data(" v1".utf8)

    /// A game folder with the exe and the game's own DLL.
    private func gameFolder(_ tmp: TempDir, stamp: UInt32 = 0x6a79_a155) throws -> URL {
        let exe = tmp.url.appendingPathComponent(SpiderMan2Fix.executableName)
        try Self.pe(stamp: stamp, image: 0x0d06_9000).write(to: exe)
        try original.write(to: tmp.url.appendingPathComponent(SpiderMan2Fix.agsName))
        return exe
    }

    private func fix(_ builds: Builds, fail: Bool = false) -> SpiderMan2Fix {
        SpiderMan2Fix(carrier: carrier) { _ in
            await builds.bump()
            if fail { throw ShaderBuilder.Failure.shaderNotFound("CS_ModelSkinning") }
            var files: [String: Data] = [:]
            for shader in SpiderMan2Fix.shaders { files[shader.fileName] = Data("DXBC".utf8) }
            return files
        }
    }

    private func read(_ tmp: TempDir, _ name: String) -> Data? {
        try? Data(contentsOf: tmp.url.appendingPathComponent(name))
    }

    private func siloFiles(_ tmp: TempDir) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: tmp.url.path)) ?? [])
            .filter { $0.hasPrefix("silo-sm2-") || $0 == SpiderMan2Fix.realAGSName }
    }

    // MARK: - Pure pieces

    @Test("the game build is the PE timestamp and SizeOfImage, as the carrier reads them")
    func gameBuild() {
        #expect(SpiderMan2Fix.gameBuild(peHeader: Self.pe(stamp: 0x6a79_a155, image: 0x0d06_9000)) == "6a79a155-0d069000")
        #expect(SpiderMan2Fix.gameBuild(peHeader: Data("not a PE".utf8)) == nil)
        #expect(SpiderMan2Fix.gameBuild(peHeader: Data("MZ".utf8) + Data(count: 0x40)) == nil)
    }

    @Test("the settings file names the build, the four shaders and the fog barrier, and reads back")
    func settings() {
        let text = SpiderMan2Fix.settings(build: "6a79a155-0d069000")
        #expect(SpiderMan2Fix.settingsBuild(text) == "6a79a155-0d069000")
        #expect(text.contains("shaders = 3d50acdb571dce22 14902794dd7134e4 9538ca33c087a84c 125a4957ab64d24d"))
        #expect(text.contains("fog_barrier = 1"))
        #expect(SpiderMan2Fix.shaders[0].fileName == "silo-sm2-pool-3d50acdb571dce22.dxil")
    }

    @Test("the bundled carrier is in the resources and carries its marker")
    func bundledCarrier() throws {
        let data = try #require(SpiderMan2Fix.bundledCarrier())
        #expect(SpiderMan2Fix.isCarrier(data))
        #expect(data.prefix(2) == Data("MZ".utf8))
    }

    @Test("a shader container is found in the exe by its hash")
    func findsContainer() {
        // DXBC header: magic, 16-byte digest, version 1.0, total size (32), part count.
        var container = Data("DXBC".utf8) + Data(count: 16)
        container += Data([1, 0, 0, 0, 32, 0, 0, 0, 0, 0, 0, 0])
        let exe = Data(repeating: 0x90, count: 100) + container + Data(repeating: 0xcc, count: 50)
        let hash = ShaderBuilder.hash(container)
        #expect(ShaderBuilder.container(hash, in: exe) == container)
        #expect(ShaderBuilder.container(hash &+ 1, in: exe) == nil)
    }

    @Test("the shader tools come from this repo's dxc-<commit> release")
    func toolsRelease() throws {
        let tmp = try TempDir()
        let tools = DXCTools(paths: AppPaths(supportDir: tmp.url), runner: FakeProcessRunner(),
                             repo: "Dino0005/Silo", commit: "6e0fab36dc9ac8c423e1b08fed3aeb0e739d9e54")
        #expect(tools.tag == "dxc-6e0fab36")
        #expect(tools.downloadURL.absoluteString
                == "https://github.com/Dino0005/Silo/releases/download/dxc-6e0fab36/dxc.tar.xz")
        #expect(tools.isInstalled == false)
    }

    // MARK: - The flag

    @Test("spiderMan2Fix defaults to on, also for a config saved before it existed, and round-trips off")
    func flagCodable() throws {
        #expect(EnvFlags().spiderMan2Fix == true)
        let legacy = try JSONDecoder().decode(EnvFlags.self, from: Data(#"{"metalHUD":true}"#.utf8))
        #expect(legacy.spiderMan2Fix == true)
        let off = try JSONDecoder().decode(EnvFlags.self, from: JSONEncoder().encode(EnvFlags(spiderMan2Fix: false)))
        #expect(off.spiderMan2Fix == false)
    }

    @Test("Steam's Compatibility page carries the switch, for Spider-Man 2 only")
    func steamPage() {
        var config = GameConfig(appID: SpiderMan2Fix.appID)
        #expect(SteamGameSettings.value(.spiderMan2Fix, of: config) == "1")
        #expect(SteamGameSettings.set(.spiderMan2Fix, to: "0", in: &config))
        #expect(config.envFlags.spiderMan2Fix == false)
        #expect(SteamCompatibilityPage.template.contains("appid === \(SpiderMan2Fix.appID)"))
    }

    // MARK: - The game folder

    @Test("another game's exe is left alone")
    func notThisGame() async throws {
        let tmp = try TempDir()
        let builds = Builds()
        let outcome = await fix(builds).sync(gameExe: tmp.url.appendingPathComponent("TEKKEN 8.exe"), enabled: true)
        #expect(outcome == .notThisGame)
        #expect(await builds.count == 0)
    }

    @Test("install: shaders + settings written, the game's DLL renamed, the carrier in its place; then up to date")
    func install() async throws {
        let tmp = try TempDir()
        let exe = try gameFolder(tmp)
        let builds = Builds()
        #expect(await fix(builds).sync(gameExe: exe, enabled: true) == .installed)
        #expect(read(tmp, SpiderMan2Fix.agsName) == carrier)
        #expect(read(tmp, SpiderMan2Fix.realAGSName) == original)
        for shader in SpiderMan2Fix.shaders { #expect(read(tmp, shader.fileName) != nil) }
        let settings = try #require(read(tmp, SpiderMan2Fix.settingsName))
        #expect(SpiderMan2Fix.settingsBuild(String(decoding: settings, as: UTF8.self)) == "6a79a155-0d069000")

        #expect(await fix(builds).sync(gameExe: exe, enabled: true) == .upToDate)
        #expect(await builds.count == 1)   // nothing rebuilt
    }

    @Test("a game update rebuilds the shaders; a DLL Steam restored is moved aside again")
    func afterUpdate() async throws {
        let tmp = try TempDir()
        let exe = try gameFolder(tmp)
        let builds = Builds()
        _ = await fix(builds).sync(gameExe: exe, enabled: true)

        // New game build: new exe, and Steam put a (new) original DLL back over the carrier.
        try Self.pe(stamp: 0x6b00_0000, image: 0x0d06_9000).write(to: exe)
        let updated = Data("MZ the game's new AGS".utf8)
        try updated.write(to: tmp.url.appendingPathComponent(SpiderMan2Fix.agsName))
        #expect(await fix(builds).sync(gameExe: exe, enabled: true) == .installed)
        #expect(await builds.count == 2)
        #expect(read(tmp, SpiderMan2Fix.agsName) == carrier)
        #expect(read(tmp, SpiderMan2Fix.realAGSName) == updated)
    }

    @Test("off: the game's own DLL back and every Silo file gone; then nothing to remove")
    func remove() async throws {
        let tmp = try TempDir()
        let exe = try gameFolder(tmp)
        let builds = Builds()
        _ = await fix(builds).sync(gameExe: exe, enabled: true)
        try Data("log".utf8).write(to: tmp.url.appendingPathComponent(SpiderMan2Fix.logName))

        #expect(await fix(builds).sync(gameExe: exe, enabled: false) == .removed)
        #expect(read(tmp, SpiderMan2Fix.agsName) == original)
        #expect(siloFiles(tmp).isEmpty)
        #expect(await fix(builds).sync(gameExe: exe, enabled: false) == .nothingToRemove)
    }

    @Test("off after Steam restored the DLL: the stale copy goes, Steam's file stays")
    func removeAfterSteamRestore() async throws {
        let tmp = try TempDir()
        let exe = try gameFolder(tmp)
        _ = await fix(Builds()).sync(gameExe: exe, enabled: true)
        let restored = Data("MZ restored by Steam".utf8)
        try restored.write(to: tmp.url.appendingPathComponent(SpiderMan2Fix.agsName))

        #expect(await fix(Builds()).sync(gameExe: exe, enabled: false) == .removed)
        #expect(read(tmp, SpiderMan2Fix.agsName) == restored)
        #expect(siloFiles(tmp).isEmpty)
    }

    @Test("a failed shader build leaves the folder as the game shipped it")
    func buildFails() async throws {
        let tmp = try TempDir()
        let exe = try gameFolder(tmp)
        let outcome = await fix(Builds(), fail: true).sync(gameExe: exe, enabled: true)
        guard case .failed(let reason) = outcome else {
            Issue.record("expected .failed, got \(outcome)")
            return
        }
        #expect(reason.contains("isn't supported yet"))
        #expect(read(tmp, SpiderMan2Fix.agsName) == original)
        #expect(siloFiles(tmp).isEmpty)
    }

    @Test("without the game's own DLL nothing is installed")
    func noOriginal() async throws {
        let tmp = try TempDir()
        let exe = try gameFolder(tmp)
        try FileManager.default.removeItem(at: tmp.url.appendingPathComponent(SpiderMan2Fix.agsName))
        let outcome = await fix(Builds()).sync(gameExe: exe, enabled: true)
        #expect(outcome == .failed("the game's \(SpiderMan2Fix.agsName) is missing"))
        #expect(read(tmp, SpiderMan2Fix.agsName) == nil)
        #expect(siloFiles(tmp).isEmpty)
    }
}
