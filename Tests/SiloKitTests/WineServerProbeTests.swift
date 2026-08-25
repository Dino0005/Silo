import Foundation
import Testing
@testable import SiloKit

@Suite("WineServerProbe")
struct WineServerProbeTests {

    @Test("serverDirName matches wine's hex dev-inode naming for a real dir")
    func serverDirNameFormat() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let name = try #require(WineServerProbe.serverDirName(for: tmp.url))
        #expect(name.hasPrefix("server-"))
        // Independently stat the dir and reconstruct the expected name.
        var st = stat()
        #expect(stat(tmp.url.path, &st) == 0)
        let expected = "server-\(String(UInt64(bitPattern: Int64(st.st_dev)), radix: 16))"
            + "-\(String(st.st_ino, radix: 16))"
        #expect(name == expected)
    }

    @Test("serverDirName is nil for a nonexistent prefix (a not-yet-created bottle is never live)")
    func serverDirNameNilForMissing() {
        #expect(WineServerProbe.serverDirName(
            for: URL(fileURLWithPath: "/no/such/prefix-\(UUID().uuidString)")) == nil)
    }

    @Test("isLive is true only while the wineserver socket exists")
    func isLiveTracksSocket() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let prefix = tmp.url.appendingPathComponent("SteamBottle")
        try FileManager.default.createDirectory(at: prefix, withIntermediateDirectories: true)
        #expect(!WineServerProbe.isLive(prefix: prefix))          // no server yet
        let remove = try makeWineServerSocket(for: prefix)
        #expect(WineServerProbe.isLive(prefix: prefix))           // socket present → live
        remove()
        #expect(!WineServerProbe.isLive(prefix: prefix))          // socket gone → not live
    }

    @Test("files left behind by a KILLED wineserver are not a live bottle")
    func leftoverFilesAreNotLive() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let prefix = tmp.url.appendingPathComponent("SteamBottle")
        let held = try holdWineServerLock(for: prefix)
        defer { held.release() }
        #expect(WineServerProbe.isLive(prefix: prefix))

        // Exactly what `kill -9` leaves: nobody holds the lock any more, but lock and socket are still on
        // disk. Before this the bottle read live forever and every launch was silently refused.
        held.unlock()
        let dir = try #require(held.dir)
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("socket").path))
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("lock").path))
        #expect(!WineServerProbe.isLive(prefix: prefix))
    }

    @Test("a lock nobody holds reads as free; an unopenable one is assumed live")
    func lockProbeAnswers() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let path = tmp.url.appendingPathComponent("lock").path
        FileManager.default.createFile(atPath: path, contents: Data())
        #expect(!WineServerProbe.isLockHeld(at: path))
        // Can't ask → the safe answer is "live", never "go ahead and move the prefix".
        #expect(WineServerProbe.isLockHeld(at: tmp.url.appendingPathComponent("absent").path))
    }

    @Test("a socket without a held lock isn't live, and neither is a held lock without a socket")
    func bothPiecesAreRequired() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let prefix = tmp.url.appendingPathComponent("SteamBottle")
        let held = try holdWineServerLock(for: prefix)
        defer { held.release() }
        let dir = try #require(held.dir)

        // A server that lost its socket isn't reachable, however firmly it holds its lock.
        try FileManager.default.removeItem(at: dir.appendingPathComponent("socket"))
        #expect(!WineServerProbe.isLive(prefix: prefix))
    }

    @Test("the sweep removes an unheld leftover and spares a directory whose lock is held")
    func sweepRemovesOnlyLeftovers() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        // Two prefixes: one with a live holder, one whose holder has gone.
        let live = tmp.url.appendingPathComponent("LiveBottle")
        let dead = tmp.url.appendingPathComponent("DeadBottle")
        let held = try holdWineServerLock(for: live)
        defer { held.release() }
        let leftover = try holdWineServerLock(for: dead)
        defer { leftover.release() }
        leftover.unlock()                      // exactly what a killed wineserver leaves

        #expect(WineServerProbe.isLive(prefix: live))
        #expect(!WineServerProbe.isLive(prefix: dead))

        // Both are backdated past the grace period, so the sweep's decision rests on the lock alone —
        // which is the behaviour worth testing. A freshly-made directory is spared whatever its lock says.
        try backdate(try #require(held.dir))
        try backdate(try #require(leftover.dir))
        WineServerProbe.sweepLeftovers()

        // The dead one's directory is gone; the live one's is untouched — someone is still using it.
        #expect(!FileManager.default.fileExists(atPath: try #require(leftover.dir).path))
        #expect(FileManager.default.fileExists(atPath: try #require(held.dir).path))
        #expect(WineServerProbe.isLive(prefix: live))     // and it still reads as live afterwards
    }

    @Test("a directory with no lock file at all is swept — a live server always has one")
    func sweepRemovesLocklessDirectory() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let prefix = tmp.url.appendingPathComponent("Bottle")
        let leftover = try holdWineServerLock(for: prefix)
        defer { leftover.release() }
        leftover.unlock()
        let dir = try #require(leftover.dir)
        try FileManager.default.removeItem(at: dir.appendingPathComponent("lock"))

        try backdate(dir)
        WineServerProbe.sweepLeftovers()
        #expect(!FileManager.default.fileExists(atPath: dir.path))
    }

    @Test("a directory made moments ago is spared even with nobody holding its lock")
    func sweepSparesYoungDirectory() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let prefix = tmp.url.appendingPathComponent("Starting")
        let starting = try holdWineServerLock(for: prefix)
        defer { starting.release() }
        starting.unlock()          // the window between creating the dir and taking the lock

        WineServerProbe.sweepLeftovers()      // no backdating: it's seconds old
        #expect(FileManager.default.fileExists(atPath: try #require(starting.dir).path))
    }

    /// Push a directory's modification date past the sweep's grace period.
    private func backdate(_ dir: URL, by seconds: TimeInterval = 3600) throws {
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-seconds)], ofItemAtPath: dir.path)
    }

    @Test("isAnyBottleLive spots a live manual bottle, and reports false when all are quiet")
    func anyBottleLive() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let paths = AppPaths(supportDir: tmp.url.appendingPathComponent("Silo"))
        #expect(!WineServerProbe.isAnyBottleLive(paths: paths))
        let remove = try makeWineServerSocket(for: paths.manualBottle(UUID()))
        defer { remove() }
        #expect(WineServerProbe.isAnyBottleLive(paths: paths))
    }
}
