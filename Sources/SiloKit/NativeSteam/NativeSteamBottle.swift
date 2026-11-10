import Foundation

/// The bottle, and the bridge files, for Windows games started by macOS Steam.
///
/// The bottle is an APFS clone of the classic Steam bottle (decided 2026-11-08): it inherits the fonts, VC++
/// runtimes, d3dcompiler and Silo's defaults already installed there, and the same `x:`/`y:` library drives, so
/// games installed by macOS Steam into a shared library are found at the same paths. Its Windows Steam client
/// stays on disk but can't run: `steam.exe` becomes the bridge's stand-in (the original kept beside it).
///
/// Bridge files, by the names Wine uses: `steam.exe`, `x86_64-windows/lsteamclient.dll`,
/// `i386-windows/lsteamclient.dll`, `x86_64-unix/lsteamclient.so`. They come from the Wine runtime when it was
/// built with them (`Scripts/add-lsteamclient.sh`: Valve's Proton sources + Silo's patches — lsteamclient in
/// `lib/wine`, the stand-in `steam.exe` in `share/silo/native-steam`), else from the hand-filled development
/// folder `AppPaths.nativeSteamBridgeDir` (local only, never shipped).
public struct NativeSteamBottle: Sendable {
    public static let bridgeFiles = [
        "steam.exe", "x86_64-windows/lsteamclient.dll", "i386-windows/lsteamclient.dll", "x86_64-unix/lsteamclient.so",
    ]

    /// Where `bridgeFiles` are read from.
    public enum BridgeSource: Sendable, Equatable {
        /// A runtime root (`<root>/bin/wine`) that ships the bridge.
        case runtime(URL)
        /// The development folder, laid out exactly like `bridgeFiles`.
        case devFolder(URL)

        public func url(for file: String) -> URL {
            switch self {
            case .runtime(let root):
                return file == "steam.exe"
                    ? root.appendingPathComponent("share/silo/native-steam/steam.exe")
                    : root.appendingPathComponent("lib/wine/\(file)")
            case .devFolder(let dir):
                return dir.appendingPathComponent(file)
            }
        }
    }
    /// Where the classic bottle's real `steam.exe` is kept once the stand-in takes its place.
    public static let originalClientName = "steam.exe.windows-client"

    public enum Failure: Error, Equatable {
        case bridgeMissing([String])
        case sourceBottleMissing
    }

    public let paths: AppPaths
    /// The Media Foundation variant: `SteamNativeMF`, cloned from the classic MF bottle instead of the Steam one.
    public let mediaFoundation: Bool
    private let cloner: BottleCloner

    public init(paths: AppPaths, runner: ProcessRunning, mediaFoundation: Bool = false) {
        self.paths = paths
        self.mediaFoundation = mediaFoundation
        self.cloner = BottleCloner(runner: runner)
    }

    /// This bottle's prefix.
    public var prefix: URL { mediaFoundation ? paths.nativeSteamBottleMF : paths.nativeSteamBottle }
    /// The classic bottle it is cloned from.
    public var sourcePrefix: URL { mediaFoundation ? paths.steamBottleMF : paths.steamBottle }

    /// The runtime of `wine` when it ships every bridge file, else the development folder.
    public func bridgeSource(wine: URL?, fileManager: FileManager = .default) -> BridgeSource {
        if let wine {
            let runtime = BridgeSource.runtime(WineRuntimeLayout(wineBinary: wine).root)
            if Self.missingBridgeFiles(in: runtime, fileManager: fileManager).isEmpty { return runtime }
        }
        return .devFolder(paths.nativeSteamBridgeDir)
    }

    /// Bridge files `source` doesn't have.
    public static func missingBridgeFiles(in source: BridgeSource, fileManager: FileManager = .default) -> [String] {
        bridgeFiles.filter { !fileManager.fileExists(atPath: source.url(for: $0).path) }
    }

    /// Makes sure the bottle exists (cloning the classic one the first time) and carries the stand-in client.
    public func ensureBottle(source: BridgeSource, fileManager: FileManager = .default) async throws {
        let missing = Self.missingBridgeFiles(in: source, fileManager: fileManager)
        guard missing.isEmpty else { throw Failure.bridgeMissing(missing) }
        let bottle = prefix
        if !BottleCloner.isPrefix(bottle, fileManager: fileManager) {
            guard BottleCloner.isPrefix(sourcePrefix, fileManager: fileManager) else {
                throw Failure.sourceBottleMissing
            }
            try await cloner.clone(from: sourcePrefix, to: bottle)
        }
        let steamDir = bottle.appendingPathComponent("drive_c/Program Files (x86)/Steam", isDirectory: true)
        try fileManager.createDirectory(at: steamDir, withIntermediateDirectories: true)
        let client = steamDir.appendingPathComponent("steam.exe")
        let original = steamDir.appendingPathComponent(Self.originalClientName)
        let shim = source.url(for: "steam.exe")
        if fileManager.fileExists(atPath: client.path), !fileManager.fileExists(atPath: original.path),
           !fileManager.contentsEqual(atPath: client.path, andPath: shim.path) {
            try fileManager.moveItem(at: client, to: original)
        }
        try Self.copyIfDifferent(shim, to: client, fileManager: fileManager)
        // Patch 0003 loads lsteamclient along steamclient64.dll's own load path — this folder — and finds it
        // nowhere else (measured 2026-11-08: with the copy only in the runtime's lib/wine, "lsteamclient.dll
        // could not be loaded" and the game asked Steam to restart it). Its unix half sits beside it.
        try Self.copyIfDifferent(source.url(for: "x86_64-windows/lsteamclient.dll"),
                                 to: steamDir.appendingPathComponent("lsteamclient.dll"), fileManager: fileManager)
        try Self.copyIfDifferent(source.url(for: "x86_64-unix/lsteamclient.so"),
                                 to: steamDir.appendingPathComponent("lsteamclient.so"), fileManager: fileManager)
        // 32-bit games load lsteamclient from syswow64 (where Proton's own prefixes carry it).
        let syswow64 = bottle.appendingPathComponent("drive_c/windows/syswow64", isDirectory: true)
        if fileManager.fileExists(atPath: syswow64.path) {
            try Self.copyIfDifferent(source.url(for: "i386-windows/lsteamclient.dll"),
                                     to: syswow64.appendingPathComponent("lsteamclient.dll"), fileManager: fileManager)
        }
    }

    /// Puts the development folder's `lsteamclient` into a runtime that wasn't built with it, as builtin modules
    /// next to Wine's own. Inert for every other launch: patch 0003 only loads it with `SILO_LSTEAMCLIENT=1`.
    /// ⚠️ The working TEKKEN launch loaded the copy in the bottle's Steam folder; whether this runtime copy is
    /// needed at all is still to be checked. Repeated at every launch because a Wine reinstall (or a fresh DXMT
    /// clone) starts without it. Not needed when `bridgeSource` is the runtime itself.
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
