import Foundation
import Testing
@testable import SiloKit

/// Stopping what runs in the bottles — the menu command, and the "close everything" branch of the quit
/// prompt. Both land on the same call.
@Suite("Stop bottle processes")
struct StopBottleProcessesTests {

    /// A wine runtime just complete enough for `WineRuntimeLayout` to find `bin/wineserver` beside it.
    private static func makeWine(_ tmp: TempDir) throws -> URL {
        try tmp.makeDir("wine/lib/wine/x86_64-windows")
        try tmp.write("wine/bin/wineserver", "#!/bin/sh")
        return try tmp.write("wine/bin/wine64", "#!/bin/sh")
    }

    @Test("a live bottle is asked to shut down with wineserver -k, and its prefix is the one named")
    func stopsLiveBottleWithWineserver() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let paths = AppPaths(supportDir: tmp.url)
        let fake = FakeProcessRunner()
        let env = await AppEnvironment(paths: paths, runner: fake)
        let wine = try Self.makeWine(tmp)
        await MainActor.run { env.backendSettings.config.wineBinaryPath = wine }

        try FileManager.default.createDirectory(at: paths.steamBottle, withIntermediateDirectories: true)
        let held = try holdWineServerLock(for: paths.steamBottle)
        defer { held.release() }

        let stopped = await env.stopBottleProcesses()
        #expect(stopped == 1)
        let call = try #require(fake.invocations.first)
        #expect(call.executable.lastPathComponent == "wineserver")
        #expect(call.arguments == ["-k"])
        // Named by prefix: -k acts on the session WINEPREFIX points at, so the wrong value stops the
        // wrong bottle.
        #expect(call.environment["WINEPREFIX"] == paths.steamBottle.path)
    }

    @Test("a quiet bottle is left alone — asking it to die would start a server just to stop it")
    func skipsQuietBottles() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let paths = AppPaths(supportDir: tmp.url)
        let fake = FakeProcessRunner()
        let env = await AppEnvironment(paths: paths, runner: fake)
        let wine = try Self.makeWine(tmp)
        await MainActor.run { env.backendSettings.config.wineBinaryPath = wine }
        try FileManager.default.createDirectory(at: paths.steamBottle, withIntermediateDirectories: true)

        let stopped = await env.stopBottleProcesses()
        #expect(stopped == 0)
        #expect(fake.invocations.isEmpty)
    }

    @Test("with no wine configured there is nothing to ask, and nothing is run")
    func noWineIsANoOp() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let fake = FakeProcessRunner()
        let env = await AppEnvironment(paths: AppPaths(supportDir: tmp.url), runner: fake)
        #expect(await env.stopBottleProcesses() == 0)
        #expect(fake.invocations.isEmpty)
    }
}
