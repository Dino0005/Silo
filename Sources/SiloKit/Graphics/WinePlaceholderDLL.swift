import Foundation

/// Wine's x86_64 "placeholder" DLL — the 1032-byte stub `wineboot` drops into `system32` for every builtin it
/// knows. Wine recognises it by the signature at offset 0x40 and loads the real builtin from its own DLL path
/// instead; the stub itself never runs. The bytes don't depend on the DLL's name: the same file stands in for
/// `nvapi64`, `nvngx`, `atidxx64`… (measured byte-identical in CrossOver bottles and in a Silo bottle).
///
/// Silo needs to write one itself for builtins wine doesn't ship (see `GraphicsLinker.installGPTKPrefixLoaders`).
/// Built field by field from Wine's layout rather than copied from anywhere, so nothing is taken from a bottle.
public enum WinePlaceholderDLL {
    /// Wine's marker for a placeholder (at offset 0x40, right after the DOS header).
    static let placeholderSignature = Data("Wine placeholder DLL".utf8)
    /// Wine's marker for a real builtin PE (same offset) — what GPTK's own DLLs carry.
    static let builtinSignature = Data("Wine builtin DLL".utf8)
    private static let signatureOffset = 0x40

    /// The placeholder's bytes.
    public static let bytes: Data = {
        var d = Data(count: 0x408)
        func put16(_ v: UInt16, _ at: Int) { withUnsafeBytes(of: v.littleEndian) { d.replaceSubrange(at..<at + 2, with: $0) } }
        func put32(_ v: UInt32, _ at: Int) { withUnsafeBytes(of: v.littleEndian) { d.replaceSubrange(at..<at + 4, with: $0) } }
        func put64(_ v: UInt64, _ at: Int) { withUnsafeBytes(of: v.littleEndian) { d.replaceSubrange(at..<at + 8, with: $0) } }
        func putBytes(_ b: Data, _ at: Int) { d.replaceSubrange(at..<at + b.count, with: b) }

        // DOS header, then the signature where a DOS stub would be. PE header at 0x60.
        putBytes(Data("MZ".utf8), 0x00)
        put16(0x40, 0x02); put16(1, 0x04); put16(6, 0x08); put16(0xffff, 0x0c); put16(0xb8, 0x10)
        put16(0x60, 0x18)                       // e_lfarlc
        put32(0x60, 0x3c)                       // e_lfanew
        putBytes(placeholderSignature, signatureOffset)

        // COFF header: AMD64, two sections, 0xf0-byte optional header, IMAGE_FILE_DLL.
        putBytes(Data("PE\0\0".utf8), 0x60)
        put16(0x8664, 0x64); put16(2, 0x66); put16(0xf0, 0x74); put16(0x2000, 0x76)

        // PE32+ optional header.
        put16(0x20b, 0x78); d[0x7a] = 1         // magic, linker 1.0
        put32(5, 0x7c)                          // SizeOfCode
        put32(0x1000, 0x88); put32(0x1000, 0x8c) // entry point, BaseOfCode
        put64(0x1000_0000, 0x90)                // ImageBase
        put32(0x1000, 0x98); put32(0x200, 0x9c) // section / file alignment
        put16(1, 0xa0); put16(1, 0xa4); put16(4, 0xa8) // OS 1.0, image 1.0, subsystem 4.0
        put32(0x3000, 0xb0); put32(0x200, 0xb4) // SizeOfImage, SizeOfHeaders
        put16(2, 0xbc)                          // IMAGE_SUBSYSTEM_WINDOWS_GUI
        put32(16, 0xe4)                         // NumberOfRvaAndSizes
        put32(0x2000, 0x110); put32(8, 0x114)   // data directory 5: base relocations

        // Section table: .text (the entry point) and .reloc (one empty block).
        putBytes(Data(".text".utf8), 0x168)
        put32(0x1000, 0x170); put32(0x1000, 0x174); put32(5, 0x178); put32(0x200, 0x17c)
        put32(0x6000_0020, 0x18c)               // code | execute | read
        putBytes(Data(".reloc".utf8), 0x190)
        put32(0x1000, 0x198); put32(0x2000, 0x19c); put32(8, 0x1a0); put32(0x400, 0x1a4)
        put32(0x4200_0040, 0x1b4)               // initialized data | discardable | read

        // DllMain: `xor eax, eax; ret 0xc` — returns FALSE, never reached because wine loads the builtin.
        putBytes(Data([0x31, 0xc0, 0xc2, 0x0c, 0x00]), 0x200)
        return d
    }()

    /// Whether `data` is a Wine placeholder.
    public static func isPlaceholder(_ data: Data) -> Bool { hasSignature(placeholderSignature, in: data) }

    /// Whether `data` is a Wine builtin PE (a real builtin copied by hand, not a placeholder).
    public static func isBuiltin(_ data: Data) -> Bool { hasSignature(builtinSignature, in: data) }

    private static func hasSignature(_ signature: Data, in data: Data) -> Bool {
        let start = data.startIndex + signatureOffset
        guard data.count >= signatureOffset + signature.count, data.prefix(2) == Data("MZ".utf8)
        else { return false }
        return data[start..<start + signature.count] == signature
    }
}
