#!/usr/bin/env python3
"""Run this from the root of your Silo checkout: python3 fix-cx-lib64-env.py
Adds CX_APPLEGPTK_LIBD3DSHARED_PATH and GST_PLUGIN_SYSTEM_PATH/GST_REGISTRY to the launch environment —
found by reading CrossOver's own "bin/wine" Perl script, which sets these from a lib64/apple_gptk +
lib64/gstreamer-1.0 tree before every launch. Conditioned on those paths existing, so it's a no-op for
Silo's own self-compiled runtimes (which have no lib64 directory at all)."""
import sys

results = []

def patch_file(path, old, new, label):
    text = open(path, encoding="utf-8").read()
    if new in text:
        results.append(f"{path}: {label} — already patched")
        return
    if old not in text:
        results.append(f"{path}: {label} — ERROR, expected text not found, edit by hand")
        return
    open(path, "w", encoding="utf-8").write(text.replace(old, new, 1))
    results.append(f"{path}: {label} — patched")

patch_file(
    "Sources/SiloKit/Silo.swift",
    '''    public static func wineEnvironment(prefix: URL, wine: URL) -> [String: String] {
        [
            "WINEPREFIX": prefix.path,
            "WINEDEBUG": wineDebug,
            "DYLD_FALLBACK_LIBRARY_PATH": wine.siloDyldFallback,
            // CrossOver-derived wine trees (imported as a custom runtime, not Silo's own self-compiled
            // build) expect CX_ROOT to point at the runtime root — their cxcompatdb and other cx* tooling
            // read it to find their own JSON database/keys (without it: "cxcompatdb: CX_ROOT not set",
            // harmlessly failing open, but still worth setting). A no-op for a self-compiled runtime,
            // which has no cx* tooling to read it.
            "CX_ROOT": WineRuntimeLayout(wineBinary: wine).root.path,
        ]
    }''',
    '''    public static func wineEnvironment(prefix: URL, wine: URL) -> [String: String] {
        let root = WineRuntimeLayout(wineBinary: wine).root
        var env: [String: String] = [
            "WINEPREFIX": prefix.path,
            "WINEDEBUG": wineDebug,
            "DYLD_FALLBACK_LIBRARY_PATH": wine.siloDyldFallback,
            // CrossOver-derived wine trees (imported as a custom runtime, not Silo's own self-compiled
            // build) expect CX_ROOT to point at the runtime root — their cxcompatdb and other cx* tooling
            // read it to find their own JSON database/keys (without it: "cxcompatdb: CX_ROOT not set",
            // harmlessly failing open, but still worth setting). A no-op for a self-compiled runtime,
            // which has no cx* tooling to read it.
            "CX_ROOT": root.path,
        ]

        // CrossOver-derived runtimes ship a SEPARATE apple_gptk/GStreamer tree under <root>/lib64 — its
        // own wine script (CrossOver's Perl "bin/wine") sets these two before every launch; distinct from
        // Silo's own GPTK overlay in <root>/lib/wine, and from the dylib bundle in <root>/lib/silo-bundled.
        // Conditioned on the paths actually existing: a harmless no-op for Silo's own self-compiled
        // runtimes, which have no lib64 directory at all.
        let libd3dshared = root.appendingPathComponent("lib64/apple_gptk/external/libd3dshared.dylib")
        if FileManager.default.fileExists(atPath: libd3dshared.path) {
            env["CX_APPLEGPTK_LIBD3DSHARED_PATH"] = libd3dshared.path
        }
        let gstPlugins = root.appendingPathComponent("lib64/gstreamer-1.0", isDirectory: true)
        if FileManager.default.fileExists(atPath: gstPlugins.path) {
            env["GST_PLUGIN_SYSTEM_PATH"] = gstPlugins.path
            // CrossOver keeps its GStreamer plugin registry cache in its own per-user Application Support
            // dir (CXBottle::get_user_dir()); the closest safe equivalent here is inside the bottle prefix
            // itself, which is already per-bottle and persists across launches without needing a new
            // Silo-managed directory.
            env["GST_REGISTRY"] = prefix.appendingPathComponent("gstreamer-1.0-registry.x86_64.bin").path
        }
        return env
    }''',
    "add CX_APPLEGPTK_LIBD3DSHARED_PATH + GST_PLUGIN_SYSTEM_PATH/GST_REGISTRY to wineEnvironment"
)

patch_file(
    "Tests/SiloKitTests/SiloEnvironmentTests.swift",
    '''    @Test("enforceMsync sets WINEMSYNC and strips a user's WINEESYNC (the co-residency rule)")''',
    '''    @Test("wineEnvironment adds CrossOver's apple_gptk/GStreamer env vars only when that runtime actually has a lib64 tree")
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

    @Test("enforceMsync sets WINEMSYNC and strips a user's WINEESYNC (the co-residency rule)")''',
    "add crossOverLib64Extras test"
)

print("\n".join(results))
if any("ERROR" in r for r in results):
    sys.exit(1)
