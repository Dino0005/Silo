import Foundation
import Testing
@testable import SiloKit

/// MetalFX under DXMT: for a game that ships DLSS, with a DXMT that ships its NVIDIA extensions, the game's DLSS
/// on DXMT's own `nvapi64`/`nvngx` (→ MetalFX's temporal scaler); for any other game, MetalFX's spatial upscale
/// of the swapchain. Verified on device on God of War, 2026-10-21 (DLSS offered and working with only
/// `DXMT_ENABLE_NVEXT` + the two modules).
@Suite("DXMT DLSS")
struct DXMTDLSSTests {
    private let prefix = URL(fileURLWithPath: "/p/220")
    private let log = URL(fileURLWithPath: "/p/220.log")
    private let exe = URL(fileURLWithPath: "/lib/game/GoW.exe")

    private func backend(dxmtLib: URL = URL(fileURLWithPath: "/d/x86_64-windows")) -> BackendConfig {
        var b = BackendConfig()
        b.wineBinaryPath = URL(fileURLWithPath: "/w/bin/wine64")
        b.gptkLibDirPath = URL(fileURLWithPath: "/g/lib/wine/x86_64-windows")
        b.dxmtLibDirPath = dxmtLib
        return b
    }

    private func env(metalFX: Bool, graphics: GraphicsBackend, dlss: Bool,
                     extra: [String: String] = [:]) throws -> [String: String] {
        var cfg = GameConfig(appID: 220)
        cfg.envFlags.metalFX = metalFX
        cfg.envFlags.extra = extra
        return try LaunchOrchestrator.makePlan(
            config: cfg, backend: backend(), graphics: graphics, gameExe: exe, prefix: prefix, logURL: log,
            dxmtDLSS: dlss).environment
    }

    @Test("DXMT + MetalFX + DLSS available: NVEXT on and the pair claimed as builtin, after the backend's =")
    func enabled() throws {
        let e = try env(metalFX: true, graphics: .dxmt, dlss: true)
        #expect(e["DXMT_ENABLE_NVEXT"] == "1")
        #expect(e["WINEDLLOVERRIDES"] == GraphicsBackend.dxmt.dllOverrides + ";nvapi64,nvngx=b")
        #expect(e["DXMT_METALFX_SPATIAL_SWAPCHAIN"] == nil)   // DLSS's upscale replaces the spatial one
        #expect(e["D3DM_ENABLE_METALFX"] == nil)
    }

    @Test("A hand-written extra override still comes last")
    func extraStillLast() throws {
        let e = try env(metalFX: true, graphics: .dxmt, dlss: true, extra: ["WINEDLLOVERRIDES": "nvngx="])
        #expect(e["WINEDLLOVERRIDES"] == GraphicsBackend.dxmt.dllOverrides + ";nvapi64,nvngx=b;nvngx=")
    }

    @Test("DXMT + MetalFX without DLSS: the spatial upscale, the adapter left alone")
    func spatialWithoutDLSS() throws {
        let e = try env(metalFX: true, graphics: .dxmt, dlss: false)
        #expect(e["DXMT_METALFX_SPATIAL_SWAPCHAIN"] == "1")
        #expect(e["DXMT_ENABLE_NVEXT"] == nil)
        #expect(e["WINEDLLOVERRIDES"] == GraphicsBackend.dxmt.dllOverrides)
    }

    @Test("Nothing of it with MetalFX off, and GPTK keeps D3DMetal's own switch")
    func disabled() throws {
        for dlss in [true, false] {
            let e = try env(metalFX: false, graphics: .dxmt, dlss: dlss)
            #expect(e["DXMT_ENABLE_NVEXT"] == nil)
            #expect(e["DXMT_METALFX_SPATIAL_SWAPCHAIN"] == nil)
            #expect(e["WINEDLLOVERRIDES"] == GraphicsBackend.dxmt.dllOverrides)
        }
        let gptk = try env(metalFX: true, graphics: .gptk, dlss: true)
        #expect(gptk["DXMT_ENABLE_NVEXT"] == nil)
        #expect(gptk["DXMT_METALFX_SPATIAL_SWAPCHAIN"] == nil)
        #expect(gptk["D3DM_ENABLE_METALFX"] == "1")
        #expect(gptk["WINEDLLOVERRIDES"] == GraphicsBackend.gptk.dllOverrides)
    }

    @Test("dxmtShipsNVIDIAExtensions reads the installed DXMT's module dir")
    func detection() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let lib = try tmp.makeDir("dxmt/x86_64-windows")
        try tmp.write("dxmt/x86_64-windows/d3d11.dll", "PE")
        #expect(!LaunchOrchestrator.dxmtShipsNVIDIAExtensions(backend(dxmtLib: lib)))
        try tmp.write("dxmt/x86_64-windows/nvngx.dll", "PE")
        #expect(LaunchOrchestrator.dxmtShipsNVIDIAExtensions(backend(dxmtLib: lib)))
        var none = backend(); none.dxmtLibDirPath = nil
        #expect(!LaunchOrchestrator.dxmtShipsNVIDIAExtensions(none))
    }

    // MARK: - DLSSDetector

    @Test("A game ships DLSS: nvngx_dlss.dll beside the exe (God of War)")
    func dlssBesideExe() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let exe = try tmp.write("GoW/GoW.exe", "MZ")
        #expect(!DLSSDetector.gameShipsDLSS(exe: exe))
        try tmp.write("GoW/nvngx_dlss.dll", "MZ")
        #expect(DLSSDetector.gameShipsDLSS(exe: exe))
    }

    @Test("Unreal: found in the engine's plugin folder, from the launcher or from the Shipping exe")
    func dlssUnreal() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let launcher = try tmp.write("Game/Game.exe", "MZ")
        let shipping = try tmp.write("Game/Proj/Binaries/Win64/Proj-Win64-Shipping.exe", "MZ")
        #expect(!DLSSDetector.gameShipsDLSS(exe: shipping))
        try tmp.write("Game/Engine/Plugins/Runtime/Nvidia/DLSS/Binaries/ThirdParty/Win64/nvngx_dlss.dll", "MZ")
        #expect(DLSSDetector.gameShipsDLSS(exe: launcher))
        #expect(DLSSDetector.gameShipsDLSS(exe: shipping))
        #expect(DLSSDetector.searchRoot(forExe: shipping).standardizedFileURL.path
                == tmp.url.appendingPathComponent("Game").standardizedFileURL.path)
    }

    @Test("The search never leaves the game: a sibling game's DLSS doesn't count")
    func dlssStaysInTheGame() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let exe = try tmp.write("Library/FatalFury/FF.exe", "MZ")
        try tmp.write("Library/GoW/nvngx_dlss.dll", "MZ")
        #expect(!DLSSDetector.gameShipsDLSS(exe: exe))
    }
}
