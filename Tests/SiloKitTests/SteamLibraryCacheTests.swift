import Foundation
import Testing
@testable import SiloKit

@Suite("SteamLibraryCache")
struct SteamLibraryCacheTests {

    private func makeClient() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("silo-librarycache-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func touch(_ client: URL, _ relative: String) throws {
        let url = client.appendingPathComponent("appcache/librarycache/\(relative)")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data([0xFF]).write(to: url)
    }

    @Test("Finds the flat library_600x900.jpg")
    func flat() throws {
        let client = try makeClient()
        try touch(client, "601150/library_600x900.jpg")
        try touch(client, "601150/header.jpg")
        #expect(SteamLibraryCache.portrait(appID: 601150, clientDirs: [client])?.lastPathComponent
                == "library_600x900.jpg")
    }

    @Test("Prefers _2x, then the plain name, over a language variant")
    func ranking() throws {
        let client = try makeClient()
        try touch(client, "1/library_600x900_italian.jpg")
        try touch(client, "1/library_600x900.jpg")
        #expect(SteamLibraryCache.portrait(appID: 1, clientDirs: [client])?.lastPathComponent
                == "library_600x900.jpg")
        try touch(client, "1/library_600x900_2x.jpg")
        #expect(SteamLibraryCache.portrait(appID: 1, clientDirs: [client])?.lastPathComponent
                == "library_600x900_2x.jpg")
    }

    @Test("A language variant alone is used")
    func languageOnly() throws {
        let client = try makeClient()
        try touch(client, "1659420/library_600x900_italian.jpg")
        #expect(SteamLibraryCache.portrait(appID: 1659420, clientDirs: [client])?.lastPathComponent
                == "library_600x900_italian.jpg")
    }

    @Test("Finds the hashed library_capsule.jpg layout")
    func hashed() throws {
        let client = try makeClient()
        try touch(client, "3764200/ed3b2cae/library_capsule.jpg")
        let found = SteamLibraryCache.portrait(appID: 3764200, clientDirs: [client])
        #expect(found?.lastPathComponent == "library_capsule.jpg")
        #expect(found?.deletingLastPathComponent().lastPathComponent == "ed3b2cae")
    }

    @Test("Falls through to the next client, and is nil when nobody has it")
    func multipleClients() throws {
        let empty = try makeClient(), other = try makeClient()
        try touch(other, "7/library_600x900.jpg")
        #expect(SteamLibraryCache.portrait(appID: 7, clientDirs: [empty, other]) != nil)
        #expect(SteamLibraryCache.portrait(appID: 8, clientDirs: [empty, other]) == nil)
        #expect(SteamLibraryCache.portrait(appID: 7, clientDirs: []) == nil)
    }
}

@Suite("SteamArtworkStore portrait")
struct SteamArtworkPortraitTests {

    private func cdn(_ appID: Int, _ name: String) -> String {
        "https://cdn.cloudflare.steamstatic.com/steam/apps/\(appID)/\(name)"
    }

    private func makeStore() throws -> SteamArtworkStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("silo-portrait-\(UUID().uuidString)", isDirectory: true)
        return SteamArtworkStore(dir: dir)
    }

    @Test("Prefers the _2x cover and stores it")
    func prefers2x() async throws {
        let session = FakeURLProtocol.makeSession()
        FakeURLProtocol.stub(cdn(990001, "library_600x900_2x.jpg"), data: Data("hd".utf8), session: session)
        FakeURLProtocol.stub(cdn(990001, "library_600x900.jpg"), data: Data("sd".utf8), session: session)
        let store = try makeStore()
        #expect(store.cachedPortrait(appID: 990001) == nil)
        let url = try #require(await store.refreshPortrait(appID: 990001, session: session))
        #expect(try Data(contentsOf: url) == Data("hd".utf8))
        #expect(store.cachedPortrait(appID: 990001) == url)
    }

    @Test("Falls back to the plain cover on a _2x 404")
    func fallsBack() async throws {
        let session = FakeURLProtocol.makeSession()
        FakeURLProtocol.stub(cdn(990002, "library_600x900_2x.jpg"), statusCode: 404, data: Data(), session: session)
        FakeURLProtocol.stub(cdn(990002, "library_600x900.jpg"), data: Data("sd".utf8), session: session)
        let store = try makeStore()
        let url = try #require(await store.refreshPortrait(appID: 990002, session: session))
        #expect(try Data(contentsOf: url) == Data("sd".utf8))
    }

    @Test("Nil when neither exists, and nothing is stored")
    func neither() async throws {
        let session = FakeURLProtocol.makeSession()
        for name in ["library_600x900_2x.jpg", "library_600x900.jpg"] {
            FakeURLProtocol.stub(cdn(990003, name), statusCode: 404, data: Data(), session: session)
        }
        let store = try makeStore()
        #expect(await store.refreshPortrait(appID: 990003, session: session) == nil)
        #expect(store.cachedPortrait(appID: 990003) == nil)
    }
}
