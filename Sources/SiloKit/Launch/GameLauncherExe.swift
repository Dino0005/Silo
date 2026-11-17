import Foundation

/// A publisher's **launcher** exe that Steam runs first and that starts the real game: `launcher.exe` in
/// The Last of Us Part II (Nixxes ports such as Spider-Man have the same shape), which starts `tlou-ii.exe`.
///
/// **Why the alt loader has to know (measured 2026-11-10 on TLOU II, from macOS Steam):** the whitelist named
/// `launcher`, so the host adopted the launcher and the game started as a plain `wine` process — two Dock
/// tiles and a white icon in Stage Manager. Same failure as `UnrealLauncher`, without Unreal's layout to find
/// the child by. Steam's own launch entries name it instead: the game's other Windows entries are the real
/// executables (TLOU II lists `tlou-ii.exe`, `tlou-ii-l.exe` and two exes it no longer ships).
enum GameLauncherExe {
    /// The executables the host should go to when `exe` is a launcher: the other Windows launch entries that
    /// exist on disk, excluding helpers and launchers. Empty when `exe` isn't a launcher or nothing qualifies —
    /// the launch then stays as it is. Whitelisting several is safe: only one of them runs, and the launcher
    /// itself is no longer listed, so it can't take the host first.
    /// - Parameter installDir: the game's install folder — Steam's entries are relative to it.
    static func windowOwners(forLauncher exe: URL, installDir: URL, launchExecutables: [String],
                             fileManager: FileManager = .default) -> [URL] {
        guard isLauncher(exe.lastPathComponent) else { return [] }
        let root = installDir
        var seen: Set<String> = []
        return launchExecutables.compactMap { relative -> URL? in
            let path = relative.replacingOccurrences(of: "\\", with: "/")
            let name = (path as NSString).lastPathComponent
            guard !isLauncher(name), !AppInfoPatcher.isHelperExecutable(name),
                  name.lowercased() != exe.lastPathComponent.lowercased(),
                  seen.insert(name.lowercased()).inserted else { return nil }
            let url = root.appendingPathComponent(path)
            return fileManager.fileExists(atPath: url.path) ? url : nil
        }
    }

    static func isLauncher(_ fileName: String) -> Bool {
        fileName.lowercased().contains("launcher")
    }
}
