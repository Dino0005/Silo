import Foundation

/// The game's identity for a launch from **macOS Steam**: Wine's loader placed inside the game's host bundle
/// (`GameHostBundle`), so every process of the game runs *from* that `.app` and macOS gives it the game's name and
/// icon in the Dock, Mission Control and Stage Manager.
///
/// Why not the alt-loader host there: the host adopts exactly one process, and a game that relaunches itself
/// (measured on SOULCALIBUR VI, 2026-11-12: the adopted process starts a fresh copy of the game and exits, as soon as
/// Steam Input's pad reaches it) leaves the copy outside the bundle — Dock "wine", blank Stage Manager tile.
/// Here a small injected library (`Scripts/game-loader`, `silo-game-loader.dylib`) re-points every exec of the
/// loader for one of the game's executables at the copy in the bundle, relaunches included. Same idea as NotProton's
/// PR #90 (sn0wst0rm; final version in the NotProton fork as d77e605/8946aab/71b8965) — Silo's own code.
///
/// The loader is a **hard link** of the runtime's `lib/wine/x86_64-unix/wine` (a copy if the link fails), and every
/// other entry of that directory is **symlinked** beside it: the loader finds `ntdll.so` next to itself, and
/// `ntdll.so` resolves through its symlink to the real runtime, from which Wine derives its other directories.
/// (`CLAUDE.md`'s 2026-09-17 note that a moved loader can't work was measured without those siblings.)
public enum GameAppLoader {
    /// The loader's name inside `Contents/MacOS` — the one name the injected library and the Steam hook look for.
    public static let loaderName = "wine"
    /// The injected library inside Silo.app.
    static let injectorRelativePath = "Contents/Helpers/silo-game-loader.dylib"

    /// Environment the injected library reads: the loader to exec, and the game's executable names.
    public static let loaderEnvKey = "SILO_GAME_LOADER"
    public static let executablesEnvKey = "SILO_GAME_EXES"

    /// The injected library of the running app, or nil (a `swift run` build has no `.app`).
    public static func injector(inAppBundle appBundle: URL = Bundle.main.bundleURL,
                                fileManager: FileManager = .default) -> URL? {
        let url = appBundle.appendingPathComponent(injectorRelativePath)
        return fileManager.fileExists(atPath: url.path) ? url : nil
    }

    /// Pure: the `SILO_GAME_EXES` value — every distinct file name, joined by `:`.
    static func executablesValue(_ executables: [URL]) -> String {
        var seen = Set<String>(), names: [String] = []
        for name in executables.map(\.lastPathComponent) where !name.isEmpty && !name.contains(":") {
            if seen.insert(name.lowercased()).inserted { names.append(name) }
        }
        return names.joined(separator: ":")
    }

    /// Places the loader of `unixDir` (`<runtime>/lib/wine/x86_64-unix`) in `macOSDir` (a host bundle's
    /// `Contents/MacOS`) with its siblings symlinked, refreshing what a previous runtime left. Returns the loader.
    /// Other files there (the alt-loader host binary) are left alone.
    @discardableResult
    public static func stage(unixDir: URL, in macOSDir: URL, fileManager: FileManager = .default) throws -> URL {
        let source = unixDir.appendingPathComponent(loaderName)
        let loader = macOSDir.appendingPathComponent(loaderName)
        try fileManager.createDirectory(at: macOSDir, withIntermediateDirectories: true)

        // The loader: keep it when it is already this runtime's file, else replace it atomically.
        if !sameFile(loader, source, fileManager: fileManager) {
            let temp = macOSDir.appendingPathComponent(".\(loaderName).silo-\(UUID().uuidString)")
            do { try fileManager.linkItem(at: source, to: temp) } catch { try fileManager.copyItem(at: source, to: temp) }
            if fileManager.fileExists(atPath: loader.path) {
                _ = try fileManager.replaceItemAt(loader, withItemAt: temp)
            } else {
                try fileManager.moveItem(at: temp, to: loader)
            }
        }

        // The siblings: one symlink per entry of the runtime's unix dir; drop ours that point elsewhere.
        let wanted = try fileManager.contentsOfDirectory(atPath: unixDir.path).filter { $0 != loaderName }
        for name in try fileManager.contentsOfDirectory(atPath: macOSDir.path) {
            let item = macOSDir.appendingPathComponent(name)
            guard let target = try? fileManager.destinationOfSymbolicLink(atPath: item.path) else { continue }
            if target != unixDir.appendingPathComponent(name).path { try fileManager.removeItem(at: item) }
        }
        for name in wanted {
            let link = macOSDir.appendingPathComponent(name)
            if (try? fileManager.destinationOfSymbolicLink(atPath: link.path)) != nil { continue }
            if fileManager.fileExists(atPath: link.path) { continue }   // never replace a real file of ours
            try fileManager.createSymbolicLink(at: link, withDestinationURL: unixDir.appendingPathComponent(name))
        }
        return loader
    }

    private static func sameFile(_ a: URL, _ b: URL, fileManager: FileManager) -> Bool {
        guard let x = try? fileManager.attributesOfItem(atPath: a.path),
              let y = try? fileManager.attributesOfItem(atPath: b.path) else { return false }
        if let i = x[.systemFileNumber] as? Int, let j = y[.systemFileNumber] as? Int,
           let d = x[.systemNumber] as? Int, let e = y[.systemNumber] as? Int, i == j, d == e { return true }
        return fileManager.contentsEqual(atPath: a.path, andPath: b.path)
    }
}
