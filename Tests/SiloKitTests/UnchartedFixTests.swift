import Foundation
import Testing
@testable import SiloKit

/// The Uncharted fix (`UnchartedFix`): Silo's d3d12.dll proxy in UNCHARTED: Legacy of Thieves Collection's folder,
/// which makes the game's extra resource Releases harmless (no crash at the menu quit). Verified on device 2026-11-22.
@Suite("Uncharted fix")
struct UnchartedFixTests {
    let proxy = Data("MZ".utf8) + UnchartedFix.marker + Data(" v1".utf8)

    private func folder(_ tmp: TempDir, exe: String = "u4.exe") throws -> URL {
        let url = tmp.url.appendingPathComponent(exe)
        try Data("MZ game".utf8).write(to: url)
        return url
    }

    private func proxyFile(_ exe: URL) -> URL {
        exe.deletingLastPathComponent().appendingPathComponent(UnchartedFix.proxyName)
    }

    // MARK: - The game folder

    @Test("On: the proxy goes into the game folder, then is reported in place")
    func install() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let exe = try folder(tmp)
        let fix = UnchartedFix(proxy: proxy)
        #expect(fix.sync(gameExe: exe, enabled: true) == .installed)
        #expect(try Data(contentsOf: proxyFile(exe)) == proxy)
        #expect(fix.sync(gameExe: exe, enabled: true) == .upToDate)
        #expect(UnchartedFix.Outcome.installed.isActive && UnchartedFix.Outcome.upToDate.isActive)
    }

    @Test("Every exe of the collection counts, in any case; other games are left alone")
    func whichGame() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        for name in ["u4.exe", "U4-L.EXE", "tll.exe", "tll-l.exe"] {
            #expect(UnchartedFix.isThisGame(tmp.url.appendingPathComponent(name)), "\(name)")
        }
        let other = try folder(tmp, exe: "GoW.exe")
        #expect(UnchartedFix(proxy: proxy).sync(gameExe: other, enabled: true) == .notThisGame)
        #expect(!FileManager.default.fileExists(atPath: proxyFile(other).path))
    }

    @Test("A newer proxy from a Silo update replaces the old one")
    func refresh() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let exe = try folder(tmp)
        _ = UnchartedFix(proxy: proxy).sync(gameExe: exe, enabled: true)
        let newer = Data("MZ".utf8) + UnchartedFix.marker + Data(" v2".utf8)
        #expect(UnchartedFix(proxy: newer).sync(gameExe: exe, enabled: true) == .installed)
        #expect(try Data(contentsOf: proxyFile(exe)) == newer)
    }

    @Test("Off: Silo's proxy is taken away; nothing to do when it isn't there")
    func remove() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let exe = try folder(tmp)
        let fix = UnchartedFix(proxy: proxy)
        _ = fix.sync(gameExe: exe, enabled: true)
        #expect(fix.sync(gameExe: exe, enabled: false) == .removed)
        #expect(!FileManager.default.fileExists(atPath: proxyFile(exe).path))
        #expect(fix.sync(gameExe: exe, enabled: false) == .nothingToRemove)
        #expect(!UnchartedFix.Outcome.removed.isActive)
    }

    @Test("A d3d12.dll that isn't Silo's is never touched, on or off")
    func foreignFile() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let exe = try folder(tmp)
        let foreign = Data("MZ someone else's d3d12".utf8)
        try foreign.write(to: proxyFile(exe))
        let fix = UnchartedFix(proxy: proxy)
        let on = fix.sync(gameExe: exe, enabled: true)
        #expect(!on.isActive)
        if case .failed = on {} else { Issue.record("expected .failed, got \(on)") }
        #expect(fix.sync(gameExe: exe, enabled: false) == .nothingToRemove)
        #expect(try Data(contentsOf: proxyFile(exe)) == foreign)
    }

    @Test("Without the proxy in Silo's resources it fails, and the folder stays as it is")
    func missingProxy() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let exe = try folder(tmp)
        let outcome = UnchartedFix(proxy: nil).sync(gameExe: exe, enabled: true)
        #expect(!outcome.isActive)
        #expect(!FileManager.default.fileExists(atPath: proxyFile(exe).path))
    }

    @Test("The bundled proxy carries the marker Silo looks for")
    func bundledProxy() throws {
        let data = try #require(UnchartedFix.bundledProxy())
        #expect(UnchartedFix.isProxy(data))
    }

    // MARK: - The setting

    @Test("On by default, also for a config written before the option existed; round-trips")
    func flag() throws {
        #expect(EnvFlags().unchartedFix)
        let legacy = try JSONDecoder().decode(EnvFlags.self, from: Data(#"{"metalHUD":true}"#.utf8))
        #expect(legacy.unchartedFix)
        var off = EnvFlags()
        off.unchartedFix = false
        let back = try JSONDecoder().decode(EnvFlags.self, from: JSONEncoder().encode(off))
        #expect(!back.unchartedFix)
        // It emits nothing itself — makePlan applies it, only when the proxy is in place.
        #expect(off.environment(graphics: .gptk) == EnvFlags().environment(graphics: .gptk))
    }

    @Test("Steam's Compatibility page reads and sets it like the other switches")
    func steamPage() {
        var config = GameConfig(appID: UnchartedFix.appID)
        #expect(SteamGameSettings.value(.unchartedFix, of: config) == "1")
        #expect(SteamGameSettings.set(.unchartedFix, to: "0", in: &config))
        #expect(!config.envFlags.unchartedFix)
        #expect(!SteamGameSettings.set(.unchartedFix, to: "maybe", in: &config))
    }

    // MARK: - The renamed copy in the runtime

    @Test("The runtime keeps d3dm_d3d12.dll identical to D3DMetal's d3d12.dll, beside d3dm_d3d11.dll")
    func realModuleCopy() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let winDir = try tmp.makeDir("wine/lib/wine/x86_64-windows")
        try Data("MZ d3d12 v1".utf8).write(to: winDir.appendingPathComponent("d3d12.dll"))
        try GraphicsLinker().syncDepthFixRealModule(in: winDir)
        let copy = winDir.appendingPathComponent(UnchartedFix.realModuleName)
        #expect(try Data(contentsOf: copy) == Data("MZ d3d12 v1".utf8))
        try Data("MZ d3d12 v2".utf8).write(to: winDir.appendingPathComponent("d3d12.dll"))
        try GraphicsLinker().syncDepthFixRealModule(in: winDir)
        #expect(try Data(contentsOf: copy) == Data("MZ d3d12 v2".utf8))
        // No d3d11.dll there: its copy isn't invented.
        #expect(!FileManager.default.fileExists(
            atPath: winDir.appendingPathComponent(GraphicsLinker.depthFixRealModuleName).path))
    }

    // MARK: - What a launch emits

    private func backend() -> BackendConfig {
        var b = BackendConfig()
        b.wineBinaryPath = URL(fileURLWithPath: "/w/bin/wine64")
        b.gptkLibDirPath = URL(fileURLWithPath: "/g/lib/wine/x86_64-windows")
        b.dxmtLibDirPath = URL(fileURLWithPath: "/d/x86_64-windows")
        return b
    }

    private func plan(active: Bool, graphics: GraphicsBackend, extra: [String: String] = [:],
                      depthFix: Bool = false) throws -> LaunchPlan {
        var cfg = GameConfig(appID: UnchartedFix.appID)
        cfg.envFlags.extra = extra
        cfg.envFlags.depthFix = depthFix
        return try LaunchOrchestrator.makePlan(
            config: cfg, backend: backend(), graphics: graphics,
            gameExe: URL(fileURLWithPath: "/lib/game/u4.exe"), prefix: URL(fileURLWithPath: "/p/1659420"),
            logURL: URL(fileURLWithPath: "/p/1659420.log"), unchartedFix: active)
    }

    @Test("GPTK with the proxy in place: d3d12=n,b after the backend's set, pointed at the renamed copy")
    func planActive() throws {
        let env = try plan(active: true, graphics: .gptk).environment
        #expect(env["WINEDLLOVERRIDES"] == GraphicsBackend.gptk.dllOverrides + ";d3d12=n,b")
        #expect(env["SILO_REAL_D3D12"] == #"Z:\w\lib\wine\x86_64-windows\d3dm_d3d12.dll"#)
    }

    @Test("A hand-written extra override still comes last; the depth fix (God of War's) stays out even if on")
    func planWithOthers() throws {
        let env = try plan(active: true, graphics: .gptk, extra: ["WINEDLLOVERRIDES": "foo=d"], depthFix: true)
            .environment
        #expect(env["WINEDLLOVERRIDES"] == GraphicsBackend.gptk.dllOverrides + ";d3d12=n,b;foo=d")
        #expect(env["SILO_REAL_D3D11"] == nil)
    }

    @Test("Not in place, or under DXMT: the launch is exactly as without the fix")
    func planInactive() throws {
        let gptk = try plan(active: false, graphics: .gptk).environment
        #expect(gptk["WINEDLLOVERRIDES"] == GraphicsBackend.gptk.dllOverrides)
        #expect(gptk["SILO_REAL_D3D12"] == nil)
        let dxmt = try plan(active: true, graphics: .dxmt).environment
        #expect(dxmt["SILO_REAL_D3D12"] == nil)
        #expect(!(dxmt["WINEDLLOVERRIDES"] ?? "").contains("d3d12=n,b"))
    }
}
