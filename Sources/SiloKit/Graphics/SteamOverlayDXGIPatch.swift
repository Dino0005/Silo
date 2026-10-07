import Foundation

/// Makes GPTK 4.0 beta 2's `dxgi.dll` hookable by the Steam overlay — and with it, Steam Input.
///
/// GPTK 4's `DllMain` fills a jump table in `.data` (`dxgi_jump_table`) with `jmp [rip+2]` thunks, each followed
/// by the address of a D3DMetal function on the unix side. The Steam overlay follows that `jmp` to its final
/// target before hooking: memory no PE module owns and Wine has no view for, so `VirtualProtect` fails ("hook
/// target … covers a non-executable page"). The overlay then never sees `CreateSwapChain`, never attaches, and
/// Steam never activates the game's controller config — Steam Input is dead in every game (measured 2026-10-07
/// in `controller.txt`: no "Queueing activation … app: <game>" under GPTK 4, ~15 s after each start under GPTK 3).
///
/// The fix rewrites the generator so each thunk is `mov rax, imm64; jmp rax` instead — same jump, but one the
/// overlay can't follow, so it hooks the thunk inside `dxgi.dll` itself. `rax` is volatile at a Win64 call
/// boundary, so nothing observable changes. The fragments are WineForge's (Radim Veselý, LGPL-2.1,
/// `dlls/ntdll/pe_patches.c`, "launcher-compat/steam-overlay-d3dmetal-thunks-v2"), which applies them in memory
/// from ntdll; Silo applies them to its own copy of the file at overlay time instead, so the fix holds on both
/// Wine kinds (the imported CrossOver Wine has no WineForge ntdll) with no Wine rebuild. Verified on SoulCalibur VI
/// + DualSense: swap chain hooked, input hook set, Steam Input working.
///
/// Byte-exact: only an image of `SizeOfImage == 0x01025000` whose every fragment reads its original bytes is
/// patched. Any other `dxgi.dll` (GPTK 3, a future GPTK, Wine's or DXMT's own) is left alone.
public enum SteamOverlayDXGIPatch {
    struct Fragment {
        let rva: Int
        let original: [UInt8]
        let patched: [UInt8]
    }

    static let imageSize: UInt32 = 0x0102_5000

    static let fragments: [Fragment] = [
        // The two thunks the fill loop writes per iteration: `ff 25` (jmp [rip+…]) → `48 b8` (mov rax, imm64)…
        Fragment(rva: 0x13a4, original: [0xff, 0x25], patched: [0x48, 0xb8]),
        // …and the 0xbad filler qword at +8, whose bytes +10/+11 become `ff e0` (jmp rax).
        Fragment(rva: 0x13ba, original: [0xad, 0x0b, 0x00, 0x00], patched: [0x00, 0x00, 0xff, 0xe0]),
        Fragment(rva: 0x13c3, original: [0xff, 0x25], patched: [0x48, 0xb8]),
        Fragment(rva: 0x13d9, original: [0xad, 0x0b, 0x00, 0x00], patched: [0x00, 0x00, 0xff, 0xe0]),
        // Each table's target store, `mov [rax+8], r9` → `mov [rax+2], r9`: the address becomes the imm64.
        Fragment(rva: 0x1437, original: [0x08], patched: [0x02]),
        Fragment(rva: 0x1507, original: [0x08], patched: [0x02]),
        Fragment(rva: 0x15b7, original: [0x08], patched: [0x02]),
        Fragment(rva: 0x1667, original: [0x08], patched: [0x02]),
        Fragment(rva: 0x1717, original: [0x08], patched: [0x02]),
        Fragment(rva: 0x17d7, original: [0x08], patched: [0x02]),
    ]

    public enum State: Equatable, Sendable {
        /// Not the GPTK build this patch targets — leave it alone.
        case notApplicable
        case unpatched
        case patched
    }

    /// Which state `data` (a whole `dxgi.dll`) is in.
    public static func state(of data: Data) -> State {
        guard let offsets = fileOffsets(in: data) else { return .notApplicable }
        let bytes = [UInt8](data)
        func all(_ pick: (Fragment) -> [UInt8]) -> Bool {
            zip(fragments, offsets).allSatisfy { f, o in Array(bytes[o..<o + pick(f).count]) == pick(f) }
        }
        if all(\.original) { return .unpatched }
        if all(\.patched) { return .patched }
        return .notApplicable
    }

    /// `data` with the patch applied, or nil when it isn't an unpatched copy of the targeted build.
    public static func apply(to data: Data) -> Data? {
        guard state(of: data) == .unpatched, let offsets = fileOffsets(in: data) else { return nil }
        var bytes = [UInt8](data)
        for (f, o) in zip(fragments, offsets) { bytes.replaceSubrange(o..<o + f.patched.count, with: f.patched) }
        return Data(bytes)
    }

    /// Each fragment's file offset, or nil unless `data` is an AMD64 PE of the targeted size with every
    /// fragment inside a section's raw data.
    static func fileOffsets(in data: Data) -> [Int]? {
        let b = [UInt8](data)
        func u16(_ o: Int) -> Int? { o + 2 <= b.count ? Int(b[o]) | Int(b[o + 1]) << 8 : nil }
        func u32(_ o: Int) -> Int? {
            guard let lo = u16(o), let hi = u16(o + 2) else { return nil }
            return lo | hi << 16
        }
        guard b.count >= 0x40, b[0] == 0x4d, b[1] == 0x5a, let pe = u32(0x3c),
              pe + 24 <= b.count, b[pe..<pe + 4].elementsEqual([0x50, 0x45, 0, 0]),
              u16(pe + 4) == 0x8664,
              let sectionCount = u16(pe + 6), let optionalSize = u16(pe + 20),
              u32(pe + 24 + 56) == Int(imageSize)
        else { return nil }

        var sections: [(va: Int, size: Int, raw: Int)] = []
        let table = pe + 24 + optionalSize
        for i in 0..<sectionCount {
            let s = table + 40 * i
            guard let va = u32(s + 12), let rawSize = u32(s + 16), let raw = u32(s + 20) else { return nil }
            sections.append((va, rawSize, raw))
        }
        var offsets: [Int] = []
        for f in fragments {
            guard let s = sections.first(where: { f.rva >= $0.va && f.rva + f.original.count <= $0.va + $0.size })
            else { return nil }
            let o = s.raw + f.rva - s.va
            guard o + f.original.count <= b.count else { return nil }
            offsets.append(o)
        }
        return offsets
    }
}
