import Foundation
import Testing
@testable import SiloKit

@Suite("Silo.wineEnvironment")
struct SiloEnvironmentTests {

    @Test("Base wine env: isolated WINEPREFIX, build-gated logging, bundled DYLD fallback")
    func base() {
        let env = Silo.wineEnvironment(
            prefix: URL(fileURLWithPath: "/p/220"),
            wine: URL(fileURLWithPath: "/rt/bin/wine"))
        #expect(env["WINEPREFIX"] == "/p/220")
        #expect(env["WINEDEBUG"] == Silo.wineDebug)   // verbose in local builds, "-all" under CI
        // <wine root>/lib/silo-bundled is first (so wine's dlopen'd deps resolve from the hermetic bundle);
        // /usr/local/lib (Homebrew) is deliberately NOT on the path — it leaked a duplicate gtk into wine.
        #expect(env["DYLD_FALLBACK_LIBRARY_PATH"] == "/rt/lib/silo-bundled:/usr/lib")
        // A no-op for Silo's own self-compiled runtimes; a CrossOver-derived imported runtime's cx*
        // tooling (cxcompatdb, etc.) reads this to find its own root — without it: "CX_ROOT not set".
        #expect(env["CX_ROOT"] == "/rt")
        #expect(env.count == 4)   // base only — callers layer their own overrides
    }

    @Test("wineEnvironment adds CrossOver's apple_gptk/GStreamer env vars only when that runtime actually has a lib64 tree")
    func crossOverLib64Extras() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let prefix = URL(fileURLWithPath: "/p/220")

        // A runtime WITHOUT lib64 (Silo's own self-compiled build) — no extras, matching upstream Wine.
        let plainWine = try tmp.write("plain/bin/wine", "#!/bin/sh")
        let plainEnv = Silo.wineEnvironment(prefix: prefix, wine: plainWine)
        #expect(plainEnv["CX_APPLEGPTK_LIBD3DSHARED_PATH"] == nil)
        #expect(plainEnv["GST_PLUGIN_SYSTEM_PATH"] == nil)
        #expect(plainEnv["GST_REGISTRY"] == nil)

        // A CrossOver-derived runtime WITH lib64/apple_gptk + lib64/gstreamer-1.0 — extras present, matching
        // exactly what CrossOver's own "bin/wine" Perl script sets before every launch.
        let cxWine = try tmp.write("cx/bin/wine", "#!/bin/sh")
        try tmp.write("cx/lib64/apple_gptk/external/libd3dshared.dylib", "DYLIB")
        try tmp.makeDir("cx/lib64/gstreamer-1.0")
        let cxRoot = cxWine.deletingLastPathComponent().deletingLastPathComponent()
        let cxEnv = Silo.wineEnvironment(prefix: prefix, wine: cxWine)
        #expect(cxEnv["CX_APPLEGPTK_LIBD3DSHARED_PATH"]
            == cxRoot.appendingPathComponent("lib64/apple_gptk/external/libd3dshared.dylib").path)
        #expect(cxEnv["GST_PLUGIN_SYSTEM_PATH"] == cxRoot.appendingPathComponent("lib64/gstreamer-1.0").path)
        #expect(cxEnv["GST_REGISTRY"] == prefix.appendingPathComponent("gstreamer-1.0-registry.x86_64.bin").path)
    }

    @Test("enforceMsync sets WINEMSYNC and strips a user's WINEESYNC (the co-residency rule)")
    func enforceMsync() {
        var env = ["WINEESYNC": "1", "FOO": "bar"]
        Silo.enforceMsync(&env)
        #expect(env["WINEMSYNC"] == "1")
        #expect(env["WINEESYNC"] == nil)   // a split sync mode would fork a second wineserver
        #expect(env["FOO"] == "bar")       // everything else untouched
    }

    @Test("msyncWineEnvironment = the base wine env + the co-residency sync rule")
    func msyncEnvironment() {
        let wine = URL(fileURLWithPath: "/rt/bin/wine64")
        let env = Silo.msyncWineEnvironment(prefix: URL(fileURLWithPath: "/bottle"), wine: wine)
        #expect(env["WINEPREFIX"] == "/bottle")
        #expect(env["WINEMSYNC"] == "1")
        #expect(env["WINEESYNC"] == nil)
        #expect(env["DYLD_FALLBACK_LIBRARY_PATH"] == wine.siloDyldFallback)
    }
}
