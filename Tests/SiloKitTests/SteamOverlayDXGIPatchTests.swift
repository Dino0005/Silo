import Foundation
import Testing
@testable import SiloKit

@Suite("SteamOverlayDXGIPatch")
struct SteamOverlayDXGIPatchTests {
    /// A synthetic AMD64 PE shaped like GPTK 4.0 beta 2's `dxgi.dll` where it matters: the targeted
    /// `SizeOfImage` and the original fragment bytes in `.text`. `.text` sits at file offset 0x400 (≠ its
    /// RVA 0x1000), so the RVA → file-offset mapping is exercised. Nothing is taken from Apple's binary.
    static func fakeDXGI(imageSize: UInt32 = SteamOverlayDXGIPatch.imageSize, original: Bool = true) -> Data {
        var d = Data(count: 0x1400)
        func put16(_ v: UInt16, _ at: Int) { withUnsafeBytes(of: v.littleEndian) { d.replaceSubrange(at..<at + 2, with: $0) } }
        func put32(_ v: UInt32, _ at: Int) { withUnsafeBytes(of: v.littleEndian) { d.replaceSubrange(at..<at + 4, with: $0) } }
        d[0] = 0x4d; d[1] = 0x5a
        put32(0x80, 0x3c)
        d.replaceSubrange(0x80..<0x84, with: [0x50, 0x45, 0, 0])
        put16(0x8664, 0x84); put16(1, 0x86); put16(0xf0, 0x94)
        put16(0x20b, 0x98)
        put32(imageSize, 0x98 + 56)
        let section = 0x98 + 0xf0
        d.replaceSubrange(section..<section + 5, with: Array(".text".utf8))
        put32(0x1000, section + 8); put32(0x1000, section + 12)    // VirtualSize, VirtualAddress
        put32(0x1000, section + 16); put32(0x400, section + 20)    // SizeOfRawData, PointerToRawData
        for f in SteamOverlayDXGIPatch.fragments {
            let o = 0x400 + f.rva - 0x1000
            d.replaceSubrange(o..<o + f.original.count, with: original ? f.original : f.patched)
        }
        return d
    }

    @Test("an unpatched copy of the targeted build is patched at the right file offsets, and only there")
    func appliesFragments() throws {
        let original = Self.fakeDXGI()
        #expect(SteamOverlayDXGIPatch.state(of: original) == .unpatched)

        let patched = try #require(SteamOverlayDXGIPatch.apply(to: original))
        #expect(SteamOverlayDXGIPatch.state(of: patched) == .patched)
        #expect(patched == Self.fakeDXGI(original: false))
        #expect(patched.count == original.count)
        // e.g. the first thunk's `jmp [rip+…]` opcode became `mov rax, imm64`.
        #expect(Array(patched[0x7a4..<0x7a6]) == [0x48, 0xb8])
    }

    @Test("an already patched copy is recognised and not patched again")
    func idempotent() {
        let patched = Self.fakeDXGI(original: false)
        #expect(SteamOverlayDXGIPatch.state(of: patched) == .patched)
        #expect(SteamOverlayDXGIPatch.apply(to: patched) == nil)
    }

    @Test("any other dxgi.dll is left alone: other image size, different bytes, not a PE at all")
    func notApplicable() {
        // GPTK 3.0's dxgi.dll is 0x01016000.
        #expect(SteamOverlayDXGIPatch.state(of: Self.fakeDXGI(imageSize: 0x0101_6000)) == .notApplicable)
        #expect(SteamOverlayDXGIPatch.apply(to: Self.fakeDXGI(imageSize: 0x0101_6000)) == nil)

        // Right size, but one fragment reads something else (a rebuilt or future dxgi.dll).
        var other = Self.fakeDXGI()
        other[0x7a4] = 0x90
        #expect(SteamOverlayDXGIPatch.state(of: other) == .notApplicable)
        #expect(SteamOverlayDXGIPatch.apply(to: other) == nil)

        #expect(SteamOverlayDXGIPatch.state(of: Data("PE:dxgi.dll".utf8)) == .notApplicable)
        #expect(SteamOverlayDXGIPatch.state(of: Data()) == .notApplicable)
        // Truncated right after the headers: fragments fall outside the file.
        #expect(SteamOverlayDXGIPatch.state(of: Self.fakeDXGI().prefix(0x500)) == .notApplicable)
    }

    @Test("the fragments are WineForge's: ten of them, each the same length before and after")
    func fragmentTable() {
        #expect(SteamOverlayDXGIPatch.fragments.count == 10)
        #expect(SteamOverlayDXGIPatch.fragments.allSatisfy { $0.original.count == $0.patched.count })
    }
}
