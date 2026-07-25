import Foundation

/// A Steam game discovered from the Steam bottle's `appmanifest_*.acf`.
public struct SteamApp: Codable, Sendable, Hashable, Identifiable {
    public var id: Int { appID }

    public let appID: Int
    public let name: String
    /// Folder name under `<library>/steamapps/common/`.
    public let installDir: String
    public let stateFlags: StateFlags
    public let sizeOnDisk: Int64
    public let bytesDownloaded: Int64?
    public let bytesToDownload: Int64?
    public let buildID: Int?
    public let lastUpdated: Date?
    /// Steam's `LastOwner` — the SteamID64 of the account that owns/installed this app. Steam writes `0`
    /// for the shared system packages it auto-installs (Steamworks Common Redistributables, runtimes,
    /// tools) rather than games the user owns. Used to keep those out of the library.
    public let lastOwner: Int64?
    /// The library-folder root this app belongs to (derived during discovery, not from the .acf).
    public let libraryPath: URL

    public init(
        appID: Int,
        name: String,
        installDir: String,
        stateFlags: StateFlags,
        sizeOnDisk: Int64,
        bytesDownloaded: Int64? = nil,
        bytesToDownload: Int64? = nil,
        buildID: Int? = nil,
        lastUpdated: Date? = nil,
        lastOwner: Int64? = nil,
        libraryPath: URL
    ) {
        self.appID = appID
        self.name = name
        self.installDir = installDir
        self.stateFlags = stateFlags
        self.sizeOnDisk = sizeOnDisk
        self.bytesDownloaded = bytesDownloaded
        self.bytesToDownload = bytesToDownload
        self.buildID = buildID
        self.lastUpdated = lastUpdated
        self.lastOwner = lastOwner
        self.libraryPath = libraryPath
    }

    public var isFullyInstalled: Bool { stateFlags.isFullyInstalled }

    /// A shared system package Steam auto-installs (redistributables, runtimes, tools) — `LastOwner` is
    /// `0`/absent because no user owns it. These aren't games, so the library hides them. A user-owned
    /// game always carries the owner's SteamID64 here. (Distinct from the install dir having an exe —
    /// real games can keep their exe nested, so exe-presence is not a reliable signal.)
    ///
    /// `LastOwner == 0` isn't fully reliable in practice, though: a confirmed real-world install had
    /// 228980 (Steamworks Common Redistributables) with `LastOwner` set to the user's own SteamID64,
    /// not 0 — Steam doesn't always follow its own convention. `knownSystemAppIDs` is a fallback for
    /// well-known, stable system-package AppIDs that should always be hidden regardless of `LastOwner`.
    public var isSharedSystemApp: Bool { (lastOwner ?? 0) == 0 || Self.knownSystemAppIDs.contains(appID) }

    /// Stable, well-known Steam AppIDs for shared system packages (never real games), used as a fallback
    /// when `LastOwner` doesn't follow Steam's usual "0 for system packages" convention.
    /// - 228980: Steamworks Common Redistributables (DirectX/VC++/etc. installers bundled with many games).
    static let knownSystemAppIDs: Set<Int> = [228980]

    /// Library cover art (Steam CDN `header.jpg`).
    public var headerArtURL: URL? {
        URL(string: "https://cdn.cloudflare.steamstatic.com/steam/apps/\(appID)/header.jpg")
    }
    /// Public Steam store page.
    public var storePageURL: URL? { URL(string: "https://store.steampowered.com/app/\(appID)") }

    /// Absolute on-disk install directory: `<library>/steamapps/common/<installDir>`.
    public var installURL: URL {
        libraryPath
            .appendingPathComponent("steamapps", isDirectory: true)
            .appendingPathComponent("common", isDirectory: true)
            .appendingPathComponent(installDir, isDirectory: true)
    }
}
