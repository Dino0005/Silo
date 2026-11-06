import SwiftUI
import AppKit

/// A library tile for a game installed in the Steam bottle (`SteamApp`). Play launches it co-resident
/// with the bottle's Steam client; the menu exposes Settings, Log, Wine config, Finder, Uninstall.
/// A Steam game's tile artwork, served from disk and refreshed behind it.
///
/// Not `AsyncImage`: that redraws from the network every time, which leaves the tiles blank with no
/// connection and has nothing to fall back on when an app has no `header.jpg` at all. The stored file
/// shows first — instantly, offline included — and the refresh only replaces it once new bytes have
/// actually arrived, so a failed fetch never blanks a tile that was drawing fine.
struct SteamHeaderArt: View {
    @Environment(AppEnvironment.self) private var env
    let game: SteamApp
    @ViewState private var artwork: NSImage?

    var body: some View {
        ZStack {
            GameArtworkPlaceholder()
            if let artwork {
                Image(nsImage: artwork).resizable().aspectRatio(contentMode: .fill)
            }
        }
        .task(id: game.appID) { await load() }
    }

    private func load() async {
        let store = SteamArtworkStore(dir: env.paths.artworkDir)
        let appID = game.appID
        if let cached = store.cached(appID: appID), let image = NSImage(contentsOf: cached) {
            artwork = image
        }
        guard store.isMissing(appID: appID) else { return }   // already on disk — nothing to fetch
        let steamStore = env.steamStore
        let guessed = game.headerArtURL
        let refreshed = await Task.detached { () -> URL? in
            await store.refresh(appID: appID, guessed: guessed, store: steamStore)
        }.value
        if let refreshed, let image = NSImage(contentsOf: refreshed) { artwork = image }
    }
}

/// Steam's portrait cover for a tile, read from the bottle client's own `librarycache` (nothing fetched).
/// Without one, the landscape `fallback` is shown whole, over a blurred copy of itself filling the tile.
struct SteamPortraitArt<Fallback: View>: View {
    @Environment(AppEnvironment.self) private var env
    let appID: Int
    @ViewBuilder let fallback: () -> Fallback
    @ViewState private var portrait: NSImage?
    @ViewState private var looked = false

    var body: some View {
        ZStack {
            if let portrait {
                Image(nsImage: portrait).resizable().aspectRatio(contentMode: .fill)
            } else if looked {
                fallback().blur(radius: 24).overlay(Color.black.opacity(0.25))
                fallback()
                    .aspectRatio(TileStyle.headerAspect, contentMode: .fit)
                    .clipped()
            } else {
                GameArtworkPlaceholder()
            }
        }
        .task(id: appID) { await load() }
    }

    /// The stored HD copy first; else what the bottle's Steam already has, shown at once; then the CDN,
    /// asked once per session per app (a 404 isn't retried on every redraw).
    private func load() async {
        let store = SteamArtworkStore(dir: env.paths.artworkDir)
        let appID = appID
        if let stored = store.cachedPortrait(appID: appID), let image = NSImage(contentsOf: stored) {
            portrait = image
            looked = true
            return
        }
        let dirs = AppPaths.SteamBottleKind.allCases.map { env.paths.steamBottleClientDir($0) }
        // Off the main actor: the bottles can live on a slow external drive.
        let local = await Task.detached { SteamLibraryCache.portrait(appID: appID, clientDirs: dirs) }.value
        if let local, let image = NSImage(contentsOf: local) { portrait = image }
        if !PortraitFetchMemo.tried.contains(appID) {
            PortraitFetchMemo.tried.insert(appID)
            let fetched = await Task.detached { await store.refreshPortrait(appID: appID) }.value
            if let fetched, let image = NSImage(contentsOf: fetched) { portrait = image }
        }
        looked = true
    }
}

/// A game's app icon for the `.icons` tile: its host app's icon as macOS draws it (already in the system's
/// rounded-square shape), the same one Apple's Games app shows. A game never launched has no host app yet;
/// it gets `fallback` cropped to the same rounded square.
struct GameAppIcon<Fallback: View>: View {
    @Environment(AppEnvironment.self) private var env
    /// The host app's folder name: the Steam app ID, or a manual game's UUID.
    let hostID: String
    @ViewBuilder let fallback: () -> Fallback
    @ViewState private var icon: NSImage?
    @ViewState private var looked = false

    var body: some View {
        Group {
            if let icon {
                Image(nsImage: icon).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
            } else if looked {
                // Inset like a system icon, which leaves a margin inside its frame. Framed square and
                // clipped first: the artwork fills, and unframed it spilled over the title beside it.
                let side = TileStyle.iconSize * 0.84
                fallback()
                    .frame(width: side, height: side)
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: TileStyle.iconSize * 0.2, style: .continuous))
                    .frame(width: TileStyle.iconSize, height: TileStyle.iconSize)
            } else {
                Color.clear
            }
        }
        .task(id: hostID) {
            if let app = HostAppLookup.bundle(forID: hostID, in: env.paths.hostAppsDir) {
                let image = NSWorkspace.shared.icon(forFile: app.path)
                image.size = NSSize(width: 512, height: 512)   // ask for a large representation
                icon = image
            }
            looked = true
        }
    }
}

/// App IDs whose portrait cover was already asked of the CDN this session.
@MainActor enum PortraitFetchMemo {
    static var tried: Set<Int> = []
}

struct SteamGameTileView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.openWindow) private var openWindow
    let game: SteamApp
    let onSettings: () -> Void
    let onDetails: () -> Void
    @ViewState private var confirmingUninstall = false

    var body: some View {
        let lib = env.gameLibrary
        GameTileCard(
            title: game.name,
            isBusy: lib.isBusy(game), canLaunch: lib.canLaunch,
            helpText: "Show details",
            onPlay: { Task { await lib.play(game) } },
            onTap: onDetails
        ) { style in
            if style == .portrait {
                SteamPortraitArt(appID: game.appID) { SteamHeaderArt(game: game) }
            } else if style == .icons {
                GameAppIcon(hostID: String(game.appID)) { SteamHeaderArt(game: game) }
            } else {
                SteamHeaderArt(game: game)
            }
        } subtitle: {
            if let size = lib.sizeString(game) {
                Text(size).font(.caption).foregroundStyle(.secondary)
            }
            if let badges = lib.steamBadges[game.appID] {
                BackendTag(choice: badges.graphics)
                if badges.mediaFoundation { MediaFoundationTag() }
            }
        } menuItems: {
            menuItems()
        }
        .uninstallConfirmation(game: game, isPresented: $confirmingUninstall, library: env.gameLibrary)
    }

    @ViewBuilder private func menuItems() -> some View {
        Button("Details…", action: onDetails)
        Button("Settings…", action: onSettings)
        Button("View Log") {
            openWindow(id: LogTarget.windowID,
                       value: LogTarget(title: "\(game.name) — Log",
                                        url: env.logURL(forAppID: game.appID)))
        }
        // Both carry the appID so they open the bottle this game actually runs in — with Media
        // Foundation on, that's the MF bottle, and configuring the other one would be meaningless.
        Button("Wine Config…") { Task { await env.gameLibrary.openWinecfg(appID: game.appID) } }
        Button("Game Controllers…") {
            Task { await env.gameLibrary.openGameControllers(appID: game.appID) }
        }
            .disabled(!env.gameLibrary.canLaunch)
        Button("Create Shortcut") {
            Task {
                guard let app = await env.gameLibrary.makeShortcut(for: game) else { return }
                // The game's own icon first — square, and sharp. The header art is the last resort because
                // it's 460×215 and a square icon has to squash it. Each step is best-effort; falling all the
                // way through just leaves the generic app icon, as before.
                // A hand-supplied icon wins outright, and keeps its own shape — see `userIcon`.
                if let mine = ShortcutFinalize.userIcon(id: String(game.appID),
                                                        coversDir: env.paths.coversDir) {
                    ShortcutFinalize.apply(icon: mine, to: app, shaped: false)
                    return
                }
                var exeIcns: Data? = nil
                if let logged = ShortcutFinalize.loggedExecutable(
                    logFile: env.paths.log(forAppID: game.appID)) {
                    // The same executable the host takes its icon from: an Unreal launcher's Shipping exe.
                    let owner = UnrealLauncher.shippingExecutable(forLauncher: logged) ?? logged
                    exeIcns = await ShortcutFinalize.executableIcns(at: owner)
                }
                if exeIcns == nil {
                    exeIcns = await ShortcutFinalize.firstIconBearingExecutable(in: game.installURL)
                }
                // The executable's icon goes in as the host's does — the bundle's own `.icns`, no mask.
                if let exeIcns, ShortcutFinalize.apply(icns: exeIcns, to: app) { return }
                // Header art only from here on — rectangular, so it DOES go through the mask.
                var final: NSImage? = nil
                if final == nil {
                    // The CACHED artwork before the network. `headerArtURL` is guessed from the app ID and
                    // 404s for some titles — 3764200 among them, which is why the tile cache exists at all —
                    // so asking the network first left that game's shortcut with no icon whatsoever, even
                    // though the right image was already sitting in Artwork/.
                    if let cached = SteamArtworkStore(dir: env.paths.artworkDir).cached(appID: game.appID) {
                        final = NSImage(contentsOf: cached)
                    }
                }
                if final == nil { final = await ShortcutFinalize.remoteIcon(game.headerArtURL) }
                ShortcutFinalize.apply(icon: final, to: app)
            }
        }
        Button("View in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([game.installURL])
        }
        if let store = game.storePageURL {
            Button("View on Steam Store") { NSWorkspace.shared.open(store) }
        }
        Divider()
        Button("Uninstall…", role: .destructive) { confirmingUninstall = true }
    }
}
