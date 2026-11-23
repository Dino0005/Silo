import Foundation
import Testing
@testable import SiloKit

/// The scripts the guard injects into Steam for macOS are re-injected only when their `version` changes: a running
/// Steam keeps whatever version is live. Changing a script without bumping its version leaves users on the old one
/// until Steam restarts (found 2026-11-23: the "Uncharted fix" switch missing from the Compatibility page). Each test
/// pins the script's fingerprint to its version: when a script changes, bump its `version` and record the new
/// fingerprint here, in the same commit.
@Suite("Injected Steam scripts carry their version")
struct InjectedScriptVersionTests {
    /// 64-bit FNV-1a of the script text.
    static func fingerprint(_ text: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 { hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01b3 }
        return String(hash, radix: 16)
    }

    private func check(_ name: String, version: Int, script: String, pinned: [Int: String]) {
        let actual = Self.fingerprint(script)
        #expect(pinned[version] == actual,
                "\(name) changed: bump its version (now \(version)) and pin \(version + 1): \"\(actual)\" here")
    }

    @Test("Compatibility page")
    func compatibilityPage() {
        check("SteamCompatibilityPage", version: SteamCompatibilityPage.version,
              script: SteamCompatibilityPage.script(tools: [("silo", "Silo")], windowsOnly: [1], windowsBuild: [2],
                                                    known: [1, 2, 3]),
              pinned: [8: "4e4d92461a36010b"])
    }

    @Test("Library filters")
    func libraryFilters() {
        check("SteamLibraryFilters", version: SteamLibraryFilters.version,
              script: SteamLibraryFilters.script(windowsOnly: [1], windowsBuild: [2], known: [1, 2, 3]),
              pinned: [6: "e1443865d133ae73"])
    }

    @Test("Install with Silo")
    func installWithSilo() {
        check("SteamInstallWithSilo", version: SteamInstallWithSilo.version, script: SteamInstallWithSilo.script(),
              pinned: [2: "9cff9a2302b9f32e"])
    }
}
