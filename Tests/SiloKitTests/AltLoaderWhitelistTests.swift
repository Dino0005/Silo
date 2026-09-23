import Foundation
import Testing
@testable import SiloKit

/// `AltLoaderWhitelist` — the registry gate that decides which executables Wine hands to Silo's
/// alt-loader host. Pure string builders, so these run with no Wine and no prefix.
struct AltLoaderWhitelistTests {

    // MARK: - exeName: mirrors the sender's own matching

    /// The value Wine sees is a **Windows** path, so the backslash form is the one that matters.
    @Test func exeNameFromWindowsPath() {
        #expect(AltLoaderWhitelist.exeName(for: #"C:\windows\system32\notepad.exe"#) == "notepad")
        #expect(AltLoaderWhitelist.exeName(for: #"C:\Program Files (x86)\Steam\steam.exe"#) == "steam")
    }

    @Test func exeNameFromUnixPath() {
        #expect(AltLoaderWhitelist.exeName(for: "/games/Tekken 8/Binaries/tekken.exe") == "tekken")
    }

    /// A bare name, with or without an extension, comes through unharmed.
    @Test func exeNameWithoutDirectories() {
        #expect(AltLoaderWhitelist.exeName(for: "notepad.exe") == "notepad")
        #expect(AltLoaderWhitelist.exeName(for: "launcher") == "launcher")
    }

    /// Only the LAST dot is the extension separator — a versioned name keeps its dots.
    @Test func exeNameCutsAtTheLastDot() {
        #expect(AltLoaderWhitelist.exeName(for: #"C:\g\GravityMark 1.89.exe"#) == "GravityMark 1.89")
    }

    /// A name that is only an extension keeps its leading dot: that is what the sender's `strrchr`
    /// leaves, and guessing differently would silently fail to match.
    @Test func exeNameKeepsALeadingDot() {
        #expect(AltLoaderWhitelist.exeName(for: ".hidden") == ".hidden")
    }

    // MARK: - enableReg

    @Test func enableRegWhitelistsTheGivenNames() {
        let reg = AltLoaderWhitelist.enableReg(exeNames: ["notepad", "steam"])
        #expect(reg.hasPrefix("REGEDIT4\r\n"))
        #expect(reg.contains(#"[HKEY_CURRENT_USER\Software\CrossOver\UseAltLoader]"#))
        #expect(reg.contains("\"notepad\"=\"1\"\r\n"))
        #expect(reg.contains("\"steam\"=\"1\"\r\n"))
        // not a deletion
        #expect(!reg.contains("[-HKEY"))
    }

    /// CRLF throughout: `regedit` reads a DOS text file.
    @Test func enableRegUsesCRLF() {
        let reg = AltLoaderWhitelist.enableReg(exeNames: ["notepad"])
        #expect(!reg.contains("\n\n"))                    // no bare LF pairs
        #expect(reg.components(separatedBy: "\r\n").count > 3)
    }

    @Test func enableRegEscapesQuotesAndBackslashes() {
        let reg = AltLoaderWhitelist.enableReg(exeNames: [#"od"d\name"#])
        #expect(reg.contains(#"\""#))
        #expect(reg.contains(#"\\"#))
    }

    // MARK: - disableReg — the footgun guard

    /// The whole point: disabling must DELETE the key. An existing-but-empty `UseAltLoader` matches
    /// nothing and would exclude every executable from the alt loader — the state a half-finished
    /// `reg delete` left behind during the 2026-09-23 experiments.
    @Test func disableRegDeletesTheKeyRatherThanEmptyingIt() {
        let reg = AltLoaderWhitelist.disableReg()
        #expect(reg.contains(#"[-HKEY_CURRENT_USER\Software\CrossOver\UseAltLoader]"#))
        #expect(!reg.contains("=\"1\""))
    }

    /// An empty whitelist is NOT the way to disable: it still writes the key, so it would block
    /// everything. Guards the distinction so a future caller can't conflate the two.
    @Test func emptyEnableRegIsNotTheSameAsDisabling() {
        let empty = AltLoaderWhitelist.enableReg(exeNames: [])
        #expect(empty.contains(#"[HKEY_CURRENT_USER\Software\CrossOver\UseAltLoader]"#))
        #expect(!empty.contains("[-HKEY"))
        #expect(empty != AltLoaderWhitelist.disableReg())
    }
}
