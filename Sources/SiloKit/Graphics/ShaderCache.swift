import Foundation

/// A game's compiled shaders, as Metal keeps them per bundle identifier: `<user cache dir>/<bundle id>/com.apple.metal/`.
/// A game has two such caches, one per place it was started from (`Kind`): its host's (`…silo.host.<id>`, launches from
/// Silo) and its game app's (`…silo.game.<id>`, launches from Steam for macOS).
///
/// Metal's `functions.data` stops growing at 1,140,781,056 bytes and keeps what it holds — shaders of other areas,
/// older game builds, older macOS or GPTK. Once full, the shaders it can't store are compiled again at every launch
/// (UNCHARTED, measured 2026-11-23: as much compiler work in the second of two identical runs as in the first; with the
/// cache cleared, the second run was much lighter and the cache held 213 MB). Clearing one is the user's choice — it
/// frees the space, and the next launch from that place compiles the game's shaders again, so it loads slower and
/// stutters at first.
public enum ShaderCache {
    /// Where Metal's `functions.data` stops (measured on macOS 27, GPTK 4 beta 3).
    public static let metalFileCap: Int64 = 1_140_781_056

    /// Which of a game's two caches.
    public enum Kind: String, CaseIterable, Sendable {
        /// Launches from Steam for macOS: the game app's bundle id.
        case steam
        /// Launches from Silo: the host's bundle id.
        case silo

        var bundleIDPrefix: String {
            switch self {
            case .steam: GameHostBundle.gameAppIDPrefix
            case .silo: GameHostBundle.bundleIDPrefix
            }
        }
    }

    /// One cache: every file's size, and whether a `functions.data` has reached Metal's cap.
    public struct Usage: Sendable, Equatable {
        public let bytes: Int64
        public let isFull: Bool

        public init(bytes: Int64, isFull: Bool) {
            self.bytes = bytes
            self.isFull = isFull
        }

        public static let none = Usage(bytes: 0, isFull: false)
    }

    public struct Status: Sendable, Equatable {
        public let steam: Usage
        public let silo: Usage

        public init(steam: Usage, silo: Usage) {
            self.steam = steam
            self.silo = silo
        }

        public subscript(kind: Kind) -> Usage { kind == .steam ? steam : silo }
        public var bytes: Int64 { steam.bytes + silo.bytes }
        public var isFull: Bool { steam.isFull || silo.isFull }
        /// The caches that exist, in display order.
        public var present: [Kind] { Kind.allCases.filter { self[$0].bytes > 0 } }

        public static let empty = Status(steam: .none, silo: .none)
    }

    public enum ClearOutcome: Sendable, Equatable {
        case cleared(freed: Int64)
        case nothingToClear
        /// The game is running from there: Metal holds its cache files.
        case inUse
        case failed(String)
    }

    /// The `com.apple.metal` folder of one cache of the game `id` (a Steam app id, or a manual game's UUID).
    static func folder(_ kind: Kind, forID id: String, cacheRoot: URL) -> URL {
        cacheRoot.appendingPathComponent(kind.bundleIDPrefix + GameHostBundle.bundleSafe(id), isDirectory: true)
            .appendingPathComponent("com.apple.metal", isDirectory: true)
    }

    public static func status(forID id: String, cacheRoot: URL = LegacyIdentifiers.userCacheDirectory,
                              fileManager: FileManager = .default) -> Status {
        func usage(_ kind: Kind) -> Usage {
            var bytes: Int64 = 0
            var full = false
            for file in files(in: folder(kind, forID: id, cacheRoot: cacheRoot), fileManager: fileManager) {
                let size = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize.map(Int64.init) ?? 0
                bytes += size
                if file.lastPathComponent.hasPrefix("functions"), file.pathExtension == "data", size >= metalFileCap {
                    full = true
                }
            }
            return Usage(bytes: bytes, isFull: full)
        }
        return Status(steam: usage(.steam), silo: usage(.silo))
    }

    /// Removes the given caches. Refuses — removing none — while the game runs from any of them (Metal keeps an
    /// exclusive `flock` on a cache file it uses).
    public static func clear(_ kinds: Set<Kind> = Set(Kind.allCases), forID id: String,
                             cacheRoot: URL = LegacyIdentifiers.userCacheDirectory,
                             fileManager: FileManager = .default) -> ClearOutcome {
        let chosen = Kind.allCases.filter(kinds.contains)
        let all = chosen.flatMap { files(in: folder($0, forID: id, cacheRoot: cacheRoot), fileManager: fileManager) }
        guard !all.isEmpty else { return .nothingToClear }
        if all.contains(where: LegacyIdentifiers.isHeld) { return .inUse }
        let before = status(forID: id, cacheRoot: cacheRoot, fileManager: fileManager)
        let freed = chosen.reduce(Int64(0)) { $0 + before[$1].bytes }
        do {
            for kind in chosen {
                let dir = folder(kind, forID: id, cacheRoot: cacheRoot)
                if fileManager.fileExists(atPath: dir.path) { try fileManager.removeItem(at: dir) }
            }
            return .cleared(freed: freed)
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    private static func files(in folder: URL, fileManager: FileManager) -> [URL] {
        guard let walker = fileManager.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey])
        else { return [] }
        return walker.compactMap { $0 as? URL }.filter {
            (try? $0.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
        }
    }
}
