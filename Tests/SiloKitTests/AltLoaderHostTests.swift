import Foundation
import Testing
@testable import SiloKit

/// `AltLoaderHost` — finding the helper that `build-app.sh` installs in the app bundle. Runs with no
/// app bundle and no Wine.
struct AltLoaderHostTests {

    private func tempDir() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("silo-altloader-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeHost(in appBundle: URL, executable: Bool = true) throws -> URL {
        let helpers = appBundle.appendingPathComponent("Contents/Helpers", isDirectory: true)
        try FileManager.default.createDirectory(at: helpers, withIntermediateDirectories: true)
        let host = helpers.appendingPathComponent("SiloWineHost")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: host)
        try FileManager.default.setAttributes(
            [.posixPermissions: executable ? 0o755 : 0o644], ofItemAtPath: host.path)
        return host
    }

    @Test func findsTheHostInsideAnAssembledBundle() throws {
        let root = try tempDir(); defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("Silo.app", isDirectory: true)
        let host = try makeHost(in: app)
        #expect(AltLoaderHost.url(inAppBundle: app)?.path == host.path)
    }

    /// A dev build has no `.app`, and that must read as "not available" rather than a broken path —
    /// the caller then launches the old way and the game still runs.
    @Test func missingHostIsNilNotAGuess() throws {
        let root = try tempDir(); defer { try? FileManager.default.removeItem(at: root) }
        #expect(AltLoaderHost.url(inAppBundle: root.appendingPathComponent("Silo.app")) == nil)
    }

    /// Present but not executable is useless — LaunchServices couldn't start it.
    @Test func nonExecutableHostIsRejected() throws {
        let root = try tempDir(); defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("Silo.app", isDirectory: true)
        _ = try makeHost(in: app, executable: false)
        #expect(AltLoaderHost.url(inAppBundle: app) == nil)
    }

    @Test func environmentOverrideWins() throws {
        let root = try tempDir(); defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("Silo.app", isDirectory: true)
        let host = try makeHost(in: app)
        #expect(AltLoaderHost.resolved(environment: ["SILO_ALTLOADER_HOST": host.path])?.path == host.path)
    }

    @Test func environmentOverridePointingNowhereIsNil() {
        #expect(AltLoaderHost.resolved(environment: ["SILO_ALTLOADER_HOST": "/nope/SiloWineHost"]) == nil)
    }

    @Test func emptyOverrideFallsBackInsteadOfFailing() throws {
        // empty value must not be treated as a path; falls through to the bundle lookup (nil in tests)
        #expect(AltLoaderHost.resolved(environment: ["SILO_ALTLOADER_HOST": ""]) == nil)
    }
}
