import Foundation
import Testing
@testable import SiloKit

@Suite("MediaFoundationImporter")
struct MediaFoundationImporterTests {

    private func importer(_ tmp: TempDir) -> MediaFoundationImporter {
        MediaFoundationImporter(paths: AppPaths(supportDir: tmp.url.appendingPathComponent("Silo")))
    }

    /// Build a source folder shaped like the community MF packages: system32/ + syswow64/ with the nine
    /// DLLs each, plus the two registry exports.
    @discardableResult
    private func makePackage(
        in parent: URL,
        named name: String = "mf-src",
        dlls: [String] = MediaFoundationPackage.dllNames,
        uppercased: Bool = false,
        omit: Set<String> = []
    ) throws -> URL {
        let fm = FileManager.default
        let root = parent.appendingPathComponent(name, isDirectory: true)
        for dir in ["system32", "syswow64"] where !omit.contains(dir) {
            let d = root.appendingPathComponent(dir, isDirectory: true)
            try fm.createDirectory(at: d, withIntermediateDirectories: true)
            for dll in dlls {
                let file = uppercased ? "\(dll.uppercased()).DLL" : "\(dll).dll"
                try Data("PE".utf8).write(to: d.appendingPathComponent(file))
            }
        }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        for reg in ["mf.reg", "wmf.reg"] where !omit.contains(reg) {
            try Data("REGEDIT4".utf8).write(to: root.appendingPathComponent(reg))
        }
        return root
    }

    @Test("Imports a complete package into Runtimes/media-foundation")
    func importsCompletePackage() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let src = try makePackage(in: tmp.url)
        let mf = importer(tmp)

        #expect(mf.installed() == nil)   // nothing imported yet
        let pkg = try mf.importPackage(from: src)

        #expect(pkg.installDir.lastPathComponent == "media-foundation")
        #expect(FileManager.default.fileExists(atPath: pkg.mfReg.path))
        #expect(FileManager.default.fileExists(atPath: pkg.wmfReg.path))
        #expect(FileManager.default.fileExists(
            atPath: pkg.system32.appendingPathComponent("mfplat.dll").path))
        #expect(FileManager.default.fileExists(
            atPath: pkg.syswow64.appendingPathComponent("msmpeg2vdec.dll").path))
        #expect(mf.installed() != nil)
    }

    @Test("Rejects a folder missing syswow64 or a .reg, naming what's absent")
    func rejectsIncompleteShape() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let src = try makePackage(in: tmp.url, omit: ["syswow64", "wmf.reg"])
        let mf = importer(tmp)

        #expect(throws: MediaFoundationImporter.ImportError.missingComponents(["syswow64/", "wmf.reg"])) {
            try mf.inspect(src)
        }
    }

    @Test("Rejects a folder that has the right shape but is missing DLLs")
    func rejectsMissingDLLs() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        // Everything except the H.264 decoder and the colour converter.
        let partial = MediaFoundationPackage.dllNames.filter { $0 != "msmpeg2vdec" && $0 != "colorcnv" }
        let src = try makePackage(in: tmp.url, dlls: partial)
        let mf = importer(tmp)

        #expect(throws: MediaFoundationImporter.ImportError.missingDLLs([
            "system32/colorcnv.dll", "system32/msmpeg2vdec.dll",
            "syswow64/colorcnv.dll", "syswow64/msmpeg2vdec.dll",
        ])) {
            try mf.inspect(src)
        }
    }

    @Test("Accepts DLLs named in Windows' own casing (MFPlat.DLL), not just lowercase")
    func acceptsUppercaseNames() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let src = try makePackage(in: tmp.url, uppercased: true)
        #expect(throws: Never.self) { try importer(tmp).inspect(src) }
    }

    @Test("A failed import leaves no partial tree behind — installed() stays nil")
    func failedImportLeavesNothing() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let src = try makePackage(in: tmp.url, omit: ["mf.reg"])
        let mf = importer(tmp)

        #expect(throws: (any Error).self) { try mf.importPackage(from: src) }
        #expect(mf.installed() == nil)
        // ...and no staging dir was orphaned under Runtimes.
        let leftovers = (try? FileManager.default.contentsOfDirectory(
            atPath: AppPaths(supportDir: tmp.url.appendingPathComponent("Silo")).runtimesDir.path)) ?? []
        #expect(leftovers.allSatisfy { !$0.hasPrefix(".mf-import-") })
    }

    @Test("Re-importing replaces the previous package")
    func reimportReplaces() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let mf = importer(tmp)
        try mf.importPackage(from: try makePackage(in: tmp.url, named: "first"))

        // A second package whose mf.reg has different content — proves the tree was replaced, not merged.
        let second = try makePackage(in: tmp.url, named: "second")
        try Data("REGEDIT5-SECOND".utf8).write(to: second.appendingPathComponent("mf.reg"))
        let pkg = try mf.importPackage(from: second)

        #expect(try String(contentsOf: pkg.mfReg, encoding: .utf8) == "REGEDIT5-SECOND")
    }

    @Test("remove() clears the install")
    func removeClears() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let mf = importer(tmp)
        try mf.importPackage(from: try makePackage(in: tmp.url))
        #expect(mf.installed() != nil)

        try mf.remove()
        #expect(mf.installed() == nil)
        #expect(throws: Never.self) { try mf.remove() }   // idempotent
    }
}
