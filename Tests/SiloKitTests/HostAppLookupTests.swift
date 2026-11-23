import Foundation
import Testing
@testable import SiloKit

@Suite("HostAppLookup")
struct HostAppLookupTests {

    private func makeDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("silo-hostapps-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("Finds the .app in the game's folder")
    func finds() throws {
        let root = try makeDir()
        let app = root.appendingPathComponent("1778820/TEKKEN 8.app/Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        try Data().write(to: root.appendingPathComponent("1778820/socket"))
        #expect(HostAppLookup.bundle(forID: "1778820", in: root)?.lastPathComponent == "TEKKEN 8.app")
    }

    @Test("Nil for a game never launched, or a folder with no .app")
    func missing() throws {
        let root = try makeDir()
        try FileManager.default.createDirectory(at: root.appendingPathComponent("42"),
                                                withIntermediateDirectories: true)
        #expect(HostAppLookup.bundle(forID: "42", in: root) == nil)
        #expect(HostAppLookup.bundle(forID: "7", in: root) == nil)
    }

    @Test("The library icon: the host app first, else the game app Steam for macOS starts the game through")
    func iconBundle() throws {
        let host = try makeDir(), games = try makeDir()
        let fm = FileManager.default
        try fm.createDirectory(at: games.appendingPathComponent("2651280/Marvel's Spider-Man 2.app/Contents"),
                               withIntermediateDirectories: true)
        // Only ever started from Steam for macOS: the game app.
        #expect(HostAppLookup.iconBundle(forID: "2651280", hostAppsDir: host, gameAppsDir: games)?
            .lastPathComponent == "Marvel's Spider-Man 2.app")
        // Both: the host app.
        try fm.createDirectory(at: host.appendingPathComponent("2651280/Spider-Man2.app/Contents"),
                               withIntermediateDirectories: true)
        #expect(HostAppLookup.iconBundle(forID: "2651280", hostAppsDir: host, gameAppsDir: games)?
            .lastPathComponent == "Spider-Man2.app")
        // Neither.
        #expect(HostAppLookup.iconBundle(forID: "7", hostAppsDir: host, gameAppsDir: games) == nil)
    }
}
