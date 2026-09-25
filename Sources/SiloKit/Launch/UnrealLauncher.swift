import Foundation

/// Unreal Engine games often ship a tiny **launcher** exe at the top of the install
/// (`TEKKEN 8.exe`, 196 KB) that starts the real game, `<Project>/Binaries/Win64/<Project>-Win64-Shipping.exe`
/// (168 MB), and waits for it.
///
/// **Why the alt loader has to know (measured 2026-09-25 on Tekken 8):** the whitelist named the launcher,
/// so the single-use host adopted the LAUNCHER — a process with no window — while the real game started
/// afterwards as a plain `wine` process: two Dock tiles, and the window-owning one not ours. Whitelisting
/// both would not help, since one host serves one process and the launcher would take it again. The fix is
/// to hand the host to the Shipping executable instead: the launcher then runs as an ordinary process and
/// the host goes to the one that owns the window. Fatal Fury: City of the Wolves has the same layout.
enum UnrealLauncher {
    /// The Shipping executable that `launcher` starts, or nil when there is none — or more than one, in
    /// which case guessing could hand the host to the wrong process, and the launch stays as it is.
    static func shippingExecutable(forLauncher launcher: URL, fileManager: FileManager = .default) -> URL? {
        guard !isShipping(launcher.lastPathComponent) else { return nil }   // already the real one
        let root = launcher.deletingLastPathComponent()
        let projects = (try? fileManager.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        var found: [URL] = []
        for project in projects {
            let win64 = project.appendingPathComponent("Binaries/Win64", isDirectory: true)
            let files = (try? fileManager.contentsOfDirectory(atPath: win64.path)) ?? []
            found += files.filter(isShipping).map { win64.appendingPathComponent($0) }
        }
        return pick(found)
    }

    /// Exactly one candidate, or none. Pure, for the tests.
    static func pick(_ candidates: [URL]) -> URL? {
        candidates.count == 1 ? candidates[0] : nil
    }

    static func isShipping(_ fileName: String) -> Bool {
        let lower = fileName.lowercased()
        return lower.hasSuffix("-win64-shipping.exe")
    }
}
