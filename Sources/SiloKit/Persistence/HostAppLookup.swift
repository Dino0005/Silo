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

    /// The app whose icon stands for the game in the library: its host app, else the game app Steam for macOS
    /// starts it through (`GameApps/<id>/`). A game only ever started from Steam for macOS has no host app — Silo
    /// skips the host when the game app exists — so without this it showed Steam's artwork cropped to a square
    /// (Marvel's Spider-Man 2, 2026-11-23). Both carry the icon taken from the game's exe.
    public static func iconBundle(forID id: String, hostAppsDir: URL, gameAppsDir: URL,
                                  fileManager: FileManager = .default) -> URL? {
        bundle(forID: id, in: hostAppsDir, fileManager: fileManager)
            ?? bundle(forID: id, in: gameAppsDir, fileManager: fileManager)
    }
}
