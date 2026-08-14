import Foundation
import Testing
@testable import SiloKit

/// The Swift port of `install-local-crossover-wine.sh`. The load-bearing parts are the version-derived
/// name (so a CrossOver update installs alongside, not over) and the wine64 → wineloader symlink, without
/// which Silo's runtime discovery sees a Perl script instead of a binary.
@Suite("CrossOver Wine import")
struct CrossOverWineImporterTests {

    private let fm = FileManager.default

    /// A CrossOver.app skeleton: Info.plist with a version, a Wine tree, and the real loader.
    @discardableResult
    private func makeCrossOver(_ url: URL, version: String?, loader: Bool = true,
                               wineTree: Bool = true) throws -> URL {
        try fm.createDirectory(at: url.appendingPathComponent("Contents"),
                               withIntermediateDirectories: true)
        var plist: [String: Any] = ["CFBundleName": "CrossOver"]
        if let version { plist["CFBundleShortVersionString"] = version }
        (plist as NSDictionary).write(to: url.appendingPathComponent("Contents/Info.plist"),
                                      atomically: true)
        if wineTree {
            let bin = url.appendingPathComponent("Contents/SharedSupport/CrossOver/bin")
            try fm.createDirectory(at: bin, withIntermediateDirectories: true)
            // CrossOver's own wine/wine64 are Perl scripts — the thing the symlink exists to bypass.
            fm.createFile(atPath: bin.appendingPathComponent("wine").path,
                          contents: Data("#!/usr/bin/perl\n".utf8))
            fm.createFile(atPath: bin.appendingPathComponent("wine64").path,
                          contents: Data("#!/usr/bin/perl\n".utf8))
            if loader {
                fm.createFile(atPath: bin.appendingPathComponent("wineloader").path,
                              contents: Data("MZ".utf8))
            }
        }
        return url
    }

    private func runner() -> FakeProcessRunner {
        let fake = FakeProcessRunner()
        // Stand in for /bin/cp: the real one isn't worth invoking, but the copy has to happen for the
        // symlink step to have something to work on.
        fake.onRun = { inv in
            guard inv.executable.lastPathComponent == "cp", inv.arguments.count >= 3 else { return }
            let from = URL(fileURLWithPath: inv.arguments[inv.arguments.count - 2])
            let to = URL(fileURLWithPath: inv.arguments[inv.arguments.count - 1])
            try? FileManager.default.copyItem(at: from, to: to)
        }
        return fake
    }

    @Test("detect reads the version and derives the runtime name")
    func detectReadsVersion() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let app = try makeCrossOver(tmp.url.appendingPathComponent("CrossOver.app"), version: "26.3.0")
        let found = try #require(CrossOverWineImporter.detect(at: app.path))
        #expect(found.version == "26.3.0")
        // Named after the version, so importing after a CrossOver update lands beside the old runtime.
        #expect(found.runtimeName == "wine-crossover-26.3.0")
    }

    @Test("detect returns nil when CrossOver is absent, or has no Wine tree")
    func detectFailsClosed() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        #expect(CrossOverWineImporter.detect(at: tmp.url.appendingPathComponent("Nope.app").path) == nil)

        let noTree = try makeCrossOver(tmp.url.appendingPathComponent("NoTree.app"),
                                       version: "26.3.0", wineTree: false)
        #expect(CrossOverWineImporter.detect(at: noTree.path) == nil)
    }

    @Test("DXMT is installed as its OWN runtime, with x86_64-windows at the root")
    func dxmtBecomesItsOwnRuntime() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let app = try makeCrossOver(tmp.url.appendingPathComponent("CrossOver.app"), version: "26.3.0")
        // CrossOver keeps its DXMT inside the Wine tree — where `standardDXMTLibDir` won't look.
        let dxmt = app.appendingPathComponent(
            "Contents/SharedSupport/CrossOver/lib/dxmt/x86_64-windows")
        try fm.createDirectory(at: dxmt, withIntermediateDirectories: true)
        for dll in ["d3d11.dll", "winemetal.dll"] {
            fm.createFile(atPath: dxmt.appendingPathComponent(dll).path, contents: Data("x".utf8))
        }
        let runtimes = tmp.url.appendingPathComponent("Runtimes")

        let found = try #require(CrossOverWineImporter.detect(at: app.path))
        #expect(found.hasDXMT)
        let name = try await CrossOverWineImporter(runner: runner())
            .install(.dxmt, from: app.path, into: runtimes)
        #expect(name == "dxmt-crossover-26.3.0")

        // At the ROOT of the new runtime — the layout the DXMT listing recognises.
        #expect(fm.fileExists(atPath: runtimes
            .appendingPathComponent("\(name)/x86_64-windows/winemetal.dll").path))
        // And no wine binary: this is a backend, not a runtime to launch under.
        #expect(!fm.fileExists(atPath: runtimes.appendingPathComponent("\(name)/bin/wine64").path))
    }

    @Test("a CrossOver with no bundled DXMT reports hasDXMT false")
    func noBundledDXMT() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let app = try makeCrossOver(tmp.url.appendingPathComponent("CrossOver.app"), version: "26.3.0")
        let found = try #require(CrossOverWineImporter.detect(at: app.path))
        #expect(!found.hasDXMT)     // the DXMT tab offers nothing rather than a doomed import
    }

    @Test("install copies the tree and points bin/wine64 at the REAL loader")
    func installLinksTheLoader() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let app = try makeCrossOver(tmp.url.appendingPathComponent("CrossOver.app"), version: "26.3.0")
        let runtimes = tmp.url.appendingPathComponent("Runtimes")

        let name = try await CrossOverWineImporter(runner: runner()).install(from: app.path,
                                                                            into: runtimes)
        #expect(name == "wine-crossover-26.3.0")

        let wine64 = runtimes.appendingPathComponent("\(name)/bin/wine64")
        let attributes = try fm.attributesOfItem(atPath: wine64.path)
        #expect(attributes[.type] as? FileAttributeType == .typeSymbolicLink)
        #expect(try fm.destinationOfSymbolicLink(atPath: wine64.path) == "wineloader")
        // Relative link, so the runtime stays valid if the whole tree is moved.
        #expect(try String(contentsOf: wine64, encoding: .utf8) == "MZ")
    }

    @Test("a CrossOver with no wineloader leaves NOTHING behind")
    func missingLoaderLeavesNoPartialInstall() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let app = try makeCrossOver(tmp.url.appendingPathComponent("CrossOver.app"),
                                    version: "26.3.0", loader: false)
        let runtimes = tmp.url.appendingPathComponent("Runtimes")

        await #expect(throws: CrossOverWineImporter.ImportError.noLoader) {
            try await CrossOverWineImporter(runner: runner()).install(from: app.path, into: runtimes)
        }
        // Half an install would be listed as a runtime and adopted — worse than none.
        #expect(!fm.fileExists(atPath: runtimes.appendingPathComponent("wine-crossover-26.3.0").path))
    }

    @Test("a version-less Info.plist is refused before anything is copied")
    func missingVersionIsRefused() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let app = try makeCrossOver(tmp.url.appendingPathComponent("CrossOver.app"), version: nil)
        await #expect(throws: CrossOverWineImporter.ImportError.noVersion) {
            try await CrossOverWineImporter(runner: runner())
                .install(from: app.path, into: tmp.url.appendingPathComponent("Runtimes"))
        }
    }

    @Test("every import error reads as a sentence, not as Cocoa's fallback")
    func errorsAreReadable() {
        let errors: [CrossOverWineImporter.ImportError] = [
            .notFound("/Applications/CrossOver.app"), .notACrossOverBundle, .noVersion,
            .noWineTree, .noLoader, .copyFailed(1),
        ]
        for error in errors {
            let text = (error as NSError).localizedDescription
            #expect(!text.contains("couldn't be completed"))
            #expect(!text.isEmpty)
        }
    }
}
