import Foundation

/// Finds a game's host app — the per-game `.app` Silo writes under `HostApps/<id>/` on the first launch
/// (`GameHostBundle`), `<id>` being the Steam app ID or a manual game's UUID. Its icon is the game's own,
/// the one macOS (and Apple's Games app) shows for it.
public enum HostAppLookup {

    /// The first `.app` in `HostApps/<id>/`, or nil when the game has never been launched through Silo.
    public static func bundle(forID id: String, in hostAppsDir: URL,
                              fileManager: FileManager = .default) -> URL? {
        let dir = hostAppsDir.appendingPathComponent(id, isDirectory: true)
        guard let names = try? fileManager.contentsOfDirectory(atPath: dir.path) else { return nil }
        return names.sorted().first { $0.hasSuffix(".app") }.map { dir.appendingPathComponent($0) }
    }
}
