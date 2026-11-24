import Foundation

/// Silo's own cache of the pipelines D3DMetal compiles, for a game started from macOS Steam under GPTK:
/// `silo-pipeline-cache.dylib` (`Scripts/pipeline-cache` — MacGameFix's GPL-3.0 pipeline cache, run inside the game),
/// injected with Steam's libraries when the game's switch is on.
///
/// Metal's own cache is one file per app that stops at `ShaderCache.metalFileCap` and keeps what it holds; once full,
/// every shader it can't store is compiled again at each launch (UNCHARTED, 2026-11-23). This one keeps the compiled
/// pipelines as archives of its own — Metal 4's (a serializer on every compiler D3DMetal makes, looked up before
/// compiling) and the classic calls' (one archive per pipeline) — in a folder per game, GPU and macOS build.
public enum PipelineCache {
    static let relativePath = "Contents/Helpers/silo-pipeline-cache.dylib"
    /// The game the archives are filed under (a Steam app id), read by the library.
    static let gameEnvKey = "SILO_PIPELINE_CACHE_GAME"
    /// The folder under the user cache directory the library writes to (`silo_pipeline_cache.mm`).
    static let rootFolder = "io.github.dino0005.silo"

    /// The library in the running app, or nil (a `swift run` build has no `.app`).
    public static func library(inAppBundle appBundle: URL = Bundle.main.bundleURL,
                               fileManager: FileManager = .default) -> URL? {
        let url = appBundle.appendingPathComponent(relativePath)
        return fileManager.fileExists(atPath: url.path) ? url : nil
    }

    /// Pure: whether this launch gets the cache — the switch on, and D3DMetal doing the rendering (it is what the
    /// library hooks; under DXMT it would stay idle).
    static func applies(_ flags: EnvFlags, graphics: GraphicsBackend) -> Bool {
        flags.pipelineCache && graphics == .gptk
    }

    /// Pure: the variables the library needs for the game `appID`.
    static func environment(appID: Int) -> [String: String] {
        [gameEnvKey: String(appID)]
    }

    /// Where the archives of the game `id` are: one folder per GPU and macOS build below it.
    public static func folder(forID id: String, cacheRoot: URL = LegacyIdentifiers.userCacheDirectory) -> URL {
        cacheRoot.appendingPathComponent(rootFolder, isDirectory: true)
            .appendingPathComponent("pipelines", isDirectory: true)
            .appendingPathComponent(id, isDirectory: true)
    }

}
