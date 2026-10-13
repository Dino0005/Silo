import Foundation
import Testing
@testable import SiloKit

/// The depth fix ("Correzione profondità", `EnvFlags.depthFix`): the flag, the renamed D3DMetal copy kept in
/// the runtime, Silo's d3d11 proxy in the bottle's system32, and what a launch emits. Verified on device on
/// God of War, 2026-10-12 (GPTK through the proxy, DXMT through patch 0003).
@Suite("Depth fix")
struct DepthFixTests {
    let linker = GraphicsLinker()

    private func builtinPE(_ tag: String) -> Data {
        Data("MZ".utf8) + Data(count: 0x3e) + Data("Wine builtin DLL".utf8) + Data(tag.utf8)
    }

    /// A stand-in for Silo's proxy: any file carrying the marker.
    private func fakeProxy(_ tmp: TempDir, version: String = "1") throws -> URL {
        let url = tmp.url.appendingPathComponent("proxy-\(version).dll")
        try (Data("MZ".utf8) + GraphicsLinker.depthFixMarker + Data(version.utf8)).write(to: url)
        return url
    }

    // MARK: - Flag

    @Test("depthFix defaults to off, survives a round trip, and an old config without it decodes")
    func flagCodable() throws {
        #expect(EnvFlags().depthFix == false)
        let on = EnvFlags(depthFix: true)
        let decoded = try JSONDecoder().decode(EnvFlags.self, from: JSONEncoder().encode(on))
        #expect(decoded.depthFix == true)
        let legacy = try JSONDecoder().decode(EnvFlags.self, from: Data(#"{"metalHUD":true}"#.utf8))
        #expect(legacy.depthFix == false)
        // Like mediaFoundationNative it emits nothing itself — makePlan applies it.
        #expect(on.environment(graphics: .gptk) == EnvFlags().environment(graphics: .gptk))
    }

    // MARK: - The renamed copy in the runtime

    @Test("syncDepthFixRealModule keeps d3dm_d3d11.dll identical to d3d11.dll, and follows an update")
    func realModuleCopy() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let winDir = try tmp.makeDir("wine/lib/wine/x86_64-windows")
        try builtinPE("D3DMetal-1").write(to: winDir.appendingPathComponent("d3d11.dll"))
        try linker.syncDepthFixRealModule(in: winDir)
        let copy = winDir.appendingPathComponent(GraphicsLinker.depthFixRealModuleName)
        #expect(try Data(contentsOf: copy) == builtinPE("D3DMetal-1"))
        // A GPTK update replaces d3d11.dll — the copy must not go stale.
        try builtinPE("D3DMetal-2").write(to: winDir.appendingPathComponent("d3d11.dll"))
        try linker.syncDepthFixRealModule(in: winDir)
        #expect(try Data(contentsOf: copy) == builtinPE("D3DMetal-2"))
    }

    @Test("syncDepthFixRealModule is a no-op where there is no d3d11.dll")
    func realModuleCopyWithoutSource() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let winDir = try tmp.makeDir("wine/lib/wine/x86_64-windows")
        try linker.syncDepthFixRealModule(in: winDir)
        #expect(!FileManager.default.fileExists(
            atPath: winDir.appendingPathComponent(GraphicsLinker.depthFixRealModuleName).path))
    }

    // MARK: - The proxy in the bottle

    @Test("Enabling replaces Wine's own d3d11 in system32 with the proxy; disabling puts a placeholder back")
    func proxyOverWineOwn() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let prefix = tmp.url.appendingPathComponent("Bottle")
        let system32 = try tmp.makeDir("Bottle/drive_c/windows/system32")
        let dst = system32.appendingPathComponent("d3d11.dll")
        try builtinPE("wine-d3d11").write(to: dst)
        let proxy = try fakeProxy(tmp)

        try linker.syncDepthFixProxy(prefix: prefix, enabled: true, proxy: proxy)
        #expect(try Data(contentsOf: dst) == Data(contentsOf: proxy))
        // Wine's own copy is not "backed up": it is rebuilt as a placeholder (Wine then loads the builtin).
        #expect(!FileManager.default.fileExists(
            atPath: system32.appendingPathComponent(GraphicsLinker.depthFixBackupName).path))

        try linker.syncDepthFixProxy(prefix: prefix, enabled: false, proxy: proxy)
        #expect(try Data(contentsOf: dst) == WinePlaceholderDLL.bytes)
    }

    @Test("A foreign native d3d11 is moved aside while the proxy stands in, and comes back when it's off")
    func proxyOverForeignNative() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let prefix = tmp.url.appendingPathComponent("Bottle")
        let system32 = try tmp.makeDir("Bottle/drive_c/windows/system32")
        let dst = system32.appendingPathComponent("d3d11.dll")
        let foreign = Data("MZ someone else's native d3d11".utf8)
        try foreign.write(to: dst)
        let proxy = try fakeProxy(tmp)

        try linker.syncDepthFixProxy(prefix: prefix, enabled: true, proxy: proxy)
        #expect(try Data(contentsOf: dst) == Data(contentsOf: proxy))
        #expect(try Data(contentsOf: system32.appendingPathComponent(GraphicsLinker.depthFixBackupName)) == foreign)

        try linker.syncDepthFixProxy(prefix: prefix, enabled: false, proxy: proxy)
        #expect(try Data(contentsOf: dst) == foreign)
        #expect(!FileManager.default.fileExists(
            atPath: system32.appendingPathComponent(GraphicsLinker.depthFixBackupName).path))
    }

    @Test("Disabling never touches a d3d11 that isn't Silo's proxy")
    func disableLeavesOthersAlone() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let prefix = tmp.url.appendingPathComponent("Bottle")
        let system32 = try tmp.makeDir("Bottle/drive_c/windows/system32")
        let dst = system32.appendingPathComponent("d3d11.dll")
        for content in [builtinPE("wine-d3d11"), Data("MZ foreign".utf8)] {
            try content.write(to: dst)
            try linker.syncDepthFixProxy(prefix: prefix, enabled: false, proxy: nil)
            #expect(try Data(contentsOf: dst) == content)
        }
        // And with no file at all there is nothing to do.
        try FileManager.default.removeItem(at: dst)
        try linker.syncDepthFixProxy(prefix: prefix, enabled: false, proxy: nil)
        #expect(!FileManager.default.fileExists(atPath: dst.path))
    }

    @Test("Enabling is idempotent and updates an older proxy in place")
    func enableIdempotentAndUpdates() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let prefix = tmp.url.appendingPathComponent("Bottle")
        let dst = prefix.appendingPathComponent("drive_c/windows/system32/d3d11.dll")
        let v1 = try fakeProxy(tmp, version: "1")
        let v2 = try fakeProxy(tmp, version: "2")
        try linker.syncDepthFixProxy(prefix: prefix, enabled: true, proxy: v1)   // no system32 yet: created
        try linker.syncDepthFixProxy(prefix: prefix, enabled: true, proxy: v1)
        #expect(try Data(contentsOf: dst) == Data(contentsOf: v1))
        try linker.syncDepthFixProxy(prefix: prefix, enabled: true, proxy: v2)
        #expect(try Data(contentsOf: dst) == Data(contentsOf: v2))
        #expect(!FileManager.default.fileExists(atPath: dst.deletingLastPathComponent()
            .appendingPathComponent(GraphicsLinker.depthFixBackupName).path))   // our own file is never "foreign"
    }

    @Test("Enabling without a proxy file throws instead of silently launching unfixed")
    func enableWithoutProxyThrows() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        #expect(throws: GraphicsLinker.LinkError.self) {
            try linker.syncDepthFixProxy(prefix: tmp.url, enabled: true, proxy: nil)
        }
    }

    @Test("The proxy Silo ships is in its resources, a PE, and carries the marker")
    func bundledProxy() throws {
        let url = try #require(GraphicsLinker.bundledDepthFixProxy)
        let data = try Data(contentsOf: url)
        #expect(data.prefix(2) == Data("MZ".utf8))
        #expect(GraphicsLinker.isDepthFixProxy(data))
    }

    // MARK: - What a launch emits

    private let prefix = URL(fileURLWithPath: "/p/220")
    private let log = URL(fileURLWithPath: "/p/220.log")
    private let exe = URL(fileURLWithPath: "/lib/game/GoW.exe")

    private func backend() -> BackendConfig {
        var b = BackendConfig()
        b.wineBinaryPath = URL(fileURLWithPath: "/w/bin/wine64")
        b.gptkLibDirPath = URL(fileURLWithPath: "/g/lib/wine/x86_64-windows")
        b.dxmtLibDirPath = URL(fileURLWithPath: "/d/x86_64-windows")
        return b
    }

    private func plan(depthFix: Bool, graphics: GraphicsBackend, extra: [String: String] = [:]) throws -> LaunchPlan {
        var cfg = GameConfig(appID: 220)
        cfg.envFlags.depthFix = depthFix
        cfg.envFlags.extra = extra
        return try LaunchOrchestrator.makePlan(
            config: cfg, backend: backend(), graphics: graphics, gameExe: exe, prefix: prefix, logURL: log)
    }

    @Test("GPTK + depth fix: d3d11=n,b after the backend's set, and the proxy is pointed at the renamed copy")
    func planGPTK() throws {
        let env = try plan(depthFix: true, graphics: .gptk).environment
        #expect(env["WINEDLLOVERRIDES"] == GraphicsBackend.gptk.dllOverrides + ";d3d11=n,b")
        #expect(env["SILO_REAL_D3D11"] == #"Z:\w\lib\wine\x86_64-windows\d3dm_d3d11.dll"#)
        #expect(env["DXMT_CONFIG"] == nil)
    }

    @Test("A hand-written extra override still comes last, after the depth fix's")
    func planGPTKWithExtra() throws {
        let env = try plan(depthFix: true, graphics: .gptk, extra: ["WINEDLLOVERRIDES": "foo=d"]).environment
        #expect(env["WINEDLLOVERRIDES"] == GraphicsBackend.gptk.dllOverrides + ";d3d11=n,b;foo=d")
    }

    @Test("DXMT + depth fix: DXMT's own option, merged with a DXMT_CONFIG the user already set")
    func planDXMT() throws {
        let env = try plan(depthFix: true, graphics: .dxmt).environment
        #expect(env["DXMT_CONFIG"] == "d3d11.depthEqualAsGreaterEqual=True")
        #expect(env["SILO_REAL_D3D11"] == nil)
        #expect(env["WINEDLLOVERRIDES"] == GraphicsBackend.dxmt.dllOverrides)
        let merged = try plan(depthFix: true, graphics: .dxmt,
                              extra: ["DXMT_CONFIG": "d3d11.metalSpatialUpscaleFactor=2"]).environment
        #expect(merged["DXMT_CONFIG"] == "d3d11.metalSpatialUpscaleFactor=2;d3d11.depthEqualAsGreaterEqual=True")
    }

    @Test("Depth fix off: nothing of it in the plan, on either backend")
    func planOff() throws {
        for graphics in [GraphicsBackend.gptk, .dxmt] {
            let env = try plan(depthFix: false, graphics: graphics).environment
            #expect(env["WINEDLLOVERRIDES"] == graphics.dllOverrides)
            #expect(env["SILO_REAL_D3D11"] == nil)
            #expect(env["DXMT_CONFIG"] == nil)
        }
    }

    // MARK: - The copy at a fixed place, for NotProton

    @Test("stageDepthFixProxy puts the proxy at depth-fix/d3d11.dll, leaves it alone when current, follows an update")
    func stagedForNotProton() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let dir = AppPaths(supportDir: tmp.url).depthFixDir
        #expect(dir.lastPathComponent == "depth-fix")
        #expect(dir.deletingLastPathComponent().lastPathComponent == "Runtimes")
        let dst = dir.appendingPathComponent("d3d11.dll")

        let v1 = try fakeProxy(tmp, version: "1")
        try linker.stageDepthFixProxy(into: dir, proxy: v1)
        #expect(try Data(contentsOf: dst) == Data(contentsOf: v1))
        let inode = try FileManager.default.attributesOfItem(atPath: dst.path)[.systemFileNumber] as? Int

        try linker.stageDepthFixProxy(into: dir, proxy: v1)
        #expect(try FileManager.default.attributesOfItem(atPath: dst.path)[.systemFileNumber] as? Int == inode)

        let v2 = try fakeProxy(tmp, version: "2")
        try linker.stageDepthFixProxy(into: dir, proxy: v2)
        #expect(try Data(contentsOf: dst) == Data(contentsOf: v2))
        // No staging leftovers beside it.
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["d3d11.dll"])
    }

    @Test("stageDepthFixProxy without a proxy throws and writes nothing")
    func stagedWithoutProxy() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let dir = AppPaths(supportDir: tmp.url).depthFixDir
        #expect(throws: (any Error).self) { try linker.stageDepthFixProxy(into: dir, proxy: nil) }
        #expect(!FileManager.default.fileExists(atPath: dir.path))
    }

}
