import Foundation
import Testing
@testable import SiloKit

/// `CacheInventory`: every game's caches in one list, uninstalled games' included.
@Suite("Cache inventory")
struct CacheInventoryTests {
    private func put(_ root: URL, _ relative: String, size: Int) throws {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(count: size).write(to: url)
    }

    @Test("Installed games, games left behind (named by their app), and D3DMetal folders no game owns; biggest first")
    func scan() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let cache = tmp.url.appendingPathComponent("cache"), hosts = tmp.url.appendingPathComponent("HostApps"),
            gameApps = tmp.url.appendingPathComponent("GameApps")
        let game = GameHostBundle.gameAppIDPrefix, host = GameHostBundle.bundleIDPrefix
        // Installed: UNCHARTED, with Metal's cache and D3DMetal's of two of its executables.
        try put(cache, "\(game)1659420/com.apple.metal/1/functions.data", size: 200)
        try put(cache, "d3dm/u4-l.exe/shaders.cache", size: 600)
        try put(cache, "d3dm/tll-l.exe/shaders.cache", size: 300)
        // Uninstalled: NieR (its host app is still there) and an app id with no app at all.
        try put(cache, "\(host)524220/com.apple.metal/1/functions.data", size: 50)
        try FileManager.default.createDirectory(at: hosts.appendingPathComponent("524220/NieR Automata.app"),
                                                withIntermediateDirectories: true)
        try put(cache, "io.github.dino0005.silo/pipelines/999/a/archive-1-0.bin", size: 7)
        // D3DMetal folders of no game in the library; the Windows Steam client's host is an entry of its own.
        try put(cache, "d3dm/NieRAutomata.exe/shaders.cache", size: 40)
        try put(cache, "\(host)steam-client/com.apple.metal/1/functions.data", size: 9)
        // A game in the library with nothing cached is not listed.
        let games = [CacheInventory.Game(id: "1659420", name: "UNCHARTED", executables: ["u4-l.exe", "tll-l.exe", "u4.exe"]),
                     CacheInventory.Game(id: "1778820", name: "TEKKEN 8", executables: ["Polaris-Win64-Shipping.exe"])]

        let entries = CacheInventory.scan(games: games, hostAppsDir: hosts, gameAppsDir: gameApps, cacheRoot: cache)
        #expect(entries.map(\.name) == ["UNCHARTED", "NieR Automata", "NieRAutomata.exe", "Steam (Windows)", "Steam app 999"])
        // Steam's app cache names a left-behind game Silo made no app for.
        let named = CacheInventory.scan(games: games, hostAppsDir: hosts, gameAppsDir: gameApps, cacheRoot: cache) {
            $0 == "999" ? "Spacewar" : nil
        }
        #expect(named.last?.name == "Spacewar")
        #expect(entries.map(\.installed) == [true, false, false, true, false])
        #expect(entries[0].status.bytes == 1_100 && entries[0].status.translation.bytes == 900)
        #expect(entries[2].id == "exe:NieRAutomata.exe" && entries[2].status.translation.bytes == 40)
        #expect(entries[4].status.pipelines.bytes == 7)
    }

    @Test("The Windows Steam client is one entry, with its executables' D3DMetal folders and its host's Metal cache")
    func steamClient() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        try put(tmp.url, "d3dm/steamwebhelper.exe/shaders.cache", size: 19)
        try put(tmp.url, "d3dm/steam.exe/shaders.cache", size: 1)
        try put(tmp.url, "\(GameHostBundle.bundleIDPrefix)steam-client/com.apple.metal/1/functions.data", size: 30)
        let entries = CacheInventory.scan(games: [], hostAppsDir: tmp.url, gameAppsDir: tmp.url, cacheRoot: tmp.url)
        #expect(entries.map(\.name) == ["Steam (Windows)"])
        #expect(entries[0].installed && entries[0].status.bytes == 50 && entries[0].status.translation.bytes == 20)
        #expect(CacheInventory.clear(entries[0], cacheRoot: tmp.url) == .cleared(freed: 50))
    }

    @Test("Clearing an entry removes all its caches and nothing else")
    func clear() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let cache = tmp.url
        try put(cache, "\(GameHostBundle.bundleIDPrefix)524220/com.apple.metal/1/functions.data", size: 50)
        try put(cache, "d3dm/NieRAutomata.exe/shaders.cache", size: 40)
        try put(cache, "d3dm/u4-l.exe/shaders.cache", size: 600)
        let entries = CacheInventory.scan(games: [], hostAppsDir: tmp.url, gameAppsDir: tmp.url, cacheRoot: cache)
        let nier = try #require(entries.first { $0.id == "exe:NieRAutomata.exe" })
        #expect(CacheInventory.clear(nier, cacheRoot: cache) == .cleared(freed: 40))
        let left = try #require(entries.first { $0.id == "524220" })
        #expect(CacheInventory.clear(left, cacheRoot: cache) == .cleared(freed: 50))
        #expect(CacheInventory.scan(games: [], hostAppsDir: tmp.url, gameAppsDir: tmp.url, cacheRoot: cache).map(\.id)
                == ["exe:u4-l.exe"])
    }
}
