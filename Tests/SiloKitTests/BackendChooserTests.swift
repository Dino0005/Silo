import Foundation
import Testing
@testable import SiloKit

@Suite("BackendChooser + PE imports")
struct BackendChooserTests {

    private func writePE(_ tmp: TempDir, _ name: String, magic: UInt16, machine: UInt16, imports: [String]) throws -> URL {
        try PEFixture.write(PEFixture.withImports(magic: magic, machine: machine, imports: imports), into: tmp, name)
    }

    // MARK: - PE import reader

    @Test("importedDLLs reads the import table for PE32+ and PE32, lowercased")
    func importsRead() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let x64 = try writePE(tmp, "a.exe", magic: 0x20b, machine: 0x8664, imports: ["d3d11.dll", "KERNEL32.dll"])
        #expect(WindowsExecutable.importedDLLs(of: x64) == ["d3d11.dll", "kernel32.dll"])
        let x86 = try writePE(tmp, "b.exe", magic: 0x10b, machine: 0x014c, imports: ["D3D9.dll"])
        #expect(WindowsExecutable.importedDLLs(of: x86) == ["d3d9.dll"])
    }

    @Test("importedDLLs fails open on a non-PE / malformed file (empty set)")
    func importsFailOpen() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let junk = tmp.url.appendingPathComponent("junk.bin")
        try Data([0x4D, 0x5A, 0x00, 0x01, 0x02, 0x03]).write(to: junk)     // "MZ" then garbage
        #expect(WindowsExecutable.importedDLLs(of: junk).isEmpty)
        #expect(WindowsExecutable.importedDLLs(of: tmp.url.appendingPathComponent("missing.exe")).isEmpty)
    }

    // MARK: - choose() (pure — bitness in, backend out)

    @Test("explicit choices are honored regardless of bitness — and win over a learned hint")
    func chooseExplicit() {
        #expect(BackendChooser.choose(.gptk, is32Bit: true) == .gptk)
        #expect(BackendChooser.choose(.dxmt, is32Bit: false) == .dxmt)
        // A user's pin always beats a reactively-learned hint (which only applies to `.auto`).
        #expect(BackendChooser.choose(.gptk, is32Bit: false, learned: .dxmt) == .gptk)
    }

    @Test("auto: 64-bit → GPTK, 32-bit → DXMT")
    func chooseAuto() {
        #expect(BackendChooser.choose(.auto, is32Bit: false) == .gptk)
        #expect(BackendChooser.choose(.auto, is32Bit: true) == .dxmt)   // GPTK is 64-bit-only
    }

    @Test("auto: a learned hint is consulted only for a 64-bit launch")
    func chooseLearnedConsulted64BitAutoOnly() {
        #expect(BackendChooser.choose(.auto, is32Bit: false, learned: .dxmt) == .dxmt)  // 64-bit auto uses the hint
        #expect(BackendChooser.choose(.auto, is32Bit: false, learned: nil) == .gptk)    // no hint → GPTK default
        #expect(BackendChooser.choose(.auto, is32Bit: false, learned: .gptk) == .gptk)  // defensive: hint agrees
        #expect(BackendChooser.choose(.auto, is32Bit: true, learned: .dxmt) == .dxmt)   // 32-bit: DXMT regardless
    }

    // MARK: - dxmtMightHelp()

    @Test("dxmtMightHelp: D3D10/11 → yes; D3D12 or D3D9-only → no; unknown → yes (permissive)")
    func mightHelp() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        func pe(_ n: String, _ imports: [String]) throws -> URL {
            try writePE(tmp, n, magic: 0x20b, machine: 0x8664, imports: imports)
        }
        #expect(BackendChooser.dxmtMightHelp(exe: try pe("d11.exe", ["d3d11.dll", "kernel32.dll"])))
        #expect(!BackendChooser.dxmtMightHelp(exe: try pe("d12.exe", ["d3d12.dll", "d3d11.dll"])))   // needs D3D12
        #expect(!BackendChooser.dxmtMightHelp(exe: try pe("d9.exe", ["d3d9.dll"])))                  // D3D9-only
        #expect(BackendChooser.dxmtMightHelp(exe: try pe("d9x.exe", ["d3d9.dll", "d3d10core.dll"]))) // has D3D10
        #expect(BackendChooser.dxmtMightHelp(exe: try pe("none.exe", ["kernel32.dll"])))             // dynamic → try
    }

    @Test("dxmtMightHelp catches a DELAY-loaded d3d12 → DXMT can't help (no wasted reroute)")
    func mightHelpDelayLoadedD3D12() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        // A title that delay-loads d3d12 (common) — the delay directory is the only place the name appears.
        let exe = try PEFixture.write(
            PEFixture.withDelayImports(magic: 0x20b, machine: 0x8664, imports: ["d3d12.dll"]), into: tmp, "dl12.exe")
        #expect(WindowsExecutable.importedDLLs(of: exe) == ["d3d12.dll"])
        #expect(!BackendChooser.dxmtMightHelp(exe: exe))   // needs D3D12 → DXMT is pointless
    }

    // MARK: - Unreal D3D12 detection (for the DXMT mismatch note)

    /// Build `<root>/<Game>/Binaries/Win64/<Game>-Win64-Shipping.exe`, optionally with an Engine tree
    /// beside the game and optionally a D3D12 RHI dll.
    private func makeUnrealLayout(
        _ tmp: TempDir, game: String = "CotW", engine: Bool = true, d3d12DLL: Bool = false
    ) throws -> URL {
        let fm = FileManager.default
        let binaries = tmp.url.appendingPathComponent("\(game)/Binaries/Win64", isDirectory: true)
        try fm.createDirectory(at: binaries, withIntermediateDirectories: true)
        let exe = binaries.appendingPathComponent("\(game)-Win64-Shipping.exe")
        fm.createFile(atPath: exe.path, contents: Data("MZ".utf8))
        if engine {
            let engineBin = tmp.url.appendingPathComponent("Engine/Binaries/Win64", isDirectory: true)
            try fm.createDirectory(at: engineBin, withIntermediateDirectories: true)
            if d3d12DLL {
                fm.createFile(atPath: engineBin.appendingPathComponent("D3D12RHI.dll").path, contents: Data())
            }
        }
        return exe
    }

    @Test("An Unreal game is recognised from EITHER shape — shipping binary or root launcher")
    func unrealLayoutIsRecognised() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        // The import table is what dxmtMightHelp reads, and Unreal's LoadLibrary use leaves it empty — so
        // the note stayed silent on exactly the game that motivated it (Fatal Fury).
        #expect(BackendChooser.isUnrealD3D12(exe: try makeUnrealLayout(tmp)))

        // The launcher shape: `TEKKEN 8.exe` sits at the install root beside Engine/, with no
        // `-Win64-Shipping` anywhere in its name. Matching on the name missed it while catching every
        // other Unreal title in the same library.
        let launcher = tmp.url.appendingPathComponent("TEKKEN 8.exe")
        FileManager.default.createFile(atPath: launcher.path, contents: Data("MZ".utf8))
        #expect(BackendChooser.isUnrealD3D12(exe: launcher))

        // Tekken 8's actual shape: an Engine tree carrying only ThirdParty, with the engine binaries kept
        // under the project folder. Requiring Engine/Binaries/Win64 missed it while matching every other
        // Unreal title in the same library.
        let thirdParty = try TempDir(); defer { thirdParty.cleanup() }
        try thirdParty.makeDir("Engine/Binaries/ThirdParty")
        let tekkenLauncher = thirdParty.url.appendingPathComponent("TEKKEN 8.exe")
        FileManager.default.createFile(atPath: tekkenLauncher.path, contents: Data("MZ".utf8))
        #expect(BackendChooser.isUnrealD3D12(exe: tekkenLauncher))
    }

    @Test("A game with no engine tree above it is not claimed")
    func nonUnrealIsNotClaimed() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        // Nested deep enough that the four-level walk stays INSIDE this TempDir. One level down, the walk
        // climbs out into the shared system temp dir, where a parallel test's tree can be found and the
        // assertion turns on the scheduler. (In a real install the walk stays inside the Steam library.)
        let other = try tmp.makeDir("steamapps/common/SomeGame")
        let plain = other.appendingPathComponent("Game.exe")
        FileManager.default.createFile(atPath: plain.path, contents: Data("MZ".utf8))
        #expect(!BackendChooser.isUnrealD3D12(exe: plain))
    }


    @Test("needsD3D12 answers yes for an Unreal layout, and no for a plain exe with no D3D12 anywhere")
    func needsD3D12CoversBothPaths() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        // The Unreal path: no d3d12 in the import table, recognised by layout instead. This is the case
        // the warning existed for and stayed silent on.
        #expect(BackendChooser.needsD3D12(exe: try makeUnrealLayout(tmp)))
        // A file that isn't a PE at all imports nothing, so dxmtMightHelp treats it as unknown (returns
        // true → "DXMT might help"), and the layout check doesn't claim it either.
        //
        // In its OWN TempDir, and nested: makeUnrealLayout above puts an Engine tree at the root of `tmp`,
        // so a file placed beside it would be found by the upward walk — the test would have contradicted
        // itself. Nesting also keeps the four-level walk from climbing into the shared system temp dir.
        let plainTmp = try TempDir(); defer { plainTmp.cleanup() }
        let plain = try plainTmp.makeDir("steamapps/common/SomeGame")
            .appendingPathComponent("Game.exe")
        FileManager.default.createFile(atPath: plain.path, contents: Data("MZ".utf8))
        #expect(!BackendChooser.needsD3D12(exe: plain))
    }

}
