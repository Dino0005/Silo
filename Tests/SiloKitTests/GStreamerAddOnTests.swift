import Foundation
import CryptoKit
import Testing
@testable import SiloKit

@Suite("GStreamerAddOn")
struct GStreamerAddOnTests {

    // MARK: - Synthetic Mach-O images

    private static func le(_ v: UInt32) -> [UInt8] { withUnsafeBytes(of: v.littleEndian, Array.init) }
    private static func be(_ v: UInt32) -> [UInt8] { withUnsafeBytes(of: v.bigEndian, Array.init) }

    /// A thin x86_64 dylib image: one unrelated load command, then LC_ID_DYLIB with `compat` (major X of X.0.0).
    static func thinDylib(compatMajor: UInt32) -> [UInt8] {
        let filler: [UInt8] = le(0x2A) + le(16) + le(0) + le(0)                 // some other command, 16 bytes
        let name = Array("@rpath/libgstreamer-1.0.0.dylib".utf8) + [0, 0, 0, 0, 0]
        let idCmd: [UInt8] = le(0xD) + le(UInt32(24 + name.count)) + le(24) + le(2)
            + le(compatMajor << 16) + le(compatMajor << 16) + name
        let header: [UInt8] = le(0xFEED_FACF) + le(0x0100_0007) + le(3) + le(6)
            + le(2) + le(UInt32(filler.count + idCmd.count)) + le(0) + le(0)
        return header + filler + idCmd
    }

    /// A universal image with an arm64 slice first and the x86_64 one second.
    static func fatDylib(x86Compat: UInt32) -> [UInt8] {
        let arm = thinDylib(compatMajor: 9999), x86 = thinDylib(compatMajor: x86Compat)
        let armOffset: UInt32 = 64, x86Offset = armOffset + UInt32(arm.count)
        var data = be(0xCAFE_BABE) + be(2)
            + be(0x0100_000C) + be(0) + be(armOffset) + be(UInt32(arm.count)) + be(0)
            + be(0x0100_0007) + be(3) + be(x86Offset) + be(UInt32(x86.count)) + be(0)
        data += [UInt8](repeating: 0, count: Int(armOffset) - data.count)
        return data + arm + x86
    }

    @Test("Reads GStreamer's compatibility version from a thin or universal dylib, without otool")
    func readsCompatibilityVersion() {
        #expect(GStreamerAddOn.compatibilityVersion(ofDylib: Data(Self.thinDylib(compatMajor: 2405))) == 2405 << 16)
        #expect(GStreamerAddOn.compatibilityVersion(ofDylib: Data(Self.fatDylib(x86Compat: 2405))) == 2405 << 16)
        #expect(GStreamerAddOn.compatibilityVersion(ofDylib: Data("not a dylib".utf8)) == nil)
        #expect(GStreamerAddOn.compatibilityVersion(ofDylib: Data()) == nil)
    }

    @Test("The runtime's GStreamer minor comes from lib64's core library (2405 → 1.24)")
    func runtimeMinor() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let root = tmp.url.appendingPathComponent("rt")
        #expect(GStreamerAddOn.gstreamerMinor(ofRuntime: root) == nil)        // no GStreamer at all
        try FileManager.default.createDirectory(at: root.appendingPathComponent("lib64"), withIntermediateDirectories: true)
        try Data(Self.thinDylib(compatMajor: 2405)).write(to: root.appendingPathComponent(GStreamerAddOn.corePath))
        #expect(GStreamerAddOn.gstreamerMinor(ofRuntime: root) == 24)
    }

    @Test("Picks the add-on release for the runtime's GStreamer minor only")
    func picksRelease() {
        func rel(_ tag: String) -> GitHubRelease { GitHubRelease(tagName: tag, name: nil, assets: []) }
        let list = [rel("v0.6.5"), rel("gst-libav-1.28.6"), rel("wine-cx-26.3.0"), rel("gst-libav-1.24.4")]
        #expect(GStreamerAddOn.release(in: list, forMinor: 24)?.tagName == "gst-libav-1.24.4")
        #expect(GStreamerAddOn.release(in: list, forMinor: 28)?.tagName == "gst-libav-1.28.6")
        #expect(GStreamerAddOn.release(in: list, forMinor: 2) == nil)          // "1.2." must not match 1.24
    }

    // MARK: - Merge

    /// An add-on package as build-gst-libav.sh lays it out.
    private func makePackage(_ tmp: TempDir, version: String = "1.24.4") throws -> URL {
        try tmp.write("pkg/GSTREAMER_VERSION", version + "\n")
        try tmp.write("pkg/lib64/gstreamer-1.0/libgstlibav.dylib", "LIBAV")
        try tmp.write("pkg/lib64/gstreamer-1.0/libgstmatroska.dylib", "MKV")
        try tmp.write("pkg/lib64/libavcodec.60.dylib", "AVCODEC")
        return tmp.url.appendingPathComponent("pkg")
    }

    @Test("Merges the plugins and FFmpeg libs into lib64, and is a no-op the second time")
    func merges() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let pkg = try makePackage(tmp)
        try tmp.write("rt/lib64/gstreamer-1.0/libgstplayback.dylib", "CROSSOVER")   // CrossOver's own plugin
        let rt = tmp.url.appendingPathComponent("rt")
        #expect(try GStreamerAddOn.merge(package: pkg, intoRuntime: rt, runtimeMinor: 24) == 3)
        #expect(GStreamerAddOn.isInstalled(inRuntime: rt))
        #expect(try String(contentsOf: rt.appendingPathComponent("lib64/libavcodec.60.dylib"), encoding: .utf8) == "AVCODEC")
        #expect(try String(contentsOf: rt.appendingPathComponent("lib64/gstreamer-1.0/libgstplayback.dylib"),
                           encoding: .utf8) == "CROSSOVER")                         // untouched
        #expect(try GStreamerAddOn.merge(package: pkg, intoRuntime: rt, runtimeMinor: 24) == 0)
    }

    @Test("Refuses another GStreamer minor, and never overwrites a different file (runtime left untouched)")
    func refuses() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let pkg = try makePackage(tmp)
        let rt = tmp.url.appendingPathComponent("rt")
        #expect(throws: GStreamerAddOn.AddOnError.versionMismatch(runtime: 28, addOn: "1.24.4")) {
            try GStreamerAddOn.merge(package: pkg, intoRuntime: rt, runtimeMinor: 28)
        }
        try tmp.write("rt/lib64/libavcodec.60.dylib", "SOMEONE ELSE'S")
        #expect(throws: GStreamerAddOn.AddOnError.wouldOverwrite("lib64/libavcodec.60.dylib")) {
            try GStreamerAddOn.merge(package: pkg, intoRuntime: rt, runtimeMinor: 24)
        }
        #expect(!GStreamerAddOn.isInstalled(inRuntime: rt))                         // nothing was copied
    }

    @Test("Finds the package at the archive's top level or inside one wrapper folder")
    func packageRoot() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        try tmp.write("flat/GSTREAMER_VERSION", "1.24.4")
        try tmp.write("wrapped/gst-libav-1.24.4/GSTREAMER_VERSION", "1.24.4")
        try tmp.makeDir("empty")
        #expect(GStreamerAddOn.packageRoot(in: tmp.url.appendingPathComponent("flat"))?.lastPathComponent == "flat")
        #expect(GStreamerAddOn.packageRoot(in: tmp.url.appendingPathComponent("wrapped"))?.lastPathComponent
                == "gst-libav-1.24.4")
        #expect(GStreamerAddOn.packageRoot(in: tmp.url.appendingPathComponent("empty")) == nil)
    }

    // MARK: - End to end through RuntimeManager

    @Test("addGStreamerAddOn finds the matching release, verifies its digest, merges it and cleans up")
    func endToEnd() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let session = FakeURLProtocol.makeSession()
        let paths = AppPaths(supportDir: tmp.url.appendingPathComponent("Silo"))
        let runtime = paths.runtimesDir.appendingPathComponent("wine-crossover-26.3.0")
        try FileManager.default.createDirectory(at: runtime.appendingPathComponent("lib64"), withIntermediateDirectories: true)
        try Data(Self.thinDylib(compatMajor: 2405)).write(to: runtime.appendingPathComponent(GStreamerAddOn.corePath))

        let archive = Data("ADDON-ARCHIVE".utf8)
        let digest = SHA256.hash(data: archive).map { String(format: "%02x", $0) }.joined()
        let json = """
        [{"tag_name":"v0.6.5","name":null,"assets":[]},
         {"tag_name":"gst-libav-1.24.4","name":null,"assets":[
            {"name":"gst-libav-1.24.4.tar.xz","browser_download_url":"https://e.com/gst-libav-1.24.4.tar.xz"}]}]
        """
        FakeURLProtocol.stub("https://api.github.com/repos/acme/silo/releases?per_page=30&page=1",
                             data: Data(json.utf8), session: session)
        FakeURLProtocol.stub("https://e.com/gst-libav-1.24.4.tar.xz", data: archive, session: session)
        FakeURLProtocol.stub("https://e.com/gst-libav-1.24.4.tar.xz.sha256",
                             data: Data("\(digest)  gst-libav-1.24.4.tar.xz\n".utf8), session: session)

        let fake = FakeProcessRunner()
        fake.onRun = { inv in   // "tar" lays the package out in the staging dir
            guard inv.executable.lastPathComponent == "tar", let c = inv.arguments.firstIndex(of: "-C") else { return }
            let dest = URL(fileURLWithPath: inv.arguments[c + 1])
            let plugin = dest.appendingPathComponent("lib64/gstreamer-1.0/libgstlibav.dylib")
            try? FileManager.default.createDirectory(at: plugin.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? Data("LIBAV".utf8).write(to: plugin)
            try? Data("1.24.4\n".utf8).write(to: dest.appendingPathComponent("GSTREAMER_VERSION"))
        }
        let manager = RuntimeManager(paths: paths, runner: fake, session: session)

        let tag = try await manager.addGStreamerAddOn(toRuntime: "wine-crossover-26.3.0", repo: "acme/silo", requireDigest: true)
        #expect(tag == "gst-libav-1.24.4")
        #expect(GStreamerAddOn.isInstalled(inRuntime: runtime))
        #expect(!FileManager.default.fileExists(
            atPath: paths.runtimesDir.appendingPathComponent(".addon-gst-libav-1.24.4").path))   // download removed
        // Already there: nothing to do, no network needed.
        #expect(try await manager.addGStreamerAddOn(toRuntime: "wine-crossover-26.3.0", repo: "acme/silo",
                                                    requireDigest: true) == nil)
    }
}
