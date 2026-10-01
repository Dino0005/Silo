import Foundation
import Testing
@testable import SiloKit

@Suite("RuntimeVariants")
struct RuntimeVariantsTests {

    /// Minimal base wine runtime tree + a marker file so a clone (or its absence) is detectable.
    private func makeWine(_ tmp: TempDir) throws -> URL {
        try tmp.makeDir("wine/lib/wine/x86_64-windows")
        try tmp.makeDir("wine/lib/wine/x86_64-unix")
        try tmp.write("wine/share/marker.txt", "BASE")
        return try tmp.write("wine/bin/wine64", "#!/bin/sh")
    }

    /// A DXMT module dir (the `x86_64-windows` folder `BackendConfig.dxmtLibDirPath` points at).
    private func makeDXMT(_ tmp: TempDir) throws -> URL {
        let lib = try tmp.makeDir("dxmt/lib/wine/x86_64-windows")
        for module in ["d3d11.dll", "d3d10core.dll", "dxgi.dll", "winemetal.dll"] {
            try tmp.write("dxmt/lib/wine/x86_64-windows/\(module)", "DXMT")
        }
        try tmp.makeDir("dxmt/lib/wine/x86_64-unix")
        try tmp.write("dxmt/lib/wine/x86_64-unix/winemetal.so", "WM")
        return lib
    }

    /// A GPTK module dir (PE dlls + relative-symlink `.so`s + lib/external), as `overlayGPTK` expects.
    private func makeGPTK(_ tmp: TempDir) throws -> URL {
        let win = try tmp.makeDir("gptk/lib/wine/x86_64-windows")
        let unix = try tmp.makeDir("gptk/lib/wine/x86_64-unix")
        try tmp.makeDir("gptk/lib/external/D3DMetal.framework")
        for module in ["d3d11.dll", "dxgi.dll"] {
            try tmp.write("gptk/lib/wine/x86_64-windows/\(module)", "GPTK:\(module)")
            let so = unix.appendingPathComponent((module as NSString).deletingPathExtension + ".so")
            try FileManager.default.createSymbolicLink(
                atPath: so.path, withDestinationPath: "../../external/libd3dshared.dylib")
        }
        try tmp.write("gptk/lib/external/libd3dshared.dylib", "DYLIB")
        try tmp.write("gptk/lib/external/D3DMetal.framework/D3DMetal", "FRAMEWORK")
        return win
    }

    /// A GPTK that, like the real one, also replaces Wine's d3d12/d3d10 and adds modules Wine doesn't ship.
    private func makeFullGPTK(_ tmp: TempDir) throws -> URL {
        let win = try makeGPTK(tmp)
        let unix = tmp.url.appendingPathComponent("gptk/lib/wine/x86_64-unix")
        for module in ["d3d12.dll", "d3d10.dll", "nvapi64.dll"] {
            try tmp.write("gptk/lib/wine/x86_64-windows/\(module)", "GPTK:\(module)")
            try FileManager.default.createSymbolicLink(
                atPath: unix.appendingPathComponent((module as NSString).deletingPathExtension + ".so").path,
                withDestinationPath: "../../external/libd3dshared.dylib")
        }
        return win
    }

    /// Wine's own PE-only Direct3D modules, as a clean runtime has them (no `.so`).
    private func addWineD3D(_ tmp: TempDir) throws {
        for module in ["d3d12.dll", "d3d10.dll", "d3d11.dll", "dxgi.dll"] {
            try tmp.write("wine/lib/wine/x86_64-windows/\(module)", "WINE:\(module)")
        }
    }

    private func read(_ tmp: TempDir, _ path: String) throws -> String {
        try String(contentsOf: tmp.url.appendingPathComponent(path), encoding: .utf8)
    }

    @Test("A DXMT clone made AFTER the base got GPTK carries Wine's own d3d12/d3d10, not D3DMetal's")
    func dxmtCloneAfterGPTKGetsWineModules() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let wine = try makeWine(tmp)
        try addWineD3D(tmp)
        let variants = RuntimeVariants()
        _ = try variants.prepare(backend: .gptk, baseWine: wine, libDir: try makeFullGPTK(tmp))
        #expect(try read(tmp, "wine/lib/wine/x86_64-windows/d3d12.dll") == "GPTK:d3d12.dll")   // base: GPTK

        _ = try variants.prepare(backend: .dxmt, baseWine: wine, libDir: try makeDXMT(tmp))
        let clone = "wine-dxmt/lib/wine"
        #expect(try read(tmp, "\(clone)/x86_64-windows/d3d12.dll") == "WINE:d3d12.dll")   // Wine's again
        #expect(try read(tmp, "\(clone)/x86_64-windows/d3d10.dll") == "WINE:d3d10.dll")
        #expect(try read(tmp, "\(clone)/x86_64-windows/d3d11.dll") == "DXMT")             // DXMT's own
        #expect(try read(tmp, "\(clone)/x86_64-windows/dxgi.dll") == "DXMT")
        let fm = FileManager.default
        #expect(!fm.fileExists(atPath: tmp.url.appendingPathComponent("\(clone)/x86_64-windows/nvapi64.dll").path))
        for so in ["d3d12.so", "d3d10.so", "nvapi64.so", "d3d11.so", "dxgi.so"] {   // no D3DMetal bridge left
            #expect((try? fm.destinationOfSymbolicLink(
                atPath: tmp.url.appendingPathComponent("\(clone)/x86_64-unix/\(so)").path)) == nil)
        }
        #expect(try read(tmp, "wine/lib/wine/x86_64-windows/d3d12.dll") == "GPTK:d3d12.dll")   // base untouched

        // Idempotent: a second launch changes nothing.
        _ = try variants.prepare(backend: .dxmt, baseWine: wine, libDir: try makeDXMT(tmp))
        #expect(try read(tmp, "\(clone)/x86_64-windows/d3d12.dll") == "WINE:d3d12.dll")
        #expect(try read(tmp, "\(clone)/x86_64-windows/d3d11.dll") == "DXMT")
    }

    @Test("Wine's originals are kept once, from the clean runtime — never from one GPTK already overlaid")
    func originalsOnlyFromCleanRuntime() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let wine = try makeWine(tmp)
        try addWineD3D(tmp)
        let linker = GraphicsLinker()
        try linker.overlayGPTK(wineBinary: wine, gptkLibDir: try makeFullGPTK(tmp))
        let kept = "wine/lib/wine/\(GraphicsLinker.wineOriginalsDirName)"
        #expect(try read(tmp, "\(kept)/x86_64-windows/d3d12.dll") == "WINE:d3d12.dll")
        #expect(try read(tmp, "\(kept)/touched.txt").contains("nvapi64.dll"))

        // A GPTK update overlays again: the originals stay Wine's, not the previous GPTK's.
        try tmp.write("gptk/lib/wine/x86_64-windows/d3d11.dll", "GPTK2")
        try linker.overlayGPTK(wineBinary: wine, gptkLibDir: tmp.url.appendingPathComponent("gptk/lib/wine/x86_64-windows"))
        #expect(try read(tmp, "\(kept)/x86_64-windows/d3d12.dll") == "WINE:d3d12.dll")

        // A runtime overlaid BEFORE originals were kept (D3DMetal bridges already there): nothing is saved.
        try FileManager.default.removeItem(at: tmp.url.appendingPathComponent(kept))
        try tmp.write("gptk/lib/wine/x86_64-windows/d3d11.dll", "GPTK3")
        try linker.overlayGPTK(wineBinary: wine, gptkLibDir: tmp.url.appendingPathComponent("gptk/lib/wine/x86_64-windows"))
        #expect(!FileManager.default.fileExists(atPath: tmp.url.appendingPathComponent(kept).path))
    }

    @Test("prepare(.gptk) overlays the BASE runtime in place and returns the base wine (no clone)")
    func prepareGPTK() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let wine = try makeWine(tmp)
        let gptkLib = try makeGPTK(tmp)
        let out = try RuntimeVariants().prepare(backend: .gptk, baseWine: wine, libDir: gptkLib)
        #expect(out == wine)                                     // the proven in-place path
        #expect(FileManager.default.fileExists(
            atPath: tmp.url.appendingPathComponent("wine/lib/wine/x86_64-windows/d3d11.dll").path))
        #expect(!FileManager.default.fileExists(
            atPath: tmp.url.appendingPathComponent("wine-dxmt").path))   // nothing cloned
    }

    @Test("prepare(.dxmt) clones the base to <root>-dxmt and overlays DXMT into the CLONE only")
    func prepareDXMT() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let wine = try makeWine(tmp)
        let dxmtLib = try makeDXMT(tmp)
        let out = try RuntimeVariants().prepare(backend: .dxmt, baseWine: wine, libDir: dxmtLib)
        #expect(out.path.hasSuffix("wine-dxmt/bin/wine64"))
        // A full clone (the marker rode along); the overlay landed in the clone, never the base.
        #expect(FileManager.default.fileExists(
            atPath: tmp.url.appendingPathComponent("wine-dxmt/share/marker.txt").path))
        #expect(FileManager.default.fileExists(
            atPath: tmp.url.appendingPathComponent("wine-dxmt/lib/wine/x86_64-windows/winemetal.dll").path))
        #expect(!FileManager.default.fileExists(
            atPath: tmp.url.appendingPathComponent("wine/lib/wine/x86_64-windows/winemetal.dll").path))
    }

    @Test("prepare(.dxmt) keeps an EXISTING clone (idempotent — no wipe on every launch)")
    func prepareDXMTIdempotent() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let wine = try makeWine(tmp)
        let dxmtLib = try makeDXMT(tmp)
        let variants = RuntimeVariants()
        _ = try variants.prepare(backend: .dxmt, baseWine: wine, libDir: dxmtLib)
        // Mutate a file INSIDE the clone — a re-clone would wipe this.
        let marker = tmp.url.appendingPathComponent("wine-dxmt/share/marker.txt")
        try Data("MUTATED".utf8).write(to: marker)
        _ = try variants.prepare(backend: .dxmt, baseWine: wine, libDir: dxmtLib)
        #expect(try String(contentsOf: marker, encoding: .utf8) == "MUTATED")   // clone NOT re-created
    }

    @Test("cloneName + isVariantClone are the ONE naming source — and never flag a real DXMT release tag")
    func cloneNaming() {
        #expect(RuntimeVariants.cloneName(ofBase: "wine-cx-26.2.0", backend: .dxmt) == "wine-cx-26.2.0-dxmt")
        // A clone name round-trips as a clone…
        #expect(RuntimeVariants.isVariantClone(RuntimeVariants.cloneName(ofBase: "wine-cx-26.2.0", backend: .dxmt)))
        // …a base wine build and a REAL DXMT release tag do not (the latter must stay listable in the DXMT pane).
        #expect(!RuntimeVariants.isVariantClone("wine-cx-26.2.0"))
        #expect(!RuntimeVariants.isVariantClone("dxmt-v0.72-cx26.2.0"))
    }
}
