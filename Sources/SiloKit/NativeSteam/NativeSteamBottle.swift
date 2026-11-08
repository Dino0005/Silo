import Foundation

/// The bottle, and the bridge files, for Windows games started by macOS Steam.
///
/// The bottle is an APFS clone of the classic Steam bottle (decided 2026-11-08): it inherits the fonts, VC++
/// runtimes, d3dcompiler and Silo's defaults already installed there, and the same `x:`/`y:` library drives, so
/// games installed by macOS Steam into a shared library are found at the same paths. Its Windows Steam client
/// stays on disk but can't run: `steam.exe` becomes the bridge's stand-in (the original kept beside it).
///
/// Bridge layout (`AppPaths.nativeSteamBridgeDir`), the same names Wine uses:
/// `steam.exe`, `x86_64-windows/lsteamclient.dll`, `i386-windows/lsteamclient.dll`, `x86_64-unix/lsteamclient.so`.
/// ⚠️ For now filled by hand from the test kit (local only); Silo's own build of these is task A2.
public struct NativeSteamBottle: Sendable {
    public static let bridgeFiles = [
        "steam.exe", "x86_64-windows/lsteamclient.dll", "i386-windows/lsteamclient.dll", "x86_64-unix/lsteamclient.so",
    ]
    /// Where the classic bottle's real `steam.exe` is kept once the stand-in takes its place.
    public static let originalClientName = "steam.exe.windows-client"

    public enum Failure: Error, Equatable {
        case bridgeMissing([String])
        case sourceBottleMissing
    }

    public let paths: AppPaths
    private let cloner: BottleCloner

    public init(paths: AppPaths, runner: ProcessRunning) {
        self.paths = paths
        self.cloner = BottleCloner(runner: runner)
    }

    /// Bridge files not present in `nativeSteamBridgeDir`.
    public func missingBridgeFiles(fileManager: FileManager = .default) -> [String] {
        Self.bridgeFiles.filter {
            !fileManager.fileExists(atPath: paths.nativeSteamBridgeDir.appendingPathComponent($0).path)
        }
    }

    /// Makes sure the bottle exists (cloning the classic one the first time) and carries the stand-in client.
    public func ensureBottle(fileManager: FileManager = .default) async throws {
        let missing = missingBridgeFiles(fileManager: fileManager)
        guard missing.isEmpty else { throw Failure.bridgeMissing(missing) }
        let bottle = paths.nativeSteamBottle
        if !BottleCloner.isPrefix(bottle, fileManager: fileManager) {
            guard BottleCloner.isPrefix(paths.steamBottle, fileManager: fileManager) else {
                throw Failure.sourceBottleMissing
            }
            try await cloner.clone(from: paths.steamBottle, to: bottle)
        }
        let steamDir = bottle.appendingPathComponent("drive_c/Program Files (x86)/Steam", isDirectory: true)
        try fileManager.createDirectory(at: steamDir, withIntermediateDirectories: true)
        let client = steamDir.appendingPathComponent("steam.exe")
        let original = steamDir.appendingPathComponent(Self.originalClientName)
        let shim = paths.nativeSteamBridgeDir.appendingPathComponent("steam.exe")
        if fileManager.fileExists(atPath: client.path), !fileManager.fileExists(atPath: original.path),
           !fileManager.contentsEqual(atPath: client.path, andPath: shim.path) {
            try fileManager.moveItem(at: client, to: original)
        }
        try Self.copyIfDifferent(shim, to: client, fileManager: fileManager)
        // 32-bit games load lsteamclient from syswow64 (where Proton's own prefixes carry it).
        let syswow64 = bottle.appendingPathComponent("drive_c/windows/syswow64", isDirectory: true)
        if fileManager.fileExists(atPath: syswow64.path) {
            try Self.copyIfDifferent(paths.nativeSteamBridgeDir.appendingPathComponent("i386-windows/lsteamclient.dll"),
                                     to: syswow64.appendingPathComponent("lsteamclient.dll"), fileManager: fileManager)
        }
    }

    /// Puts `lsteamclient` into the runtime a launch uses, as builtin modules next to Wine's own — so no
    /// `WINEDLLPATH` is needed. Inert for every other launch: patch 0003 only loads it with `SILO_LSTEAMCLIENT=1`.
    /// Repeated at every launch because a Wine reinstall (or a fresh DXMT clone) starts without it.
    public func stageRuntime(wine: URL, fileManager: FileManager = .default) throws {
        let layout = WineRuntimeLayout(wineBinary: wine)
        let bridge = paths.nativeSteamBridgeDir
        try Self.copyIfDifferent(bridge.appendingPathComponent("x86_64-windows/lsteamclient.dll"),
                                 to: layout.windowsModulesDir(.x86_64).appendingPathComponent("lsteamclient.dll"),
                                 fileManager: fileManager)
        try Self.copyIfDifferent(bridge.appendingPathComponent("i386-windows/lsteamclient.dll"),
                                 to: layout.windowsModulesDir(.i386).appendingPathComponent("lsteamclient.dll"),
                                 fileManager: fileManager)
        try Self.copyIfDifferent(bridge.appendingPathComponent("x86_64-unix/lsteamclient.so"),
                                 to: layout.unixModulesDir(.x86_64).appendingPathComponent("lsteamclient.so"),
                                 fileManager: fileManager)
    }

    static func copyIfDifferent(_ source: URL, to destination: URL, fileManager: FileManager) throws {
        if fileManager.contentsEqual(atPath: source.path, andPath: destination.path) { return }
        try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temp = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).silo-\(UUID().uuidString)")
        try fileManager.copyItem(at: source, to: temp)
        if fileManager.fileExists(atPath: destination.path) {
            _ = try fileManager.replaceItemAt(destination, withItemAt: temp)
        } else {
            try fileManager.moveItem(at: temp, to: destination)
        }
    }
}
