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
    @State private var artwork: NSImage?

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
        guard store.isStale(appID: appID) else { return }   // fresh enough — don't spend a request
        let steamStore = env.steamStore
        let guessed = game.headerArtURL
        let refreshed = await Task.detached { () -> URL? in
            await store.refresh(appID: appID, guessed: guessed, store: steamStore)
        }.value
        if let refreshed, let image = NSImage(contentsOf: refreshed) { artwork = image }
    }
}

struct SteamGameTileView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.openWindow) private var openWindow
    let game: SteamApp
    let onSettings: () -> Void
    let onDetails: () -> Void
    @State private var confirmingUninstall = false

    var body: some View {
        let lib = env.gameLibrary
        GameTileCard(
            title: game.name,
            isBusy: lib.isBusy(game), canLaunch: lib.canLaunch,
            helpText: "Show details",
            onPlay: { Task { await lib.play(game) } },
            onTap: onDetails
        ) {
            SteamHeaderArt(game: game)
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
        Button("Create Desktop Shortcut") {
            Task {
                guard let app = await env.gameLibrary.makeShortcut(for: game) else { return }
                // The game's own icon first — square, and sharp. The header art is the last resort because
                // it's 460×215 and a square icon has to squash it. Each step is best-effort; falling all the
                // way through just leaves the generic app icon, as before.
                let exeIcon: NSImage?
                if let logged = ShortcutFinalize.loggedExecutable(
                    logFile: env.paths.log(forAppID: game.appID)) {
                    exeIcon = await ShortcutFinalize.executableIcon(at: logged)
                } else {
                    exeIcon = await ShortcutFinalize.firstIconBearingExecutable(in: game.installURL)
                }
                // An `if`, not `??`: the right-hand side of `??` is an autoclosure, and that can't be
                // async. The header art is still only reached when the executable gave nothing.
                var final = exeIcon
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
