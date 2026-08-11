import Foundation

/// Keeps manual games' cover images under `AppPaths.coversDir`.
///
/// The chosen file is COPIED rather than referenced: a cover picked off an external drive, or moved
/// afterwards, keeps working. Only the resulting file NAME is persisted — resolved against `coversDir`, so
/// the record survives the support directory moving, the same reason `SharedSaveFolder` stores a root plus
/// a name instead of a path.
public struct CoverArtStore: Sendable {
    // Computed (not stored): FileManager isn't Sendable, but the shared instance is fine to use.
    private var fileManager: FileManager { .default }
    private let coversDir: URL

    public init(coversDir: URL) {
        self.coversDir = coversDir
    }

    /// Where a stored cover lives, or nil if the name is absent or the file is gone (a cover deleted from
    /// Finder must degrade to the exe icon, not to a broken image).
    public func url(named name: String?) -> URL? {
        guard let name, !name.isEmpty else { return nil }
        let url = coversDir.appendingPathComponent(name, isDirectory: false)
        return fileManager.fileExists(atPath: url.path) ? url : nil
    }

    /// Copy `source` in as `<id>.<ext>` and return the stored file name, or nil if the copy failed.
    ///
    /// Named after the game so a second choice REPLACES the first instead of piling up files. Failure is
    /// deliberately soft — a cover is decoration and must never be able to break saving a game's settings.
    public func store(_ source: URL, for id: UUID) -> String? {
        let ext = source.pathExtension.isEmpty ? "png" : source.pathExtension.lowercased()
        let name = "\(id.uuidString).\(ext)"
        let destination = coversDir.appendingPathComponent(name, isDirectory: false)
        do {
            try fileManager.createDirectory(at: coversDir, withIntermediateDirectories: true)
            // Any previous cover for this game, whatever its extension.
            remove(for: id)
            try fileManager.copyItem(at: source, to: destination)
            return name
        } catch {
            return nil
        }
    }

    /// Delete every cover belonging to `id`, whatever the extension. Called when a cover is cleared and
    /// when the game itself is removed, so `Covers/` doesn't collect orphans.
    public func remove(for id: UUID) {
        let prefix = id.uuidString
        let names = (try? fileManager.contentsOfDirectory(atPath: coversDir.path)) ?? []
        for name in names where name.hasPrefix(prefix) {
            try? fileManager.removeItem(at: coversDir.appendingPathComponent(name, isDirectory: false))
        }
    }
}
