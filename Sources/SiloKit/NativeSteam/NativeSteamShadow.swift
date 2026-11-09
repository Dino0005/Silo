import Darwin
import Foundation

/// An APFS copy-on-write "shadow" of every installed Windows game, so that a wipe by macOS Steam is undone in
/// seconds instead of days of downloads.
///
/// Why: `AppInfoPatcher.protectWindowsInstall` keeps Steam from deleting a Windows game, but Steam replaces the
/// patched entry with Valve's (Windows-only) one mid-session when the game's metadata really changes on the
/// server; if that game then updates in the same session, Steam commits an empty Mac depot set and deletes it
/// (measured 2026-11-08/09: five games lost, "0 mounted depots" in `content_log.txt`).
///
/// How: `<library>/.silo-shadow/<appid>/` holds `files/` — a `clonefile(2)` of `steamapps/common/<installdir>`
/// — and `appmanifest.acf`, the manifest it matches. A clone shares every block with the original, so it costs
/// almost nothing until Steam replaces files; it is refreshed only when the manifest changed (after an update),
/// which releases the replaced blocks. When a manifest shows a wiped install (no installed depots, size 0) and
/// a shadow exists, the files and the manifest are cloned back — Steam then sees the game installed at its old
/// build and updates it normally. A shadow whose game is no longer installed is deleted.
/// Only with Steam closed (the guard runs it after every Steam exit); nothing is ever asked of the user.
public struct NativeSteamShadow: Sendable {
    public static let folderName = ".silo-shadow"

    public enum Action: Sendable, Equatable {
        case created(UInt32)
        case refreshed(UInt32)
        case restored(UInt32)
        case removed(UInt32)
        case failed(UInt32, String)
    }

    /// What the shadow needs from an `appmanifest_<id>.acf`.
    public struct Manifest: Sendable, Equatable {
        public var appID: UInt32
        public var installDir: String
        public var stateFlags: Int
        public var buildID: String
        public var lastUpdated: String
        public var installedDepots: Int
        public var sizeOnDisk: Int64

        /// Fully installed (StateFlags 4 only — not mid-update) with real content.
        public var isHealthy: Bool { stateFlags == 4 && installedDepots > 0 && sizeOnDisk > 0 }
        /// What a wipe leaves behind: the manifest stays, its depot list and size go to nothing.
        public var looksWiped: Bool { installedDepots == 0 && sizeOnDisk == 0 }
        /// The same installed build as `other`.
        func sameBuild(as other: Manifest) -> Bool {
            buildID == other.buildID && lastUpdated == other.lastUpdated && installedDepots == other.installedDepots
        }

        public init?(text: String) {
            guard let node = try? KeyValuesParser().parse(text: text), let state = node["AppState"],
                  let id = state["appid"]?.stringValue.flatMap(UInt32.init),
                  let dir = state["installdir"]?.stringValue,
                  !dir.isEmpty, !dir.contains("/"), dir != ".", dir != ".." else { return nil }
            appID = id
            installDir = dir
            stateFlags = state["StateFlags"]?.stringValue.flatMap(Int.init) ?? 0
            buildID = state["buildid"]?.stringValue ?? ""
            lastUpdated = state["LastUpdated"]?.stringValue ?? ""
            installedDepots = state["InstalledDepots"]?.pairs.count ?? 0
            sizeOnDisk = state["SizeOnDisk"]?.stringValue.flatMap(Int64.init) ?? 0
        }
    }

    private let isSteamRunning: @Sendable () -> Bool
    private let clone: @Sendable (URL, URL) throws -> Void

    public init(isSteamRunning: @escaping @Sendable () -> Bool,
                clone: @escaping @Sendable (URL, URL) throws -> Void = NativeSteamShadow.cloneFile) {
        self.isSteamRunning = isSteamRunning
        self.clone = clone
    }

    public struct CloneError: Error, Equatable { public let errno: Int32 }

    /// `clonefile(2)`: a copy-on-write clone of a file or a whole directory tree (APFS, same volume only).
    public static func cloneFile(_ source: URL, _ destination: URL) throws {
        if Darwin.clonefile(source.path, destination.path, UInt32(CLONE_NOFOLLOW)) != 0 { throw CloneError(errno: errno) }
    }

    /// Restores wiped games, refreshes changed shadows, drops orphaned ones — in every library.
    /// - Parameter windowsGames: the installed apps to look after (`NativeSteamInstaller.installedWindowsGameIDs`).
    public func sync(libraries: [URL], windowsGames: Set<UInt32>, fileManager: FileManager = .default) -> [Action] {
        guard !isSteamRunning() else { return [] }
        var actions: [Action] = []
        for library in libraries where fileManager.fileExists(atPath: library.path) {
            actions += sync(library: library, windowsGames: windowsGames, fileManager: fileManager)
        }
        return actions
    }

    private func sync(library: URL, windowsGames: Set<UInt32>, fileManager: FileManager) -> [Action] {
        let steamapps = library.appendingPathComponent("steamapps", isDirectory: true)
        let root = library.appendingPathComponent(Self.folderName, isDirectory: true)
        var actions: [Action] = []
        var installed: Set<UInt32> = []

        for name in (try? fileManager.contentsOfDirectory(atPath: steamapps.path)) ?? []
        where name.hasPrefix("appmanifest_") && name.hasSuffix(".acf") {
            let manifestURL = steamapps.appendingPathComponent(name)
            guard let text = try? String(contentsOf: manifestURL, encoding: .utf8),
                  let manifest = Manifest(text: text) else { continue }
            installed.insert(manifest.appID)
            guard windowsGames.contains(manifest.appID) else { continue }

            let shadow = root.appendingPathComponent(String(manifest.appID), isDirectory: true)
            let shadowManifestURL = shadow.appendingPathComponent("appmanifest.acf")
            let shadowManifest = (try? String(contentsOf: shadowManifestURL, encoding: .utf8)).flatMap(Manifest.init)
            let gameDir = steamapps.appendingPathComponent("common/\(manifest.installDir)", isDirectory: true)

            do {
                if manifest.looksWiped, let saved = shadowManifest, saved.isHealthy {
                    try restore(shadow: shadow, savedManifest: shadowManifestURL, to: gameDir, manifest: manifestURL,
                                fileManager: fileManager)
                    actions.append(.restored(manifest.appID))
                } else if manifest.isHealthy, shadowManifest.map({ !$0.sameBuild(as: manifest) }) ?? true,
                          fileManager.fileExists(atPath: gameDir.path) {
                    let existed = shadowManifest != nil
                    try refresh(shadow: shadow, root: root, from: gameDir, manifest: manifestURL, fileManager: fileManager)
                    actions.append(existed ? .refreshed(manifest.appID) : .created(manifest.appID))
                }
            } catch {
                actions.append(.failed(manifest.appID, "\(error)"))
            }
        }

        // A game uninstalled (or moved to another library) takes its shadow with it, so its space comes back.
        for name in (try? fileManager.contentsOfDirectory(atPath: root.path)) ?? [] {
            guard let id = UInt32(name), !installed.contains(id) else { continue }
            if (try? fileManager.removeItem(at: root.appendingPathComponent(name))) != nil { actions.append(.removed(id)) }
        }
        return actions
    }

    /// Builds the new shadow beside the old one, then swaps: a failure never leaves a game without a shadow.
    private func refresh(shadow: URL, root: URL, from gameDir: URL, manifest: URL, fileManager: FileManager) throws {
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        let staging = root.appendingPathComponent(".new-\(shadow.lastPathComponent)", isDirectory: true)
        try? fileManager.removeItem(at: staging)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        do {
            try clone(gameDir, staging.appendingPathComponent("files", isDirectory: true))
            try clone(manifest, staging.appendingPathComponent("appmanifest.acf"))
        } catch {
            try? fileManager.removeItem(at: staging)
            throw error
        }
        try? fileManager.removeItem(at: shadow)
        try fileManager.moveItem(at: staging, to: shadow)
    }

    /// Clones the shadow back over a wiped game: its files, then the manifest that matches them. The shadow
    /// stays as it was (it still matches the restored install).
    private func restore(shadow: URL, savedManifest: URL, to gameDir: URL, manifest: URL,
                         fileManager: FileManager) throws {
        guard !isSteamRunning() else { throw CloneError(errno: EBUSY) }
        let files = shadow.appendingPathComponent("files", isDirectory: true)
        let staging = gameDir.deletingLastPathComponent()
            .appendingPathComponent(".silo-restore-\(gameDir.lastPathComponent)", isDirectory: true)
        try? fileManager.removeItem(at: staging)
        try clone(files, staging)
        // What the wipe left (a few empty folders, steam_appid.txt) goes; the clone takes its place.
        try? fileManager.removeItem(at: gameDir)
        try fileManager.moveItem(at: staging, to: gameDir)
        let manifestStaging = manifest.deletingLastPathComponent().appendingPathComponent(".silo-restore-\(manifest.lastPathComponent)")
        try? fileManager.removeItem(at: manifestStaging)
        try clone(savedManifest, manifestStaging)
        _ = try fileManager.replaceItemAt(manifest, withItemAt: manifestStaging)
    }
}
