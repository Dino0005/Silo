import Foundation
import Testing
@testable import SiloKit

/// `PipelineCache`: Silo's own cache of D3DMetal's pipelines, for a game started from macOS Steam.
@Suite("Pipeline cache")
struct PipelineCacheTests {
    @Test("Only with its switch on, and only under GPTK")
    func applies() {
        var flags = EnvFlags()
        #expect(!flags.pipelineCache)   // off by default while it is being measured
        #expect(!PipelineCache.applies(flags, graphics: .gptk))
        flags.pipelineCache = true
        #expect(PipelineCache.applies(flags, graphics: .gptk))
        #expect(!PipelineCache.applies(flags, graphics: .dxmt))
    }

    @Test("The library is told the game it files the archives under")
    func environment() {
        #expect(PipelineCache.environment(appID: 1_659_420) == ["SILO_PIPELINE_CACHE_GAME": "1659420"])
    }

    @Test("The archives' folder is the one the library writes, and its size counts every GPU and macOS build")
    func folderAndSize() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let folder = PipelineCache.folder(forID: "1659420", cacheRoot: tmp.url)
        #expect(folder.path.hasSuffix("/io.github.dino0005.silo/pipelines/1659420"))
        #expect(ShaderCache.status(forID: "1659420", cacheRoot: tmp.url).pipelines.bytes == 0)
        for (sub, size) in [("Apple_M4_Max-Version_27_2/archive-1-0.bin", 300),
                            ("Apple_M4_Max-Version_27_2/classic/ab/ab-1-0.bin", 20),
                            ("Apple_M4_Max-Version_27_1/archive-9-0.bin", 5)] {
            let file = folder.appendingPathComponent(sub)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(count: size).write(to: file)
        }
        #expect(ShaderCache.status(forID: "1659420", cacheRoot: tmp.url).pipelines.bytes == 325)
        #expect(ShaderCache.status(forID: "1778820", cacheRoot: tmp.url).pipelines.bytes == 0)
    }

    @Test("A config written before the switch existed reads it as off, and it round-trips")
    func decoding() throws {
        let old = try JSONDecoder().decode(EnvFlags.self, from: Data(#"{"syncMode":"msync"}"#.utf8))
        #expect(!old.pipelineCache)
        var flags = EnvFlags()
        flags.pipelineCache = true
        let back = try JSONDecoder().decode(EnvFlags.self, from: JSONEncoder().encode(flags))
        #expect(back.pipelineCache)
    }

    @Test("Silo's archives are a cache of their own in the Shader cache section: listed, cleared alone or with the rest")
    func clearing() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let archive = PipelineCache.folder(forID: "1778820", cacheRoot: tmp.url)
            .appendingPathComponent("Apple_M3_Pro-Version_27_2_1/archive-1-0.bin")
        try FileManager.default.createDirectory(at: archive.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(count: 64).write(to: archive)
        let metal = tmp.url.appendingPathComponent(GameHostBundle.gameAppIDPrefix + "1778820/com.apple.metal/1/functions.data")
        try FileManager.default.createDirectory(at: metal.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(count: 10).write(to: metal)
        let status = ShaderCache.status(forID: "1778820", cacheRoot: tmp.url)
        #expect(status.present == [.steam, .pipelines])
        #expect(!status.pipelines.isFull && status.bytes == 74)

        // The game running from macOS Steam (Metal holds its cache) blocks clearing Silo's archives too.
        let fd = open(metal.path, O_RDONLY)
        #expect(flock(fd, LOCK_EX) == 0)
        #expect(ShaderCache.clear([.pipelines], forID: "1778820", cacheRoot: tmp.url) == .inUse)
        close(fd)

        #expect(ShaderCache.clear([.pipelines], forID: "1778820", cacheRoot: tmp.url) == .cleared(freed: 64))
        #expect(!FileManager.default.fileExists(atPath: archive.path))
        #expect(ShaderCache.status(forID: "1778820", cacheRoot: tmp.url).present == [.steam])
    }
}
