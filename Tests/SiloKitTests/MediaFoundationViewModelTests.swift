import Foundation
import Testing
@testable import SiloKit

@Suite("MediaFoundationViewModel")
@MainActor
struct MediaFoundationViewModelTests {

    private func makeVM(_ tmp: TempDir, _ fake: FakeProcessRunner,
                        wine wineBinary: URL? = URL(fileURLWithPath: "/w/bin/wine64"))
        -> (MediaFoundationViewModel, AppPaths) {
        let paths = AppPaths(supportDir: tmp.url.appendingPathComponent("Silo"))
        let vm = MediaFoundationViewModel(
            importer: MediaFoundationImporter(paths: paths),
            cloner: BottleCloner(runner: fake),
            installer: MediaFoundationInstaller(runner: fake),
            paths: paths,
            configStore: ConfigStore(paths: paths),
            wineBinary: { wineBinary })
        return (vm, paths)
    }

    /// A folder shaped like a real MF package.
    @discardableResult
    private func makePackageFolder(_ tmp: TempDir, named name: String = "mf-src") throws -> URL {
        for dir in ["system32", "syswow64"] {
            try tmp.makeDir("\(name)/\(dir)")
            for dll in MediaFoundationPackage.dllNames { try tmp.write("\(name)/\(dir)/\(dll).dll", "PE") }
        }
        try tmp.write("\(name)/mf.reg", "REGEDIT4")
        try tmp.write("\(name)/wmf.reg", "REGEDIT5")
        return tmp.url.appendingPathComponent(name)
    }

    /// A Steam bottle to clone from. The clone is faked, so the destination is created here too —
    /// `/bin/cp` never actually runs under FakeProcessRunner.
    private func makeSteamBottle(_ tmp: TempDir, _ paths: AppPaths, _ fake: FakeProcessRunner) throws {
        try FileManager.default.createDirectory(
            at: paths.steamBottle.appendingPathComponent("drive_c/windows/system32"),
            withIntermediateDirectories: true)
        fake.onRun = { inv in
            guard inv.executable.path == "/bin/cp" else { return }
            try? FileManager.default.createDirectory(
                at: paths.steamBottleMF.appendingPathComponent("drive_c/windows/system32"),
                withIntermediateDirectories: true)
            try? FileManager.default.createDirectory(
                at: paths.steamBottleMF.appendingPathComponent("drive_c/windows/syswow64"),
                withIntermediateDirectories: true)
        }
    }

    @Test("Starts with no package and no bottle")
    func startsEmpty() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let (vm, _) = makeVM(tmp, FakeProcessRunner())
        vm.refresh()
        #expect(vm.package == nil)
        #expect(!vm.bottleReady)
        #expect(!vm.canBuildBottle)
    }

    @Test("Importing a valid folder makes the package available")
    func importsPackage() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let (vm, _) = makeVM(tmp, FakeProcessRunner())
        await vm.importPackage(from: try makePackageFolder(tmp))
        #expect(vm.package != nil)
        #expect(vm.statusMessage?.contains("imported") == true)
    }

    @Test("A wrong folder is rejected with a message naming what's missing")
    func rejectsWrongFolder() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let (vm, _) = makeVM(tmp, FakeProcessRunner())
        let empty = try tmp.makeDir("not-a-package")

        await vm.importPackage(from: empty)

        #expect(vm.package == nil)
        let message = try #require(vm.statusMessage)
        #expect(message.contains("system32/"))
        #expect(message.contains("mf.reg"))
    }

    @Test("Can't build the bottle without a package, even with a Steam bottle present")
    func needsPackageToBuild() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let fake = FakeProcessRunner()
        let (vm, paths) = makeVM(tmp, fake)
        try makeSteamBottle(tmp, paths, fake)
        vm.refresh()
        #expect(!vm.canBuildBottle)
    }

    @Test("Can't build the bottle without a Steam bottle to copy")
    func needsSteamBottleToBuild() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let (vm, _) = makeVM(tmp, FakeProcessRunner())
        await vm.importPackage(from: try makePackageFolder(tmp))

        #expect(!vm.canBuildBottle)
        await vm.buildBottle()
        #expect(vm.statusMessage?.contains("Steam bottle") == true)
    }

    @Test("Building clones the Steam bottle and applies the recipe to the copy")
    func buildsBottle() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let fake = FakeProcessRunner()
        let (vm, paths) = makeVM(tmp, fake)
        try makeSteamBottle(tmp, paths, fake)
        await vm.importPackage(from: try makePackageFolder(tmp))
        #expect(vm.canBuildBottle)

        await vm.buildBottle()

        #expect(vm.bottleReady)
        #expect(!vm.canBuildBottle)   // nothing left to build
        #expect(MediaFoundationInstaller.isInstalled(inPrefix: paths.steamBottleMF))
        // Cloned from the Steam bottle, and the recipe ran against the COPY, not the original.
        let cp = try #require(fake.invocations.first { $0.executable.path == "/bin/cp" })
        #expect(cp.arguments.contains(paths.steamBottle.path))
        #expect(cp.arguments.contains(paths.steamBottleMF.path))
        #expect(!MediaFoundationInstaller.isInstalled(inPrefix: paths.steamBottle))
    }

    @Test("Without a configured wine, building refuses and says so")
    func needsWine() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let fake = FakeProcessRunner()
        let (vm, paths) = makeVM(tmp, fake, wine: nil)
        try makeSteamBottle(tmp, paths, fake)
        await vm.importPackage(from: try makePackageFolder(tmp))

        await vm.buildBottle()

        #expect(!vm.bottleReady)
        #expect(vm.statusMessage?.contains("Wine") == true)
    }

    @Test("A failed recipe removes the half-built clone rather than leaving a lookalike bottle")
    func failedBuildCleansUp() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let fake = FakeProcessRunner()
        let (vm, paths) = makeVM(tmp, fake)
        try makeSteamBottle(tmp, paths, fake)
        await vm.importPackage(from: try makePackageFolder(tmp))
        fake.queueResult(ProcessResult(exitCode: 0))   // the clone
        fake.queueResult(ProcessResult(exitCode: 0))   // overrides
        fake.queueResult(ProcessResult(exitCode: 9))   // mf.reg import fails

        await vm.buildBottle()

        #expect(!vm.bottleReady)
        // A bottle that was copied but never got the recipe would silently behave like the normal one.
        #expect(!FileManager.default.fileExists(atPath: paths.steamBottleMF.path))
        #expect(vm.statusMessage?.contains("registry import") == true)
    }

    @Test("Removing the bottle clears it and lets it be rebuilt")
    func removesBottle() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let fake = FakeProcessRunner()
        let (vm, paths) = makeVM(tmp, fake)
        try makeSteamBottle(tmp, paths, fake)
        await vm.importPackage(from: try makePackageFolder(tmp))
        await vm.buildBottle()
        #expect(vm.bottleReady)

        await vm.removeBottle()

        #expect(!vm.bottleReady)
        #expect(!FileManager.default.fileExists(atPath: paths.steamBottleMF.path))
        #expect(vm.canBuildBottle)
    }

    @Test("Removing the bottle turns the flag off on every game")
    func removingBottleClearsGameFlags() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let fake = FakeProcessRunner()
        let (vm, paths) = makeVM(tmp, fake)
        let store = ConfigStore(paths: paths)
        try makeSteamBottle(tmp, paths, fake)
        await vm.importPackage(from: try makePackageFolder(tmp))
        await vm.buildBottle()
        // Two games opted in, one didn't.
        try await store.updateGame(appID: 220) { $0.envFlags.mediaFoundationNative = true }
        try await store.updateGame(appID: 440) { $0.envFlags.mediaFoundationNative = true }
        try await store.updateGame(appID: 550) { $0.envFlags.mediaFoundationNative = false }

        await vm.removeBottle()

        // Otherwise those games would point at a bottle that's gone, with the toggle hidden — no way
        // for the user to turn it off again.
        let state = await store.load()
        #expect(state.games.allSatisfy { !$0.envFlags.mediaFoundationNative })
        #expect(state.games.count == 3)   // nothing was dropped, only the flag changed
    }

    @Test("Removing the package leaves an already-built bottle working")
    func removingPackageKeepsBottle() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let fake = FakeProcessRunner()
        let (vm, paths) = makeVM(tmp, fake)
        try makeSteamBottle(tmp, paths, fake)
        await vm.importPackage(from: try makePackageFolder(tmp))
        await vm.buildBottle()

        vm.removePackage()

        #expect(vm.package == nil)
        #expect(vm.bottleReady)   // the DLLs live in the bottle now, not in the package folder
    }
}
