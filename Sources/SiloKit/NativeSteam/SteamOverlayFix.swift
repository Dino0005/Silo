import Foundation

/// Silo's fix for Steam's overlay in a game started from macOS Steam: `silo-overlay-fix.dylib` (`Scripts/overlay-fix`),
/// injected right after Steam's `gameoverlayrenderer.dylib`. The overlay draws with pipelines built for BGRA8 into the
/// game's drawable whatever its format; D3DMetal presents RGB10A2, so the overlay came out as coloured noise (measured on
/// SOULCALIBUR VI, 2026-11-13). The library rebuilds the overlay's pipeline for the drawable's format when they differ.
public enum SteamOverlayFix {
    static let relativePath = "Contents/Helpers/silo-overlay-fix.dylib"
    static let overlayLibraryName = "gameoverlayrenderer.dylib"

    /// The library in the running app, or nil (a `swift run` build has no `.app`).
    public static func library(inAppBundle appBundle: URL = Bundle.main.bundleURL,
                               fileManager: FileManager = .default) -> URL? {
        let url = appBundle.appendingPathComponent(relativePath)
        return fileManager.fileExists(atPath: url.path) ? url : nil
    }

    /// Pure: `libraries` with `fix` right after Steam's overlay — only when the overlay is there.
    static func adding(_ fix: URL?, to libraries: [URL]) -> [URL] {
        guard let fix, let index = libraries.firstIndex(where: { $0.lastPathComponent == overlayLibraryName })
        else { return libraries }
        var result = libraries
        result.insert(fix, at: index + 1)
        return result
    }
}
