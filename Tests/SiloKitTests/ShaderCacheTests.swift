import Foundation
import Testing
@testable import SiloKit

/// `ShaderCache`: a game's Metal shader cache, its size, whether it is full, and clearing it on request.
@Suite("Shader cache")
struct ShaderCacheTests {
    /// `<root>/<prefix><id>/com.apple.metal/<gpu>/<name>` with `size` bytes (sparse, so a "full" file costs nothing).
    @discardableResult
    private func file(_ root: URL, _ prefix: String, _ id: String, _ name: String, size: Int64) throws -> URL {
        let dir = root.appendingPathComponent(prefix + id).appendingPathComponent("com.apple.metal/16777235_419")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(size))
        try handle.close()
        return url
    }

    @Test("Size counts both the host's and the game app's folders; another game's doesn't count")
    func status() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        try file(tmp.url, GameHostBundle.bundleIDPrefix, "1659420", "functions.data", size: 1_000)
        try file(tmp.url, GameHostBundle.gameAppIDPrefix, "1659420", "functions.data", size: 2_000)
        try file(tmp.url, GameHostBundle.gameAppIDPrefix, "1659420", "functions.list", size: 30)
        try file(tmp.url, GameHostBundle.gameAppIDPrefix, "1778820", "functions.data", size: 9_999)
        let s = ShaderCache.status(forID: "1659420", cacheRoot: tmp.url)
        #expect(s.bytes == 3_030)
        #expect(s.silo.bytes == 1_000 && s.steam.bytes == 2_030)
        #expect(s.present == [.steam, .silo])
        #expect(!s.isFull)
        #expect(ShaderCache.status(forID: "7", cacheRoot: tmp.url) == .empty)
    }

    @Test("A functions.data at Metal's cap reads as full")
    func full() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        try file(tmp.url, GameHostBundle.gameAppIDPrefix, "1659420", "functions.data", size: ShaderCache.metalFileCap)
        try file(tmp.url, GameHostBundle.bundleIDPrefix, "1659420", "functions.data", size: 10)
        let s = ShaderCache.status(forID: "1659420", cacheRoot: tmp.url)
        #expect(s.isFull)
        #expect(s.steam.isFull && !s.silo.isFull)   // the warning goes on the right row
    }

    @Test("Clearing removes both folders and reports what it freed; then there is nothing to clear")
    func clear() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        try file(tmp.url, GameHostBundle.bundleIDPrefix, "1659420", "functions.data", size: 500)
        try file(tmp.url, GameHostBundle.gameAppIDPrefix, "1659420", "functions.data", size: 700)
        let other = try file(tmp.url, GameHostBundle.gameAppIDPrefix, "1778820", "functions.data", size: 10)
        #expect(ShaderCache.clear(forID: "1659420", cacheRoot: tmp.url) == .cleared(freed: 1_200))
        #expect(ShaderCache.status(forID: "1659420", cacheRoot: tmp.url) == .empty)
        #expect(FileManager.default.fileExists(atPath: other.path))   // another game's cache is untouched
        #expect(ShaderCache.clear(forID: "1659420", cacheRoot: tmp.url) == .nothingToClear)
    }

    @Test("A cache file Metal holds (the game running) is never removed")
    func inUse() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let data = try file(tmp.url, GameHostBundle.gameAppIDPrefix, "1659420", "functions.data", size: 100)
        let fd = open(data.path, O_RDONLY)
        #expect(fd >= 0)
        defer { close(fd) }
        #expect(flock(fd, LOCK_EX) == 0)
        #expect(ShaderCache.clear(forID: "1659420", cacheRoot: tmp.url) == .inUse)
        #expect(FileManager.default.fileExists(atPath: data.path))
    }

    @Test("A manual game's UUID maps to the same bundle-safe folder names Silo gives its apps")
    func manualGameID() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let id = "538C9332-8799-4259-8C93-7F8E43B4CBA7"
        try file(tmp.url, GameHostBundle.bundleIDPrefix, GameHostBundle.bundleSafe(id), "functions.data", size: 42)
        #expect(ShaderCache.status(forID: id, cacheRoot: tmp.url).bytes == 42)
    }

    @Test("A manual game has only Silo's cache: a game-app folder of one (a migration leftover) is not listed or cleared")
    func manualGameHasNoSteamCache() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let id = "538C9332-8799-4259-8C93-7F8E43B4CBA7"
        try file(tmp.url, GameHostBundle.bundleIDPrefix, id, "functions.data", size: 42)
        let leftover = try file(tmp.url, GameHostBundle.gameAppIDPrefix, id, "functions.data", size: 42)
        #expect(ShaderCache.kinds(forID: id) == [.silo])
        #expect(ShaderCache.kinds(forID: "1659420") == ShaderCache.Kind.allCases)
        let s = ShaderCache.status(forID: id, cacheRoot: tmp.url)
        #expect(s.present == [.silo] && s.bytes == 42)
        #expect(ShaderCache.clear(forID: id, cacheRoot: tmp.url) == .cleared(freed: 42))
        #expect(FileManager.default.fileExists(atPath: leftover.path))
    }

    @Test("Clearing one cache leaves the other")
    func clearOne() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        try file(tmp.url, GameHostBundle.bundleIDPrefix, "1778820", "functions.data", size: 822)
        try file(tmp.url, GameHostBundle.gameAppIDPrefix, "1778820", "functions.data", size: 894)
        #expect(ShaderCache.clear([.silo], forID: "1778820", cacheRoot: tmp.url) == .cleared(freed: 822))
        let s = ShaderCache.status(forID: "1778820", cacheRoot: tmp.url)
        #expect(s.silo == .none && s.steam.bytes == 894)
        #expect(s.present == [.steam])
        #expect(ShaderCache.clear([.silo], forID: "1778820", cacheRoot: tmp.url) == .nothingToClear)
    }

    @Test("A running game blocks clearing its cache, but not the other one")
    func inUseOnlyBlocksItsOwn() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let steam = try file(tmp.url, GameHostBundle.gameAppIDPrefix, "1778820", "functions.data", size: 5)
        try file(tmp.url, GameHostBundle.bundleIDPrefix, "1778820", "functions.data", size: 7)
        let fd = open(steam.path, O_RDONLY)
        defer { close(fd) }
        #expect(flock(fd, LOCK_EX) == 0)
        #expect(ShaderCache.clear([.steam], forID: "1778820", cacheRoot: tmp.url) == .inUse)
        #expect(ShaderCache.clear(forID: "1778820", cacheRoot: tmp.url) == .inUse)   // all: refused, nothing removed
        #expect(ShaderCache.status(forID: "1778820", cacheRoot: tmp.url).silo.bytes == 7)
        #expect(ShaderCache.clear([.silo], forID: "1778820", cacheRoot: tmp.url) == .cleared(freed: 7))
    }
}
