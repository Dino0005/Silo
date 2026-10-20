import Foundation

/// Whether a game ships NVIDIA DLSS — its `nvngx_dlss.dll`, the DLSS model the game hands to the driver's
/// `nvngx`. Under DXMT, Silo's MetalFX option means DLSS on MetalFX's temporal scaler for such a game and the
/// spatial MetalFX upscale of the swapchain for any other (the user's decision, 2026-10-21): enabling DXMT's
/// NVIDIA extensions makes the GPU look like an NVIDIA one, which a game without DLSS gains nothing from.
///
/// Where the file sits: next to the exe (God of War, `<install>/nvngx_dlss.dll`), or — for Unreal — in a
/// plugin folder of the project or the engine (`<root>/Engine/Plugins/Runtime/Nvidia/DLSS/Binaries/ThirdParty/
/// Win64/`, `<root>/<Project>/Plugins/DLSS/…`). Unreal's exe is either the launcher at `<root>` or
/// `<root>/<Project>/Binaries/Win64/…-Shipping.exe`, so the search starts at `<root>` in both cases. Bounded
/// (depth and entry count): it runs before every DXMT launch with MetalFX on, and must never walk a whole
/// library when a game's exe sits high up.
enum DLSSDetector {
    static let fileName = "nvngx_dlss.dll"
    static let maxDepth = 9
    static let maxEntries = 50_000

    static func gameShipsDLSS(exe: URL, fileManager: FileManager = .default) -> Bool {
        let root = searchRoot(forExe: exe)
        guard let walker = fileManager.enumerator(
            at: root, includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants])
        else { return false }
        var seen = 0
        for case let url as URL in walker {
            seen += 1
            if seen > maxEntries { return false }
            if walker.level >= maxDepth { walker.skipDescendants() }
            if url.lastPathComponent.lowercased() == fileName { return true }
        }
        return false
    }

    /// The game's root for the search: three levels above an Unreal `Binaries/Win64` exe, else the exe's own
    /// folder. Pure, for the tests.
    static func searchRoot(forExe exe: URL) -> URL {
        let dir = exe.deletingLastPathComponent()
        let parent = dir.deletingLastPathComponent()
        if dir.lastPathComponent.lowercased() == "win64", parent.lastPathComponent.lowercased() == "binaries" {
            return parent.deletingLastPathComponent().deletingLastPathComponent()
        }
        return dir
    }
}
