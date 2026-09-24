import Foundation
import Testing
@testable import SiloKit

/// `AltLoaderSession` — the launch-time wiring that hands a game's process to Silo's bundled host so
/// its window carries the game's icon. Runs with no Wine: the fake runner records what would have been
/// executed.
struct AltLoaderSessionTests {
    private let wine = URL(fileURLWithPath: "/rt/bin/wine64")
    private let gameExe = URL(fileURLWithPath: #"C:\windows\system32\notepad.exe"#)

    /// Deliberately a **short** root, under `/tmp` rather than the per-user `TMPDIR`: the hand-over
    /// socket has to fit in `sun_path` (103 bytes), and `TMPDIR` alone eats 49 of them. Production has
    /// the same budget — it just doesn't add a test directory on top.
    private func tempDir() throws -> URL {
        let url = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("sa-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// An executable host, as `build-app.sh` installs it.
    private func fakeHost(in dir: URL) throws -> URL {
        let host = dir.appendingPathComponent("SiloWineHost")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: host)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: host.path)
        return host
    }

    /// A real prefix directory: `applyRegistry` writes the `.reg` into `drive_c`, so a made-up
    /// absolute path would make every call fail for the wrong reason.
    private func makePrefix(in root: URL) throws -> URL {
        let prefix = root.appendingPathComponent("SteamBottle", isDirectory: true)
        try FileManager.default.createDirectory(
            at: prefix.appendingPathComponent("drive_c"), withIntermediateDirectories: true)
        return prefix
    }

    private func prepare(
        runner: FakeProcessRunner, root: URL, prefix: URL, host: URL?, disable: Bool = false
    ) async -> URL? {
        var env: [String: String] = [:]
        if let host { env["SILO_ALTLOADER_HOST"] = host.path }
        if disable { env[AltLoaderSession.disableFlag] = "1" }
        // `socketWaitTimeout: .zero` = don't wait for a bind: no real host binds in a unit test.
        return await AltLoaderSession(runner: runner, environment: env, temporaryDirectory: root,
                                      socketWaitTimeout: .zero).prepare(
            gameName: "Blocco Note", gameID: "220", gameExe: gameExe, iconICO: nil,
            prefix: prefix, wine: wine,
            hostAppsDir: root.appendingPathComponent("HostApps", isDirectory: true))
    }

    // MARK: - Degrading to the old launch path

    /// A `swift run` dev build has no host in the bundle. That must read as "launch the old way", with
    /// nothing executed — the icon is cosmetic and must never block a game.
    @Test func withoutAHostItDoesNothingAtAll() async throws {
        let root = try tempDir(); defer { try? FileManager.default.removeItem(at: root) }
        let runner = FakeProcessRunner()
        #expect(await prepare(runner: runner, root: root, prefix: try makePrefix(in: root), host: nil) == nil)
        #expect(runner.invocations.isEmpty)
    }

    /// The global escape hatch: one flag disables the whole mechanism, and it must short-circuit before
    /// touching the prefix or the registry.
    @Test func disableFlagShortCircuitsBeforeAnySideEffect() async throws {
        let root = try tempDir(); defer { try? FileManager.default.removeItem(at: root) }
        let host = try fakeHost(in: root)
        let runner = FakeProcessRunner()
        #expect(await prepare(runner: runner, root: root, prefix: try makePrefix(in: root), host: host, disable: true) == nil)
        #expect(runner.invocations.isEmpty)
    }

    // MARK: - The happy path

    @Test func preparesTheWhitelistThenLaunchesTheBundleAndReturnsTheSocket() async throws {
        let root = try tempDir(); defer { try? FileManager.default.removeItem(at: root) }
        let host = try fakeHost(in: root)
        let runner = FakeProcessRunner()

        let prefix = try makePrefix(in: root)
        let socket = try #require(await prepare(runner: runner, root: root, prefix: prefix, host: host))

        #expect(socket.lastPathComponent.hasPrefix("silo-al-220-"))
        #expect(runner.invocations.count == 2)

        // 1) the registry gate, imported in one `wine regedit /S` like applyWineDefaults does
        let reg = runner.invocations[0]
        #expect(reg.executable == wine)
        #expect(reg.arguments == ["regedit", "/S", "C:\\silo-altloader.reg"])
        #expect(reg.environment["WINEPREFIX"] == prefix.path)

        // 2) the bundle started through LaunchServices — launching the executable directly does not work
        let open = runner.invocations[1]
        #expect(open.executable.path == "/usr/bin/open")
        // `-n`: a still-running instance of the same game must not swallow the launch (see the note in
        // `prepare`) — LaunchServices would activate it instead of binding the new socket.
        #expect(open.arguments.first == "-n")
        #expect(open.arguments[1] == "-a")
        #expect(open.arguments[2].hasSuffix("220/Blocco Note.app"))
        #expect(open.arguments[3] == "--args")
        #expect(open.arguments[4] == socket.path)
    }

    /// The host really is installed in the per-game bundle, so LaunchServices has something to start.
    @Test func theBundleEndsUpCarryingTheHost() async throws {
        let root = try tempDir(); defer { try? FileManager.default.removeItem(at: root) }
        let host = try fakeHost(in: root)
        _ = await prepare(runner: FakeProcessRunner(), root: root,
                          prefix: try makePrefix(in: root), host: host)
        let installed = root.appendingPathComponent(
            "HostApps/220/Blocco Note.app/Contents/MacOS/SiloGameHost")
        #expect(FileManager.default.isExecutableFile(atPath: installed.path))
    }

    /// Wine matches on the exe's **base** name, so that is what must be written. Getting this wrong is
    /// how the host ended up adopting `wineboot` instead of the game.
    @Test func theWhitelistNamesTheExeBaseName() async throws {
        let root = try tempDir(); defer { try? FileManager.default.removeItem(at: root) }
        let host = try fakeHost(in: root)
        let prefix = try makePrefix(in: root)
        let written = LockedBox("")
        let runner = FakeProcessRunner()
        let regFile = prefix.appendingPathComponent("drive_c/silo-altloader.reg")
        runner.onRun = { inv in
            guard inv.arguments.first == "regedit" else { return }
            // the .reg is deleted after the import, so capture it while the call is in flight
            written.set((try? String(contentsOf: regFile, encoding: .utf8)) ?? "")
        }
        _ = await prepare(runner: runner, root: root, prefix: prefix, host: host)
        #expect(written.value.contains("\"notepad\"=\"1\""))
        #expect(!written.value.contains("notepad.exe"))
    }

    // MARK: - Failure leaves nothing behind

    /// If `open` fails the launch must fall back — and the whitelist key must not be left in the
    /// prefix, because an `UseAltLoader` that lists nothing excludes *every* exe from the alt loader.
    @Test func aFailedOpenReturnsNilAndRemovesTheWhitelist() async throws {
        let root = try tempDir(); defer { try? FileManager.default.removeItem(at: root) }
        let host = try fakeHost(in: root)
        let runner = FakeProcessRunner()
        runner.queueResult(ProcessResult(exitCode: 0))    // regedit succeeds
        runner.queueResult(ProcessResult(exitCode: 1))    // open fails

        #expect(await prepare(runner: runner, root: root,
                              prefix: try makePrefix(in: root), host: host) == nil)
        // a third call must have happened: the cleanup import
        #expect(runner.invocations.count == 3)
        #expect(runner.invocations[2].arguments == ["regedit", "/S", "C:\\silo-altloader-off.reg"])
    }

    /// A registry import that fails stops the sequence: no point launching a host Wine will never talk to.
    @Test func aFailedRegistryImportStopsBeforeLaunching() async throws {
        let root = try tempDir(); defer { try? FileManager.default.removeItem(at: root) }
        let host = try fakeHost(in: root)
        let runner = FakeProcessRunner()
        runner.queueResult(ProcessResult(exitCode: 1))    // regedit fails

        #expect(await prepare(runner: runner, root: root,
                              prefix: try makePrefix(in: root), host: host) == nil)
        #expect(runner.invocations.count == 1)            // nothing was opened
    }

    // MARK: - cleanup

    @Test func cleanupDeletesTheKeyRatherThanEmptyingIt() async throws {
        let root = try tempDir(); defer { try? FileManager.default.removeItem(at: root) }
        let prefix = try makePrefix(in: root)
        let runner = FakeProcessRunner()
        let written = LockedBox("")
        let regFile = prefix.appendingPathComponent("drive_c/silo-altloader-off.reg")
        runner.onRun = { _ in
            written.set((try? String(contentsOf: regFile, encoding: .utf8)) ?? "")
        }
        await AltLoaderSession(runner: runner).cleanup(prefix: prefix, wine: wine)
        #expect(written.value.contains("[-HKEY_CURRENT_USER\\Software\\CrossOver\\UseAltLoader]"))
    }

    // MARK: - Socket paths

    /// One socket per game, so two launches can't collide; anything odd in the id is neutralised.
    @Test func socketPathIsPerGameAndSanitised() {
        let tmp = URL(fileURLWithPath: "/tmp", isDirectory: true)
        #expect(AltLoaderSession.socketPath(forGameID: "220", temporaryDirectory: tmp)
                != AltLoaderSession.socketPath(forGameID: "570", temporaryDirectory: tmp))
        let odd = AltLoaderSession.socketPath(forGameID: "a/b c", temporaryDirectory: tmp)
        #expect(odd.deletingLastPathComponent().path == "/tmp")
        #expect(odd.lastPathComponent.hasPrefix("silo-al-a-b-c-"))
        // Same id, same socket, on every launch — otherwise a second launch would talk past the host.
        #expect(AltLoaderSession.socketPath(forGameID: "220", temporaryDirectory: tmp)
                == AltLoaderSession.socketPath(forGameID: "220", temporaryDirectory: tmp))
        // Ids sharing a head still differ: the hash covers the whole id.
        #expect(AltLoaderSession.socketPath(forGameID: "BEEF0000-A", temporaryDirectory: tmp)
                != AltLoaderSession.socketPath(forGameID: "BEEF0000-B", temporaryDirectory: tmp))
    }

    /// The defect the first on-device run of the wired feature exposed (2026-09-24): `sun_path` holds
    /// 103 bytes and **truncates** silently past that, so the host binds a name the game never connects
    /// to. A manual game's 36-char UUID under the per-user `TMPDIR` overflowed the old name by 2 bytes.
    @Test func socketPathFitsSunPathEvenForAUUIDUnderTheRealTempDir() {
        let real = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let uuid = "BEEF0000-0000-4000-8000-000000000001"
        let path = AltLoaderSession.socketPath(forGameID: uuid, temporaryDirectory: real).path
        #expect(path.utf8.count <= AltLoaderSession.maxSocketPathLength)
        // And the old shape really did not fit — the bound that makes this test worth keeping.
        #expect(real.appendingPathComponent("silo-altloader-\(uuid).sock").path.utf8.count
                > AltLoaderSession.maxSocketPathLength)
    }

    /// If the path cannot fit anyway (a pathological temp dir), refuse rather than hand Wine a socket it
    /// will fail to reach — and leave no whitelist key behind.
    @Test func anOverLongSocketPathIsRefusedAndLeavesNoKey() async throws {
        let root = try tempDir(); defer { try? FileManager.default.removeItem(at: root) }
        let host = try fakeHost(in: root)
        let deep = root.appendingPathComponent(String(repeating: "d", count: 120), isDirectory: true)
        try FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true)
        let runner = FakeProcessRunner()

        let socket = await AltLoaderSession(
            runner: runner, environment: ["SILO_ALTLOADER_HOST": host.path],
            temporaryDirectory: deep, socketWaitTimeout: .zero
        ).prepare(gameName: "Blocco Note", gameID: "220", gameExe: gameExe, iconICO: nil,
                  prefix: try makePrefix(in: root), wine: wine,
                  hostAppsDir: root.appendingPathComponent("HostApps", isDirectory: true))

        #expect(socket == nil)
        #expect(!runner.invocations.contains { $0.executable.path == "/usr/bin/open" })
        #expect(runner.invocations.last?.arguments == ["regedit", "/S", "C:\\silo-altloader-off.reg"])
    }

    // MARK: - Waiting for the host to bind

    /// `open` returns before the host has bound, and the spawn follows within milliseconds: without the
    /// wait the game reaches `connect()` first, gets ENOENT and forks — no icon, no error (the second
    /// half of the 2026-09-24 finding). A host that does bind must be waited for, and found.
    @Test func prepareWaitsUntilTheHostHasBound() async throws {
        let root = try tempDir(); defer { try? FileManager.default.removeItem(at: root) }
        let host = try fakeHost(in: root)
        let runner = FakeProcessRunner()
        // Stand in for the host: create the socket file when `open` is called, as `bind` would.
        runner.onRun = { inv in
            guard inv.executable.path == "/usr/bin/open" else { return }
            try? Data().write(to: URL(fileURLWithPath: inv.arguments[4]))
        }
        let socket = await AltLoaderSession(
            runner: runner, environment: ["SILO_ALTLOADER_HOST": host.path],
            temporaryDirectory: root, socketWaitTimeout: .seconds(2)
        ).prepare(gameName: "Blocco Note", gameID: "220", gameExe: gameExe, iconICO: nil,
                  prefix: try makePrefix(in: root), wine: wine,
                  hostAppsDir: root.appendingPathComponent("HostApps", isDirectory: true))
        #expect(socket != nil)
    }

    /// A socket left behind by an earlier run must be removed before the host starts — otherwise the
    /// wait below finds *that* file, the game connects to a socket nobody accepts on, and it hangs
    /// (measured on God of War, 2026-09-24). The stale file must not survive the attempt either.
    @Test func aStaleSocketIsRemovedSoTheWaitMeansThisRun() async throws {
        let root = try tempDir(); defer { try? FileManager.default.removeItem(at: root) }
        let host = try fakeHost(in: root)
        let stale = AltLoaderSession.socketPath(forGameID: "220", temporaryDirectory: root)
        try Data("stantio".utf8).write(to: stale)

        let runner = FakeProcessRunner()
        let socket = await AltLoaderSession(
            runner: runner, environment: ["SILO_ALTLOADER_HOST": host.path],
            temporaryDirectory: root, socketWaitTimeout: .milliseconds(120)
        ).prepare(gameName: "Blocco Note", gameID: "220", gameExe: gameExe, iconICO: nil,
                  prefix: try makePrefix(in: root), wine: wine,
                  hostAppsDir: root.appendingPathComponent("HostApps", isDirectory: true))

        #expect(socket == nil)     // nothing bound in this run, so no hand-over
        #expect(!FileManager.default.fileExists(atPath: stale.path))
    }

    /// A host that never binds (crashed, refused by Gatekeeper) must degrade to the old launch path and
    /// remove the key — a game must never be held up by a cosmetic icon.
    @Test func aHostThatNeverBindsTimesOutAndCleansUp() async throws {
        let root = try tempDir(); defer { try? FileManager.default.removeItem(at: root) }
        let host = try fakeHost(in: root)
        let runner = FakeProcessRunner()
        let socket = await AltLoaderSession(
            runner: runner, environment: ["SILO_ALTLOADER_HOST": host.path],
            temporaryDirectory: root, socketWaitTimeout: .milliseconds(120)
        ).prepare(gameName: "Blocco Note", gameID: "220", gameExe: gameExe, iconICO: nil,
                  prefix: try makePrefix(in: root), wine: wine,
                  hostAppsDir: root.appendingPathComponent("HostApps", isDirectory: true))
        #expect(socket == nil)
        #expect(runner.invocations.last?.arguments == ["regedit", "/S", "C:\\silo-altloader-off.reg"])
    }
}
