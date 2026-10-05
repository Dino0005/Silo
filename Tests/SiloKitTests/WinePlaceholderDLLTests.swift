import Foundation
import Testing
import CryptoKit
@testable import SiloKit

@Suite("WinePlaceholderDLL")
struct WinePlaceholderDLLTests {
    @Test("bytes are exactly wineboot's x86_64 placeholder")
    func matchesWineboot() {
        // SHA-256 of the 1032-byte placeholder wineboot writes into system32 — measured identical for
        // nvapi64/nvngx/atidxx64 in CrossOver 26.3 bottles and in a Silo bottle booted on that Wine.
        let digest = SHA256.hash(data: WinePlaceholderDLL.bytes).map { String(format: "%02x", $0) }.joined()
        #expect(WinePlaceholderDLL.bytes.count == 1032)
        #expect(digest == "76935dbf9665ab75549e61de1c912dd41f34c81bbf6cd985386717e3a2bb439b")
    }

    @Test("tells a placeholder from a real builtin and from a native DLL")
    func classifies() {
        let builtin = Data("MZ".utf8) + Data(count: 0x3e) + Data("Wine builtin DLL".utf8)
        let native = Data("MZ".utf8) + Data(count: 0x3e) + Data("This program cannot be run in DOS".utf8)

        #expect(WinePlaceholderDLL.isPlaceholder(WinePlaceholderDLL.bytes))
        #expect(!WinePlaceholderDLL.isBuiltin(WinePlaceholderDLL.bytes))
        #expect(WinePlaceholderDLL.isBuiltin(builtin))
        #expect(!WinePlaceholderDLL.isPlaceholder(builtin))
        #expect(!WinePlaceholderDLL.isBuiltin(native))
        #expect(!WinePlaceholderDLL.isPlaceholder(native))
        #expect(!WinePlaceholderDLL.isBuiltin(Data("MZ".utf8)))   // too short to carry a marker
    }
}
