import Foundation
import Testing
@testable import SiloKit

@Suite("BottleCloner")
struct BottleClonerTests {

    private func makePrefix(_ tmp: TempDir, _ name: String) throws -> URL {
        let prefix = try tmp.makeDir(name)
        try tmp.makeDir("\(name)/drive_c/windows/system32")
        try tmp.write("\(name)/system.reg", "WINE REGISTRY Version 2")
        return prefix
    }

    @Test("Clones with cp -Rc (copy-on-write) when the filesystem supports it")
    func clonesCopyOnWrite() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let source = try makePrefix(tmp, "SteamBottle")
        let dest = tmp.url.appendingPathComponent("SteamBottleMF")
        let fake = FakeProcessRunner()

        try await BottleCloner(runner: fake).clone(from: source, to: dest)

        let call = try #require(fake.lastInvocation)
        #expect(call.executable.path == "/bin/cp")
        #expect(call.arguments == ["-Rc", source.path, dest.path])
        #expect(fake.invocations.count == 1)   // no fallback needed
    }

    @Test("Falls back to a plain cp -R when cloning isn't supported (non-APFS bottles root)")
    func fallsBackToPlainCopy() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let source = try makePrefix(tmp, "SteamBottle")
        let dest = tmp.url.appendingPathComponent("SteamBottleMF")
        let fake = FakeProcessRunner()
        fake.queueResult(ProcessResult(exitCode: 1, standardError: Data("clonefile failed".utf8)))
        fake.queueResult(ProcessResult(exitCode: 0))

        try await BottleCloner(runner: fake).clone(from: source, to: dest)

        #expect(fake.invocations.count == 2)
        #expect(fake.invocations[0].arguments.first == "-Rc")
        #expect(fake.invocations[1].arguments.first == "-R")
    }

    @Test("Surfaces the failure when both copy attempts fail")
    func propagatesCopyFailure() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let source = try makePrefix(tmp, "SteamBottle")
        let dest = tmp.url.appendingPathComponent("SteamBottleMF")
        let fake = FakeProcessRunner()
        fake.queueResult(ProcessResult(exitCode: 1))
        fake.queueResult(ProcessResult(exitCode: 28, standardError: Data("No space left".utf8)))

        await #expect(throws: BottleCloner.CloneError.copyFailed(status: 28, stderr: "No space left")) {
            try await BottleCloner(runner: fake).clone(from: source, to: dest)
        }
    }

    @Test("Refuses a source that isn't a Wine prefix, and never shells out")
    func refusesNonPrefix() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let notAPrefix = try tmp.makeDir("random-folder")
        let fake = FakeProcessRunner()

        await #expect(throws: BottleCloner.CloneError.sourceMissing(notAPrefix)) {
            try await BottleCloner(runner: fake)
                .clone(from: notAPrefix, to: tmp.url.appendingPathComponent("dest"))
        }
        #expect(fake.invocations.isEmpty)
    }

    @Test("Refuses to overwrite an existing destination — a bottle holds a login and saves")
    func refusesExistingDestination() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let source = try makePrefix(tmp, "SteamBottle")
        let dest = try makePrefix(tmp, "SteamBottleMF")
        let fake = FakeProcessRunner()

        await #expect(throws: BottleCloner.CloneError.destinationExists(dest)) {
            try await BottleCloner(runner: fake).clone(from: source, to: dest)
        }
        #expect(fake.invocations.isEmpty)
    }
}

@Suite("MediaFoundationInstaller")
struct MediaFoundationInstallerTests {

    private let wine = URL(fileURLWithPath: "/w/bin/wine64")

    /// A prefix plus an MF package, both on disk, ready to install.
    private func fixture(_ tmp: TempDir) throws -> (prefix: URL, package: MediaFoundationPackage) {
        let prefix = try tmp.makeDir("bottle")
        try tmp.makeDir("bottle/drive_c/windows/system32")
        try tmp.makeDir("bottle/drive_c/windows/syswow64")

        let pkgDir = try tmp.makeDir("mf")
        for dir in ["system32", "syswow64"] {
            try tmp.makeDir("mf/\(dir)")
            for dll in MediaFoundationPackage.dllNames {
                try tmp.write("mf/\(dir)/\(dll).dll", "PE-\(dir)")
            }
        }
        try tmp.write("mf/mf.reg", "REGEDIT4")
        try tmp.write("mf/wmf.reg", "REGEDIT5")
        return (prefix, MediaFoundationPackage(installDir: pkgDir))
    }

    @Test("Copies all nine DLLs into both system32 and syswow64")
    func copiesDLLs() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let (prefix, package) = try fixture(tmp)

        try await MediaFoundationInstaller(runner: FakeProcessRunner())
            .install(package: package, intoPrefix: prefix, wine: wine)

        for dir in ["system32", "syswow64"] {
            for dll in MediaFoundationPackage.dllNames {
                let path = prefix.appendingPathComponent("drive_c/windows/\(dir)/\(dll).dll").path
                #expect(FileManager.default.fileExists(atPath: path), "missing \(dir)/\(dll).dll")
            }
        }
    }

    @Test("Replaces a Wine builtin symlink rather than copying onto it")
    func replacesSymlinks() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let (prefix, package) = try fixture(tmp)
        // Wine ships some of these as links into its own tree; a plain copy onto one would fail.
        let target = try tmp.write("elsewhere/mfplat.dll", "WINE-BUILTIN")
        let link = prefix.appendingPathComponent("drive_c/windows/system32/mfplat.dll")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        try await MediaFoundationInstaller(runner: FakeProcessRunner())
            .install(package: package, intoPrefix: prefix, wine: wine)

        #expect(try String(contentsOf: link, encoding: .utf8) == "PE-system32")
        #expect(try String(contentsOf: target, encoding: .utf8) == "WINE-BUILTIN")  // link followed, not written through
    }

    @Test("Writes the nine overrides as ONE regedit call, not nine")
    func overridesAreASingleImport() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let (prefix, package) = try fixture(tmp)
        let fake = FakeProcessRunner()
        // onRun is @Sendable, so it can't mutate a captured var — the staged contents go through a
        // locked box, same as the progress stages below.
        let captured = TextBox()
        fake.onRun = { inv in
            guard inv.arguments.contains("C:\\silo-mf-overrides.reg") else { return }
            let staged = prefix.appendingPathComponent("drive_c/silo-mf-overrides.reg")
            captured.value = try? String(contentsOf: staged, encoding: .utf8)
        }

        try await MediaFoundationInstaller(runner: fake)
            .install(package: package, intoPrefix: prefix, wine: wine)

        let contents = try #require(captured.value)
        #expect(contents.contains("[HKEY_CURRENT_USER\\Software\\Wine\\DllOverrides]"))
        for dll in MediaFoundationPackage.dllNames {
            #expect(contents.contains("\"\(dll)\"=\"native\""))
        }
        let overrideCalls = fake.invocations.filter { $0.arguments.contains("C:\\silo-mf-overrides.reg") }
        #expect(overrideCalls.count == 1)
    }

    @Test("Imports both .reg files in BOTH architectures — 32-bit reads the Wow6432Node view")
    func importsRegistryBothArchitectures() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let (prefix, package) = try fixture(tmp)
        let fake = FakeProcessRunner()

        try await MediaFoundationInstaller(runner: fake)
            .install(package: package, intoPrefix: prefix, wine: wine)

        for reg in ["silo-mf.reg", "silo-wmf.reg"] {
            let calls = fake.invocations.filter { $0.arguments.contains("C:\\\(reg)") }
            #expect(calls.count == 2, "\(reg) should be imported 64- and 32-bit")
            #expect(calls.contains { $0.arguments.first == "regedit" })
            #expect(calls.contains { $0.arguments.first == "C:\\windows\\syswow64\\regedit.exe" })
        }
    }

    @Test("Registers the three COM modules in both architectures, silently")
    func registersComModules() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let (prefix, package) = try fixture(tmp)
        let fake = FakeProcessRunner()

        try await MediaFoundationInstaller(runner: fake)
            .install(package: package, intoPrefix: prefix, wine: wine)

        for module in MediaFoundationPackage.comModules {
            let calls = fake.invocations.filter { $0.arguments.contains("\(module).dll") }
            #expect(calls.count == 2, "\(module) should be registered 64- and 32-bit")
            #expect(calls.allSatisfy { $0.arguments.contains("/s") })   // no dialog per module
        }
        // msmpeg2vdec is the one that writes the H.264 decoder's InputTypes — the step whose absence
        // kept the video black through every earlier attempt.
        #expect(fake.invocations.contains { $0.arguments.contains("msmpeg2vdec.dll") })
    }

    @Test("Overrides are written BEFORE regsvr32, so registration sees the Microsoft DLLs")
    func overridesPrecedeRegistration() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let (prefix, package) = try fixture(tmp)
        let fake = FakeProcessRunner()

        try await MediaFoundationInstaller(runner: fake)
            .install(package: package, intoPrefix: prefix, wine: wine)

        let overrideIndex = try #require(
            fake.invocations.firstIndex { $0.arguments.contains("C:\\silo-mf-overrides.reg") })
        let firstRegsvr = try #require(
            fake.invocations.firstIndex { $0.arguments.contains("colorcnv.dll") })
        #expect(overrideIndex < firstRegsvr)
    }

    @Test("Reports progress through every stage, ending in .done")
    func reportsProgress() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let (prefix, package) = try fixture(tmp)
        let box = StageBox()

        try await MediaFoundationInstaller(runner: FakeProcessRunner())
            .install(package: package, intoPrefix: prefix, wine: wine) { box.append($0) }

        #expect(box.stages == [.copyingDLLs, .writingOverrides, .importingRegistry,
                               .registeringComponents, .done])
    }

    @Test("Marks the prefix so callers can tell it's already set up")
    func marksPrefix() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let (prefix, package) = try fixture(tmp)
        #expect(!MediaFoundationInstaller.isInstalled(inPrefix: prefix))

        try await MediaFoundationInstaller(runner: FakeProcessRunner())
            .install(package: package, intoPrefix: prefix, wine: wine)

        #expect(MediaFoundationInstaller.isInstalled(inPrefix: prefix))
    }

    @Test("A failing wine step aborts, names the step, and leaves no marker")
    func failedStepAborts() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let (prefix, package) = try fixture(tmp)
        let fake = FakeProcessRunner()
        fake.queueResult(ProcessResult(exitCode: 0))                                    // overrides
        fake.queueResult(ProcessResult(exitCode: 5, standardError: Data("boom".utf8)))   // mf.reg 64-bit

        await #expect(throws: MediaFoundationInstaller.InstallError.stepFailed(
            step: "registry import (mf.reg)", status: 5, stderr: "boom")) {
            try await MediaFoundationInstaller(runner: fake)
                .install(package: package, intoPrefix: prefix, wine: wine)
        }
        #expect(!MediaFoundationInstaller.isInstalled(inPrefix: prefix))
    }

    @Test("Refuses a directory that isn't a Wine prefix")
    func refusesNonPrefix() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let (_, package) = try fixture(tmp)
        let notAPrefix = try tmp.makeDir("nope")

        await #expect(throws: MediaFoundationInstaller.InstallError.prefixMissing(notAPrefix)) {
            try await MediaFoundationInstaller(runner: FakeProcessRunner())
                .install(package: package, intoPrefix: notAPrefix, wine: wine)
        }
    }

    /// Captures a string from a `@Sendable` callback.
    private final class TextBox: @unchecked Sendable {
        private let lock = NSLock()
        private var _value: String?
        var value: String? {
            get { lock.withLock { _value } }
            set { lock.withLock { _value = newValue } }
        }
    }

    /// Collects progress callbacks from the installer's `@Sendable` closure.
    private final class StageBox: @unchecked Sendable {
        private let lock = NSLock()
        private var _stages: [MediaFoundationInstaller.Stage] = []
        var stages: [MediaFoundationInstaller.Stage] { lock.withLock { _stages } }
        func append(_ stage: MediaFoundationInstaller.Stage) { lock.withLock { _stages.append(stage) } }
    }
}
