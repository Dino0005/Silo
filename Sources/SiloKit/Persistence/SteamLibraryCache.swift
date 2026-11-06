import Foundation

/// Reads artwork the bottle's own Steam client has already downloaded, under
/// `<Steam>/appcache/librarycache/<appID>/`. Nothing is fetched: what Steam's library showed, Silo can show.
///
/// Two layouts are on disk side by side (measured 2026-11-06 on the dev bottle): older entries keep
/// `library_600x900.jpg` (or a per-language `library_600x900_italian.jpg`) at the top of the folder; newer
/// ones put `library_capsule.jpg` in a sub-folder named after a content hash.
public enum SteamLibraryCache {

    /// The portrait (2:3) cover for `appID`, from the first client folder that has one. A `_2x` file is
    /// preferred where Steam has it, then the plain name, then a language variant, then the hashed layout.
    public static func portrait(appID: Int, clientDirs: [URL],
                                fileManager: FileManager = .default) -> URL? {
        for client in clientDirs {
            let dir = client.appendingPathComponent("appcache/librarycache/\(appID)", isDirectory: true)
            guard let names = try? fileManager.contentsOfDirectory(atPath: dir.path) else { continue }
            let flat = names.filter { $0.hasPrefix("library_600x900") && $0.hasSuffix(".jpg") }
            let ranked = flat.sorted { rank($0) < rank($1) }
            if let best = ranked.first { return dir.appendingPathComponent(best) }
            for name in names.sorted() {
                let capsule = dir.appendingPathComponent(name).appendingPathComponent("library_capsule.jpg")
                if fileManager.fileExists(atPath: capsule.path) { return capsule }
            }
        }
        return nil
    }

    private static func rank(_ name: String) -> Int {
        switch name {
        case "library_600x900_2x.jpg": 0
        case "library_600x900.jpg": 1
        default: 2
        }
    }
}
