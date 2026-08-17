import Foundation
import Testing
@testable import SiloKit

@Suite("GraphicsLinker")
struct GraphicsLinkerTests {
    let linker = GraphicsLinker()

    // MARK: - Fixtures

    /// Build a minimal GPTK runtime tree and return its `lib/wine/x86_64-windows` dir (the `gptkLibDir`).
    /// Each module gets a PE `.dll` + a relative-symlink `.so` (GPTK's real layout); `lib/external` holds
    /// `libd3dshared.dylib` + a `D3DMetal.framework` directory.
    @discardableResult
    private func makeGPTK(_ tmp: TempDir, modules: [String] = ["d3d11.dll", "d3d10.dll", "nvapi64.dll"]) throws -> URL {
        let win = try tmp.makeDir("gptk/lib/wine/x86_64-windows")
        let unix = try tmp.makeDir("gptk/lib/wine/x86_64-unix")
        try tmp.makeDir("gptk/lib/external/D3DMetal.framework")
        for module in modules {
            try tmp.write("gptk/lib/wine/x86_64-windows/\(module)", "PE:\(module)")
            let so = unix.appendingPathComponent((module as NSString).deletingPathExtension + ".so")
            try FileManager.default.createSymbolicLink(
                atPath: so.path, withDestinationPath: "../../external/libd3dshared.dylib")
        }
        try tmp.write("gptk/lib/external/libd3dshared.dylib", "DYLIB")
        try tmp.write("gptk/lib/external/D3DMetal.framework/D3DMetal", "FRAMEWORK")
        return win
    }

    /// Build a minimal wine runtime tree (empty d3d dirs) and return its wine binary (`bin/wine64`).
    private func makeWine(_ tmp: TempDir) throws -> URL {
        try tmp.makeDir("wine/lib/wine/x86_64-windows")
        try tmp.makeDir("wine/lib/wine/x86_64-unix")
        return try tmp.write("wine/bin/wine64", "#!/bin/sh")
    }

    // MARK: - GPTK overlay

    @Test("overlayGPTK copies GPTK's d3d modules into the wine runtime's lib/wine + lib/external")
    func overlayCopiesModules() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let gptkLibDir = try makeGPTK(tmp)
        let wine = try makeWine(tmp)
        let wineLib = wine.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("lib")

        try linker.overlayGPTK(wineBinary: wine, gptkLibDir: gptkLibDir)

        // PE dll overlaid byte-for-byte.
        let d3d11 = wineLib.appendingPathComponent("wine/x86_64-windows/d3d11.dll")
        #expect(FileManager.default.contentsEqual(
            atPath: d3d11.path, andPath: gptkLibDir.appendingPathComponent("d3d11.dll").path))
        // Unix .so recreated AS a relative symlink (not dereferenced into a dylib copy).
        let so = wineLib.appendingPathComponent("wine/x86_64-unix/d3d11.so")
        #expect((try so.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: so.path)
            == "../../external/libd3dshared.dylib")
        // The Metal backend (lib/external) is overlaid so those symlinks + DYLD resolve.
        #expect(FileManager.default.fileExists(atPath: wineLib.appendingPathComponent("external/libd3dshared.dylib").path))
        #expect(FileManager.default.fileExists(atPath: wineLib.appendingPathComponent("external/D3DMetal.framework/D3DMetal").path))
    }

    @Test("overlayGPTK also overlays a CrossOver-derived runtime's lib64/apple_gptk tree")
    func overlayReachesAppleGPTKTree() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let gptkLibDir = try makeGPTK(tmp, modules: ["d3d11.dll", "nvngx-on-metalfx.dll"])
        let wine = try makeWine(tmp)
        let root = wine.deletingLastPathComponent().deletingLastPathComponent()

        // What a CrossOver import leaves: a second GPTK tree, with ITS OWN older modules.
        let apple = root.appendingPathComponent("lib64/apple_gptk")
        let appleWin = apple.appendingPathComponent("wine/x86_64-windows")
        try FileManager.default.createDirectory(at: appleWin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: apple.appendingPathComponent("external"), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: appleWin.appendingPathComponent("d3d11.dll").path,
                                       contents: Data("OLD-CROSSOVER".utf8))

        try linker.overlayGPTK(wineBinary: wine, gptkLibDir: gptkLibDir)

        // The tree CrossOver's wine actually loads now carries the chosen GPTK.
        #expect(FileManager.default.contentsEqual(
            atPath: appleWin.appendingPathComponent("d3d11.dll").path,
            andPath: gptkLibDir.appendingPathComponent("d3d11.dll").path))
        // The NGX shim is activated here too — under its plain name, or nothing answers as NVIDIA.
        #expect(FileManager.default.fileExists(atPath: appleWin.appendingPathComponent("nvngx.dll").path))
        // Relative symlink, same depth as in lib/, so it resolves against apple_gptk/external.
        let so = apple.appendingPathComponent("wine/x86_64-unix/nvngx.so")
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: so.path)
            == "../../external/libd3dshared.dylib")
        // And the Metal backend those symlinks point at.
        #expect(FileManager.default.fileExists(
            atPath: apple.appendingPathComponent("external/libd3dshared.dylib").path))
    }

    @Test("the apple_gptk overlay is repaired even when lib/ is already up to date")
    func appleGPTKTreeRepairedDespiteCurrentLib() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let gptkLibDir = try makeGPTK(tmp)
        let wine = try makeWine(tmp)
        let root = wine.deletingLastPathComponent().deletingLastPathComponent()

        // First pass with no apple_gptk tree: only lib/ is overlaid.
        try linker.overlayGPTK(wineBinary: wine, gptkLibDir: gptkLibDir)

        // The tree appears afterwards (a re-imported CrossOver runtime, or a Silo that didn't write here).
        // lib/ now matches the witness, so without running before the early-return this would stay stale.
        let appleWin = root.appendingPathComponent("lib64/apple_gptk/wine/x86_64-windows")
        try FileManager.default.createDirectory(at: appleWin, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: appleWin.appendingPathComponent("d3d11.dll").path,
                                       contents: Data("STALE".utf8))

        try linker.overlayGPTK(wineBinary: wine, gptkLibDir: gptkLibDir)
        #expect(FileManager.default.contentsEqual(
            atPath: appleWin.appendingPathComponent("d3d11.dll").path,
            andPath: gptkLibDir.appendingPathComponent("d3d11.dll").path))
    }

    @Test("a runtime with no lib64/apple_gptk is left alone")
    func noAppleGPTKTreeIsANoOp() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let gptkLibDir = try makeGPTK(tmp)
        let wine = try makeWine(tmp)
        let root = wine.deletingLastPathComponent().deletingLastPathComponent()

        try linker.overlayGPTK(wineBinary: wine, gptkLibDir: gptkLibDir)
        // A built-from-source runtime has one tree; the overlay must not invent a second.
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("lib64").path))
    }

    @Test("overlayGPTK is idempotent — a second call is a no-op and does not throw")
    func overlayIdempotent() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let gptkLibDir = try makeGPTK(tmp)
        let wine = try makeWine(tmp)

        try linker.overlayGPTK(wineBinary: wine, gptkLibDir: gptkLibDir)
        try linker.overlayGPTK(wineBinary: wine, gptkLibDir: gptkLibDir)   // no throw, still correct

        let d3d11 = wine.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("lib/wine/x86_64-windows/d3d11.dll")
        #expect(FileManager.default.contentsEqual(
            atPath: d3d11.path, andPath: gptkLibDir.appendingPathComponent("d3d11.dll").path))
    }

    @Test("overlayGPTK re-applies when GPTK's modules change (e.g. a GPTK update)")
    func overlayReappliesOnUpdate() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let gptkLibDir = try makeGPTK(tmp)
        let wine = try makeWine(tmp)
        try linker.overlayGPTK(wineBinary: wine, gptkLibDir: gptkLibDir)

        // A GPTK update rewrites d3d11.dll; the overlay must pick up the new bytes.
        try tmp.write("gptk/lib/wine/x86_64-windows/d3d11.dll", "PE:d3d11.dll v2")
        try linker.overlayGPTK(wineBinary: wine, gptkLibDir: gptkLibDir)

        let d3d11 = wine.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("lib/wine/x86_64-windows/d3d11.dll")
        #expect(try String(contentsOf: d3d11, encoding: .utf8) == "PE:d3d11.dll v2")
    }

    @Test("overlayGPTK only touches d3d/dxgi/nv modules — unrelated wine dlls are left intact")
    func overlayScopedToGPTKModules() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let gptkLibDir = try makeGPTK(tmp, modules: ["d3d11.dll"])
        // A stray non-graphics dll in GPTK's source must NOT clobber the wine runtime's own copy.
        try tmp.write("gptk/lib/wine/x86_64-windows/kernel32.dll", "GPTK-STRAY")
        let wine = try makeWine(tmp)
        try tmp.write("wine/lib/wine/x86_64-windows/kernel32.dll", "WINE-REAL")

        try linker.overlayGPTK(wineBinary: wine, gptkLibDir: gptkLibDir)

        let kernel32 = wine.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("lib/wine/x86_64-windows/kernel32.dll")
        #expect(try String(contentsOf: kernel32, encoding: .utf8) == "WINE-REAL")   // untouched
    }

    @Test("overlayGPTK selects a fallback witness when d3d11.dll is absent and re-applies on update")
    func overlayFallbackWitness() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        // SINGLE non-d3d11 module → witness is unambiguously modules[0] (no d3d11.dll present).
        let gptkLibDir = try makeGPTK(tmp, modules: ["d3d12.dll"])
        let wine = try makeWine(tmp)
        let wineWin = wine.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("lib/wine/x86_64-windows/d3d12.dll")

        // 1. First overlay completes the copy via the fallback witness (not a short-circuit).
        try linker.overlayGPTK(wineBinary: wine, gptkLibDir: gptkLibDir)
        #expect(FileManager.default.contentsEqual(
            atPath: wineWin.path, andPath: gptkLibDir.appendingPathComponent("d3d12.dll").path))

        // 2. A GPTK update rewrites d3d12.dll; the fallback-keyed idempotency check must DETECT it + re-apply.
        try tmp.write("gptk/lib/wine/x86_64-windows/d3d12.dll", "PE:d3d12.dll v2")
        try linker.overlayGPTK(wineBinary: wine, gptkLibDir: gptkLibDir)
        #expect(try String(contentsOf: wineWin, encoding: .utf8) == "PE:d3d12.dll v2")

        // 3. No-op when unchanged: the witness short-circuit fires; bytes + mtime are untouched.
        let mtime = try FileManager.default.attributesOfItem(atPath: wineWin.path)[.modificationDate] as? Date
        try linker.overlayGPTK(wineBinary: wine, gptkLibDir: gptkLibDir)
        #expect(try String(contentsOf: wineWin, encoding: .utf8) == "PE:d3d12.dll v2")
        let mtime2 = try FileManager.default.attributesOfItem(atPath: wineWin.path)[.modificationDate] as? Date
        #expect(mtime == mtime2)   // not re-copied (guards the re-copy-every-launch failure mode)
    }

    @Test("overlayGPTK links D3DMetal.framework into the unix-modules dir (so libd3dshared's @rpath resolves it)")
    func overlayLinksD3DMetalFramework() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let gptkLibDir = try makeGPTK(tmp)
        let wine = try makeWine(tmp)

        try linker.overlayGPTK(wineBinary: wine, gptkLibDir: gptkLibDir)

        // wine loads the d3d `.so` from x86_64-unix, so libd3dshared's @loader_path resolves there — the
        // framework must be reachable from that dir or the D3DMetal dlopen fails → silent wined3d fallback.
        let link = wine.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("lib/wine/x86_64-unix/D3DMetal.framework")
        #expect((try link.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path)
            == "../../external/D3DMetal.framework")
    }

    @Test("overlayGPTK self-repairs a runtime missing the D3DMetal.framework unix link (the pre-fix regression)")
    func overlaySelfRepairsMissingFrameworkLink() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let gptkLibDir = try makeGPTK(tmp)
        let wine = try makeWine(tmp)
        try linker.overlayGPTK(wineBinary: wine, gptkLibDir: gptkLibDir)

        // Simulate the broken state: modules already overlaid (witness byte-identical) but the framework
        // link deleted — exactly the runtime that silently fell back to wined3d before this fix.
        let link = wine.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("lib/wine/x86_64-unix/D3DMetal.framework")
        try FileManager.default.removeItem(at: link)
        #expect(!FileManager.default.fileExists(atPath: link.path))

        // The next overlay must re-create the link even though the witness short-circuits the module copy.
        try linker.overlayGPTK(wineBinary: wine, gptkLibDir: gptkLibDir)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path)
            == "../../external/D3DMetal.framework")
    }

    @Test("overlayGPTK throws sourceMissing when GPTK's module dir does not exist")
    func overlaySourceMissing() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let wine = try makeWine(tmp)
        let missing = tmp.url.appendingPathComponent("nope/lib/wine/x86_64-windows")
        #expect(throws: GraphicsLinker.LinkError.sourceMissing(missing)) {
            try linker.overlayGPTK(wineBinary: wine, gptkLibDir: missing)
        }
    }

    // MARK: - DXMT overlay

    /// Build a minimal DXMT runtime tree and return its `lib/wine/x86_64-windows` dir (the `dxmtLibDir`).
    /// DXMT's real layout: PE `d3d11`/`d3d10core`/`dxgi`/`winemetal` dlls, and ONE unix `.so` —
    /// `winemetal.so` (a real dylib, not a symlink) — the d3d PEs forward to winemetal and have no `.so`.
    @discardableResult
    private func makeDXMT(_ tmp: TempDir) throws -> URL {
        let win = try tmp.makeDir("dxmt/lib/wine/x86_64-windows")
        try tmp.makeDir("dxmt/lib/wine/x86_64-unix")
        for module in ["d3d11.dll", "d3d10core.dll", "dxgi.dll", "winemetal.dll"] {
            try tmp.write("dxmt/lib/wine/x86_64-windows/\(module)", "PE:\(module)")
        }
        try tmp.write("dxmt/lib/wine/x86_64-unix/winemetal.so", "WINEMETAL-DYLIB")
        return win
    }

    @Test("overlayDXMT copies DXMT's d3d/winemetal PE modules + winemetal.so into the wine runtime")
    func overlayDXMTCopiesModules() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let dxmtLibDir = try makeDXMT(tmp)
        let wine = try makeWine(tmp)
        let wineLib = wine.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("lib")

        try linker.overlayDXMT(wineBinary: wine, dxmtLibDir: dxmtLibDir)

        for dll in ["d3d11.dll", "d3d10core.dll", "dxgi.dll", "winemetal.dll"] {
            let dest = wineLib.appendingPathComponent("wine/x86_64-windows/\(dll)")
            #expect(FileManager.default.contentsEqual(
                atPath: dest.path, andPath: dxmtLibDir.appendingPathComponent(dll).path))
        }
        // The Metal bridge .so is overlaid as a real file (DXMT's winemetal.so isn't a symlink).
        let so = wineLib.appendingPathComponent("wine/x86_64-unix/winemetal.so")
        #expect(try String(contentsOf: so, encoding: .utf8) == "WINEMETAL-DYLIB")
    }

    @Test("overlayDXMT overlays ONLY winemetal.so (the d3d PEs are pure forwarders) and touches no lib/external")
    func overlayDXMTNoStrayUnixOrExternal() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let dxmtLibDir = try makeDXMT(tmp)
        let wine = try makeWine(tmp)
        let wineLib = wine.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("lib")

        try linker.overlayDXMT(wineBinary: wine, dxmtLibDir: dxmtLibDir)

        // No d3d11.so / dxgi.so etc. (DXMT's d3d modules have no unix half), and no lib/external at all.
        #expect(!FileManager.default.fileExists(atPath: wineLib.appendingPathComponent("wine/x86_64-unix/d3d11.so").path))
        #expect(!FileManager.default.fileExists(atPath: wineLib.appendingPathComponent("wine/x86_64-unix/dxgi.so").path))
        #expect(!FileManager.default.fileExists(atPath: wineLib.appendingPathComponent("external").path))
    }

    @Test("overlayDXMT is idempotent and re-applies on a DXMT update")
    func overlayDXMTIdempotentAndReapplies() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let dxmtLibDir = try makeDXMT(tmp)
        let wine = try makeWine(tmp)
        let d3d11 = wine.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("lib/wine/x86_64-windows/d3d11.dll")

        try linker.overlayDXMT(wineBinary: wine, dxmtLibDir: dxmtLibDir)
        try linker.overlayDXMT(wineBinary: wine, dxmtLibDir: dxmtLibDir)   // no throw, still correct
        #expect(try String(contentsOf: d3d11, encoding: .utf8) == "PE:d3d11.dll")

        try tmp.write("dxmt/lib/wine/x86_64-windows/d3d11.dll", "PE:d3d11.dll v2")  // DXMT update
        try linker.overlayDXMT(wineBinary: wine, dxmtLibDir: dxmtLibDir)
        #expect(try String(contentsOf: d3d11, encoding: .utf8) == "PE:d3d11.dll v2")
    }

    @Test("overlayDXMT throws sourceMissing when DXMT's module dir does not exist")
    func overlayDXMTSourceMissing() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let wine = try makeWine(tmp)
        let missing = tmp.url.appendingPathComponent("nope/lib/wine/x86_64-windows")
        #expect(throws: GraphicsLinker.LinkError.sourceMissing(missing)) {
            try linker.overlayDXMT(wineBinary: wine, dxmtLibDir: missing)
        }
    }

    @Test("overlayDXMT ALSO overlays the i386 tree when the release ships 32-bit libs (so 32-bit games get DXMT)")
    func overlayDXMTBothArches() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let dxmtLibDir = try makeDXMT(tmp)
        // A both-ABI release: an i386-windows sibling with 32-bit d3d PEs. (No i386-unix — the i386
        // winemetal.dll thunks into the shared x86_64-unix/winemetal.so, so the 32-bit tree ships no .so.)
        try tmp.makeDir("dxmt/lib/wine/i386-windows")
        for module in ["d3d11.dll", "d3d10core.dll", "dxgi.dll", "winemetal.dll"] {
            try tmp.write("dxmt/lib/wine/i386-windows/\(module)", "PE32:\(module)")
        }
        let wine = try makeWine(tmp)
        let wineLib = wine.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("lib")

        try linker.overlayDXMT(wineBinary: wine, dxmtLibDir: dxmtLibDir)

        // 64-bit tree overlaid as before…
        #expect(try String(contentsOf:
            wineLib.appendingPathComponent("wine/x86_64-windows/d3d11.dll"), encoding: .utf8) == "PE:d3d11.dll")
        // …AND the 32-bit tree, so a 32-bit game loads DXMT's i386 d3d11 (not stock wined3d).
        for dll in ["d3d11.dll", "d3d10core.dll", "dxgi.dll", "winemetal.dll"] {
            #expect(try String(contentsOf:
                wineLib.appendingPathComponent("wine/i386-windows/\(dll)"), encoding: .utf8) == "PE32:\(dll)")
        }
        // The shared unix bridge stays in x86_64-unix; no i386-unix is fabricated.
        #expect(FileManager.default.fileExists(atPath: wineLib.appendingPathComponent("wine/x86_64-unix/winemetal.so").path))
        #expect(!FileManager.default.fileExists(atPath: wineLib.appendingPathComponent("wine/i386-unix").path))
    }

    @Test("overlayDXMT leaves the i386 tree untouched for a 64-bit-only release (backward compatible)")
    func overlayDXMT64BitOnlyRelease() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let dxmtLibDir = try makeDXMT(tmp)   // x86_64 only, no i386-windows sibling
        let wine = try makeWine(tmp)
        let wineLib = wine.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("lib")

        try linker.overlayDXMT(wineBinary: wine, dxmtLibDir: dxmtLibDir)

        #expect(try String(contentsOf:
            wineLib.appendingPathComponent("wine/x86_64-windows/d3d11.dll"), encoding: .utf8) == "PE:d3d11.dll")
        #expect(!FileManager.default.fileExists(atPath: wineLib.appendingPathComponent("wine/i386-windows").path))
    }

    @Test("installGPTKPrefixLoaders seeds the NVIDIA shims into system32, nvngx under its plain name")
    func gptkPrefixLoaders() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let gptkLib = tmp.url.appendingPathComponent("GPTK/lib/wine/x86_64-windows")
        try FileManager.default.createDirectory(at: gptkLib, withIntermediateDirectories: true)
        FileManager.default.createFile(
            atPath: gptkLib.appendingPathComponent("nvapi64.dll").path, contents: Data("NVAPI".utf8))
        // GPTK ships the NGX shim under a suffixed, inert name — the prefix needs the plain one.
        FileManager.default.createFile(
            atPath: gptkLib.appendingPathComponent("nvngx-on-metalfx.dll").path, contents: Data("NGX".utf8))

        let prefix = tmp.url.appendingPathComponent("Bottle")
        try linker.installGPTKPrefixLoaders(prefix: prefix, gptkLibDir: gptkLib)

        let system32 = prefix.appendingPathComponent("drive_c/windows/system32")
        #expect(try String(contentsOf: system32.appendingPathComponent("nvapi64.dll"),
                           encoding: .utf8) == "NVAPI")
        #expect(try String(contentsOf: system32.appendingPathComponent("nvngx.dll"),
                           encoding: .utf8) == "NGX")
        // The suffixed name is NOT what wine looks up, so it has no business in the prefix.
        #expect(!FileManager.default.fileExists(
            atPath: system32.appendingPathComponent("nvngx-on-metalfx.dll").path))
        // 64-bit only: Apple ships no i386 D3DMetal, so there's no syswow64 twin to seed.
        #expect(!FileManager.default.fileExists(
            atPath: prefix.appendingPathComponent("drive_c/windows/syswow64/nvngx.dll").path))
    }

    @Test("installGPTKPrefixLoaders is idempotent, and skips a module this GPTK doesn't ship")
    func gptkPrefixLoadersTolerateMissing() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let gptkLib = tmp.url.appendingPathComponent("GPTK/lib/wine/x86_64-windows")
        try FileManager.default.createDirectory(at: gptkLib, withIntermediateDirectories: true)
        // Only nvapi64 — an older GPTK with no MetalFX shim at all.
        FileManager.default.createFile(
            atPath: gptkLib.appendingPathComponent("nvapi64.dll").path, contents: Data("NVAPI".utf8))

        let prefix = tmp.url.appendingPathComponent("Bottle")
        try linker.installGPTKPrefixLoaders(prefix: prefix, gptkLibDir: gptkLib)
        try linker.installGPTKPrefixLoaders(prefix: prefix, gptkLibDir: gptkLib)   // second run: no-op

        let system32 = prefix.appendingPathComponent("drive_c/windows/system32")
        #expect(FileManager.default.fileExists(atPath: system32.appendingPathComponent("nvapi64.dll").path))
        #expect(!FileManager.default.fileExists(atPath: system32.appendingPathComponent("nvngx.dll").path))
    }

    @Test("installDXMTPrefixLoaders seeds winemetal.dll into the prefix per ABI (x86_64→system32, i386→syswow64)")
    func installDXMTPrefixLoaders() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let dxmtLibDir = try makeDXMT(tmp)   // x86_64-windows/winemetal.dll = "PE:winemetal.dll"
        try tmp.makeDir("dxmt/lib/wine/i386-windows")
        try tmp.write("dxmt/lib/wine/i386-windows/winemetal.dll", "PE32:winemetal.dll")
        let prefix = try tmp.makeDir("bottle")
        let fm = FileManager.default

        try linker.installDXMTPrefixLoaders(prefix: prefix, dxmtLibDir: dxmtLibDir)

        // Without this, wine can't resolve winemetal.dll (no wineboot fakedll) → c0000135 → wined3d fallback.
        let sys32 = prefix.appendingPathComponent("drive_c/windows/system32/winemetal.dll")
        let syswow64 = prefix.appendingPathComponent("drive_c/windows/syswow64/winemetal.dll")
        #expect(try String(contentsOf: sys32, encoding: .utf8) == "PE:winemetal.dll")        // 64-bit
        #expect(try String(contentsOf: syswow64, encoding: .utf8) == "PE32:winemetal.dll")   // 32-bit
        // Idempotent — a second call doesn't throw.
        try linker.installDXMTPrefixLoaders(prefix: prefix, dxmtLibDir: dxmtLibDir)
        #expect(fm.fileExists(atPath: sys32.path))
    }

    @Test("installDXMTPrefixLoaders places ONLY system32 winemetal for a 64-bit-only release")
    func installDXMTPrefixLoaders64Only() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let dxmtLibDir = try makeDXMT(tmp)   // no i386-windows sibling
        let prefix = try tmp.makeDir("bottle")

        try linker.installDXMTPrefixLoaders(prefix: prefix, dxmtLibDir: dxmtLibDir)

        #expect(FileManager.default.fileExists(atPath:
            prefix.appendingPathComponent("drive_c/windows/system32/winemetal.dll").path))
        #expect(!FileManager.default.fileExists(atPath:
            prefix.appendingPathComponent("drive_c/windows/syswow64/winemetal.dll").path))
    }

    @Test("isOverlayModule: only .dll/.so with a backend's module prefixes; the two filters diverge right")
    func overlayModulePredicate() {
        #expect(GraphicsLinker.isOverlayModule("d3d11.dll", prefixes: ["d3d"]))
        #expect(GraphicsLinker.isOverlayModule("D3D11.DLL", prefixes: ["d3d"]))       // case-insensitive
        #expect(!GraphicsLinker.isOverlayModule("d3d11.txt", prefixes: ["d3d"]))      // wrong extension
        #expect(!GraphicsLinker.isOverlayModule("kernel32.dll", prefixes: ["d3d", "dxgi"]))   // guard
        // The backend filters parameterize the shared predicate — their DIFFERENCES must survive:
        #expect(GraphicsLinker.isGPTKModule("nvngx.dll") && !GraphicsLinker.isDXMTModule("nvngx.dll"))
        #expect(GraphicsLinker.isDXMTModule("winemetal.so") && !GraphicsLinker.isGPTKModule("winemetal.so"))
    }

    @Test("witnessMatches: skip only when the witness is byte-identical in the runtime")
    func witnessCheck() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        _ = try tmp.makeDir("src"); let win = try tmp.makeDir("win")
        try tmp.write("src/d3d11.dll", "V1")
        try tmp.write("src/dxgi.dll", "V1")
        let modules = [tmp.url.appendingPathComponent("src/d3d11.dll"),
                       tmp.url.appendingPathComponent("src/dxgi.dll")]
        #expect(!linker.witnessMatches(modules, in: win))    // nothing overlaid yet
        try tmp.write("win/d3d11.dll", "V1")
        #expect(linker.witnessMatches(modules, in: win))     // this build already overlaid → skip
        try tmp.write("win/d3d11.dll", "V2")
        #expect(!linker.witnessMatches(modules, in: win))    // an updated build re-applies
        #expect(!linker.witnessMatches([], in: win))         // no modules → never "already overlaid"
    }

    @Test("witnessMatches does NOT skip when d3d11.dll coincidentally matches (e.g. CrossOver's own native bundle) but the nvngx-on-metalfx rename was never actually performed on this runtime")
    func witnessCheckRequiresNVNGXRename() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        _ = try tmp.makeDir("src"); let win = try tmp.makeDir("win")
        try tmp.write("src/d3d11.dll", "SAME")
        try tmp.write("src/nvngx-on-metalfx.dll", "shim")
        let modules = [tmp.url.appendingPathComponent("src/d3d11.dll"),
                       tmp.url.appendingPathComponent("src/nvngx-on-metalfx.dll")]
        // d3d11.dll already matches (e.g. CrossOver's own native GPTK bundle happens to be byte-identical
        // to the imported GPTK's own copy) — but the plain nvngx.dll rename was never actually created
        // here, so the overlay must NOT be considered "already done".
        try tmp.write("win/d3d11.dll", "SAME")
        #expect(!linker.witnessMatches(modules, in: win))
        // Once the rename has genuinely happened, it correctly counts as already overlaid.
        try tmp.write("win/nvngx.dll", "shim")
        #expect(linker.witnessMatches(modules, in: win))
    }
}
