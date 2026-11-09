import Foundation
import Testing
@testable import SiloKit

@Suite("NativeSteamShadow")
struct NativeSteamShadowTests {
    static func manifest(id: UInt32, dir: String, build: String = "100", updated: String = "1", depots: Bool = true,
                         size: Int64 = 1000, flags: Int = 4) -> String {
        """
        "AppState"
        {
        \t"appid"\t\t"\(id)"
        \t"name"\t\t"Game \(id)"
        \t"StateFlags"\t\t"\(flags)"
        \t"installdir"\t\t"\(dir)"
        \t"LastUpdated"\t\t"\(updated)"
        \t"SizeOnDisk"\t\t"\(size)"
        \t"buildid"\t\t"\(build)"
        \t"InstalledDepots"
        \t{
        \(depots ? "\t\t\"\(id + 1)\"\n\t\t{\n\t\t\t\"manifest\"\t\t\"42\"\n\t\t}" : "")
        \t}
        }
        """
    }

    /// A library with one installed Windows game (files + manifest).
    func library(_ tmp: TempDir) throws -> URL {
        let lib = try tmp.makeDir("Lib")
        try tmp.write("Lib/steamapps/appmanifest_10.acf", Self.manifest(id: 10, dir: "Game"))
        try tmp.write("Lib/steamapps/common/Game/game.exe", "EXE v1")
        try tmp.write("Lib/steamapps/common/Game/data/pak0", "PAK v1")
        return lib
    }

    func read(_ url: URL) throws -> String { try String(contentsOf: url, encoding: .utf8) }

    @Test("A healthy install gets a clone of its files and manifest; an unchanged build isn't redone")
    func createsOnce() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let lib = try library(tmp)
        let shadow = NativeSteamShadow(isSteamRunning: { false })
        #expect(shadow.sync(libraries: [lib], windowsGames: [10]) == [.created(10)])
        let dir = lib.appendingPathComponent(".silo-shadow/10")
        #expect(try read(dir.appendingPathComponent("files/data/pak0")) == "PAK v1")
        #expect(NativeSteamShadow.Manifest(text: try read(dir.appendingPathComponent("appmanifest.acf")))?.buildID == "100")
        #expect(shadow.sync(libraries: [lib], windowsGames: [10]).isEmpty)
    }

    @Test("Not a Windows game, Steam running, or mid-update: no shadow")
    func skips() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let lib = try library(tmp)
        #expect(NativeSteamShadow(isSteamRunning: { false }).sync(libraries: [lib], windowsGames: []).isEmpty)
        #expect(NativeSteamShadow(isSteamRunning: { true }).sync(libraries: [lib], windowsGames: [10]).isEmpty)
        try tmp.write("Lib/steamapps/appmanifest_10.acf", Self.manifest(id: 10, dir: "Game", flags: 6))
        #expect(NativeSteamShadow(isSteamRunning: { false }).sync(libraries: [lib], windowsGames: [10]).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: lib.appendingPathComponent(".silo-shadow/10").path))
    }

    @Test("After an update the shadow is rebuilt from the new files")
    func refreshesAfterUpdate() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let lib = try library(tmp)
        let shadow = NativeSteamShadow(isSteamRunning: { false })
        _ = shadow.sync(libraries: [lib], windowsGames: [10])
        try tmp.write("Lib/steamapps/common/Game/data/pak0", "PAK v2")
        try tmp.write("Lib/steamapps/appmanifest_10.acf", Self.manifest(id: 10, dir: "Game", build: "101", updated: "2"))
        #expect(shadow.sync(libraries: [lib], windowsGames: [10]) == [.refreshed(10)])
        #expect(try read(lib.appendingPathComponent(".silo-shadow/10/files/data/pak0")) == "PAK v2")
    }

    @Test("A wiped install (manifest kept, no depots, size 0, files gone) comes back from the shadow")
    func restoresWipe() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let lib = try library(tmp)
        let shadow = NativeSteamShadow(isSteamRunning: { false })
        _ = shadow.sync(libraries: [lib], windowsGames: [10])
        // What macOS Steam left on 2026-11-09: the folder with a stray file, the manifest emptied.
        let game = lib.appendingPathComponent("steamapps/common/Game")
        try FileManager.default.removeItem(at: game)
        try tmp.write("Lib/steamapps/common/Game/steam_appid.txt", "10")
        try tmp.write("Lib/steamapps/appmanifest_10.acf", Self.manifest(id: 10, dir: "Game", build: "102", depots: false, size: 0))

        #expect(shadow.sync(libraries: [lib], windowsGames: [10]) == [.restored(10)])
        #expect(try read(game.appendingPathComponent("game.exe")) == "EXE v1")
        #expect(try read(game.appendingPathComponent("data/pak0")) == "PAK v1")
        let restored = try #require(NativeSteamShadow.Manifest(text: try read(lib.appendingPathComponent("steamapps/appmanifest_10.acf"))))
        #expect(restored.buildID == "100" && restored.isHealthy)
        // The shadow is still there and still matches: the next pass does nothing.
        #expect(shadow.sync(libraries: [lib], windowsGames: [10]).isEmpty)
    }

    @Test("A first install still downloading (no depots yet, no shadow) is left alone")
    func ignoresFreshDownload() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let lib = try tmp.makeDir("Lib")
        try tmp.write("Lib/steamapps/appmanifest_20.acf", Self.manifest(id: 20, dir: "New", depots: false, size: 0, flags: 1026))
        #expect(NativeSteamShadow(isSteamRunning: { false }).sync(libraries: [lib], windowsGames: [20]).isEmpty)
    }

    @Test("An uninstalled game's shadow is deleted, giving its space back")
    func dropsOrphans() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let lib = try library(tmp)
        let shadow = NativeSteamShadow(isSteamRunning: { false })
        _ = shadow.sync(libraries: [lib], windowsGames: [10])
        try FileManager.default.removeItem(at: lib.appendingPathComponent("steamapps/appmanifest_10.acf"))
        #expect(shadow.sync(libraries: [lib], windowsGames: []) == [.removed(10)])
        #expect(!FileManager.default.fileExists(atPath: lib.appendingPathComponent(".silo-shadow/10").path))
    }

    @Test("A failing clone keeps the old shadow and reports the game")
    func cloneFailureKeepsOld() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let lib = try library(tmp)
        _ = NativeSteamShadow(isSteamRunning: { false }).sync(libraries: [lib], windowsGames: [10])
        try tmp.write("Lib/steamapps/appmanifest_10.acf", Self.manifest(id: 10, dir: "Game", build: "101", updated: "2"))
        let broken = NativeSteamShadow(isSteamRunning: { false }, clone: { _, _ in throw NativeSteamShadow.CloneError(errno: ENOTSUP) })
        let actions = broken.sync(libraries: [lib], windowsGames: [10])
        guard case .failed(10, _)? = actions.first else { Issue.record("expected a failure, got \(actions)"); return }
        #expect(try read(lib.appendingPathComponent(".silo-shadow/10/files/data/pak0")) == "PAK v1")
    }
}
