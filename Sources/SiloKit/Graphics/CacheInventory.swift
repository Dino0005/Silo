import Foundation

/// Every game's caches in one list (Settings → General → Manage Caches…): the ones `ShaderCache` knows for each
/// game in the library, and the ones left behind by games that are no longer installed — neither Steam nor Silo
/// removes a game's caches when it is uninstalled.
///
/// A left-behind game is found by its folders under the user cache directory (`…silo.game.<id>`, `…silo.host.<id>`,
/// Silo's pipeline archives); its name comes from the app Silo made for it (`HostApps/<id>/`, `GameApps/<id>/`),
/// which outlives the game too. D3DMetal's folders are named by executable, so one that no game in the library
/// owns is listed on its own, by that name.
public enum CacheInventory {
    /// A game of the library, as the inventory needs it.
    public struct Game: Sendable, Equatable {
        public let id: String
        public let name: String
        /// Its executables' file names (D3DMetal's folders).
        public let executables: [String]

        public init(id: String, name: String, executables: [String]) {
            self.id = id
            self.name = name
            self.executables = executables
        }
    }

    public struct Entry: Sendable, Equatable, Identifiable {
        /// The game's id, or `exe:<name>` for a D3DMetal folder no game owns.
        public let id: String
        public let name: String
        public let installed: Bool
        /// The cache folder names of D3DMetal that belong to it.
        public let executables: [String]
        public let status: ShaderCache.Status

        static let executablePrefix = "exe:"
    }

    /// Pure-ish (reads the cache folders): every entry with something in it, the biggest first.
    /// - Parameter steamName: a Steam app's name when Silo made no app for it (Steam's own app cache), or nil.
    public static func scan(games: [Game], hostAppsDir: URL, gameAppsDir: URL,
                            cacheRoot: URL = LegacyIdentifiers.userCacheDirectory,
                            fileManager: FileManager = .default,
                            steamName: (String) -> String? = { _ in nil }) -> [Entry] {
        var entries: [Entry] = []
        var owned = Set<String>()
        for game in games {
            owned.formUnion(game.executables.map { $0.lowercased() })
            entries.append(Entry(id: game.id, name: game.name, installed: true, executables: game.executables,
                                 status: ShaderCache.status(forID: game.id, executables: game.executables,
                                                            cacheRoot: cacheRoot, fileManager: fileManager)))
        }
        // The Windows Steam client of Silo's bottles: one entry each, with the client's own executables.
        for (id, name, exes) in steamClients {
            owned.formUnion(exes.map { $0.lowercased() })
            entries.append(Entry(id: id, name: name, installed: true, executables: exes,
                                 status: ShaderCache.status(forID: id, executables: exes, cacheRoot: cacheRoot,
                                                            fileManager: fileManager)))
        }
        let known = Set(games.map(\.id))
        for id in leftBehindIDs(cacheRoot: cacheRoot, fileManager: fileManager) where !known.contains(id) {
            let status = ShaderCache.status(forID: id, cacheRoot: cacheRoot, fileManager: fileManager)
            let app = HostAppLookup.iconBundle(forID: id, hostAppsDir: hostAppsDir, gameAppsDir: gameAppsDir,
                                               fileManager: fileManager)
            let name = app.map { $0.deletingPathExtension().lastPathComponent }
                ?? (ShaderCache.isSteamID(id) ? steamName(id) ?? "Steam app \(id)" : id)
            entries.append(Entry(id: id, name: name, installed: false, executables: [], status: status))
        }
        let d3dm = cacheRoot.appendingPathComponent("d3dm", isDirectory: true)
        for exe in ((try? fileManager.contentsOfDirectory(atPath: d3dm.path)) ?? []).sorted()
        where !exe.hasPrefix(".") && !owned.contains(exe.lowercased()) {
            let id = Entry.executablePrefix + exe
            entries.append(Entry(id: id, name: exe, installed: false, executables: [exe],
                                 status: ShaderCache.status(forID: id, executables: [exe], cacheRoot: cacheRoot,
                                                            fileManager: fileManager)))
        }
        return entries.filter { $0.status.bytes > 0 }.sorted {
            $0.status.bytes != $1.status.bytes ? $0.status.bytes > $1.status.bytes : $0.name < $1.name
        }
    }

    /// The Windows Steam client's hosts (`…silo.host.steam-client`, `…-mf` for the Media Foundation bottle) and its
    /// executables, whose D3DMetal folders would otherwise each be listed on their own.
    static let steamClientExecutables = ["steam.exe", "steamwebhelper.exe", "steamwebhelper_orig.exe", "steamsysinfo.exe",
                                         "steamerrorreporter.exe", "steamservice.exe", "gameoverlayui.exe"]
    static let steamClients: [(String, String, [String])] = [
        ("steam-client", "Steam (Windows)", steamClientExecutables),
        ("steam-client-mf", "Steam (Windows, Media Foundation)", []),
    ]

    /// Removes every cache of `entry`, refused while its game runs (`ShaderCache.clear`).
    public static func clear(_ entry: Entry, cacheRoot: URL = LegacyIdentifiers.userCacheDirectory,
                             fileManager: FileManager = .default) -> ShaderCache.ClearOutcome {
        ShaderCache.clear(forID: entry.id, executables: entry.executables, cacheRoot: cacheRoot, fileManager: fileManager)
    }

    /// The game ids that have a cache folder: Metal's under either bundle id, or Silo's pipeline archives.
    static func leftBehindIDs(cacheRoot: URL, fileManager: FileManager) -> [String] {
        var ids = Set<String>()
        for name in (try? fileManager.contentsOfDirectory(atPath: cacheRoot.path)) ?? [] {
            for prefix in [GameHostBundle.gameAppIDPrefix, GameHostBundle.bundleIDPrefix] where name.hasPrefix(prefix) {
                let id = String(name.dropFirst(prefix.count))
                // Silo's own helpers live under the host prefix too (the Steam client's hosts).
                if ShaderCache.isSteamID(id) || UUID(uuidString: id) != nil { ids.insert(id) }
            }
        }
        let pipelines = PipelineCache.folder(forID: "x", cacheRoot: cacheRoot).deletingLastPathComponent()
        for id in (try? fileManager.contentsOfDirectory(atPath: pipelines.path)) ?? [] where ShaderCache.isSteamID(id) {
            ids.insert(id)
        }
        return ids.sorted()
    }
}
