import SwiftUI
import AppKit

/// A library tile for a manual (non-Steam) game. Play launches its `.exe` in the game's isolated bottle
/// under its resolved graphics backend (Automatic/GPTK/DXMT); the menu exposes Settings, Log, Wine config,
/// a Desktop shortcut, Finder, and Remove (which forgets the entry, not the files).
struct ManualGameTileView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.openWindow) private var openWindow
    let game: ManualGame
    let onSettings: () -> Void
    /// Opens the game card. Called instead of `onSettings` only when the game has a Steam association —
    /// without one there's nothing to show, so the tile keeps its original behaviour.
    let onDetails: () -> Void
    @State private var confirmingRemove = false

    var body: some View {
        let lib = env.gameLibrary
        GameTileCard(
            title: game.name,
            isBusy: lib.isBusy(game), canLaunch: lib.canLaunch,
            helpText: game.steamAppID == nil ? "Edit settings" : "Show details",
            onPlay: { Task { await lib.playManual(game) } },
            onTap: game.steamAppID == nil ? onSettings : onDetails
        ) {
            ManualGameArtwork(exe: game.executablePath,
                              cover: CoverArtStore(coversDir: env.paths.coversDir)
                                  .url(named: game.coverArtFileName))
        } subtitle: {
            Text("Non-Steam game").font(.caption).foregroundStyle(.secondary)
            BackendTag(choice: game.graphics)
        } menuItems: {
            menuItems()
        }
        .confirmationDialog("Remove \(game.name)?", isPresented: $confirmingRemove, titleVisibility: .visible) {
            Button("Remove", role: .destructive) { Task { await env.gameLibrary.removeManual(game) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Removes it from your library. The installed files on disk are left untouched.")
        }
    }

    @ViewBuilder private func menuItems() -> some View {
        Button("Settings…", action: onSettings)
        Button("View Log") {
            openWindow(id: LogTarget.windowID,
                       value: LogTarget(title: "\(game.name) — Log", url: env.paths.manualLog(game.id)))
        }
        Button("Run Program…") {
            // Same action as the settings sheet's button, one click closer: a language selector or a
            // configuration tool is something you reach for without wanting to open settings first.
            if let program = chooseExecutable(
                message: String(localized: "Choose an .exe or .msi to run in this game's bottle — an installer, a configuration tool."),
                installer: true) {
                Task { await env.gameLibrary.runInstaller(program, forBottle: game.bottleID) }
            }
        }
        Button("Wine Config…") { Task { await env.gameLibrary.openManualWinecfg(game) } }
        Button("Game Controllers…") {
            Task { await env.gameLibrary.openManualGameControllers(game) }
        }
            .disabled(!env.gameLibrary.canLaunch)
        Button("Create Desktop Shortcut") {
            Task {
                guard let app = await env.gameLibrary.makeShortcut(for: game) else { return }
                // Best-effort: stamp the game's own icon (parsed from its .exe) on the shortcut, then reveal it.
                let icon = await ManualIconCache.shared.icon(for: game.executablePath)
                ShortcutFinalize.apply(icon: icon, to: app)
            }
        }
        Button("View in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([game.executablePath])
        }
        Divider()
        Button("Remove…", role: .destructive) { confirmingRemove = true }
    }
}

/// A manual game's tile artwork: the icon embedded in its `.exe` if one can be extracted, else the generic
/// placeholder. The PE is parsed off the main thread, once, and the result cached by exe path.
struct ManualGameArtwork: View {
    let exe: URL
    /// A chosen cover, already resolved to an existing file. Wins over the `.exe` icon and fills the tile
    /// the way Steam artwork does; a cover deleted from Finder resolves to nil and the icon comes back.
    var cover: URL? = nil
    @State private var icon: NSImage?

    var body: some View {
        // The gradient always; the controller only when there's nothing else. The placeholder draws that
        // glyph itself, so leaving it on put a controller UNDER the game's own icon — both visible at once,
        // since an icon is padded rather than full-bleed. Invisible until `PEIcon` started returning icons.
        let hasArt = cover != nil || icon != nil
        ZStack {
            GameArtworkPlaceholder(showsGlyph: !hasArt)
            if let cover, let art = NSImage(contentsOf: cover) {
                Image(nsImage: art).resizable().aspectRatio(contentMode: .fill)
            } else if let icon {
                Image(nsImage: icon).resizable().aspectRatio(contentMode: .fit).padding(14)
            }
        }
        .task(id: exe) { icon = await ManualIconCache.shared.icon(for: exe) }
    }
}

/// Caches extracted `.exe` icons by path so a tile (or a re-render) parses the PE at most once. A parsed
/// "no icon" result is cached too (stored as `.some(nil)`), so files without an icon aren't re-parsed.
@MainActor
final class ManualIconCache {
    static let shared = ManualIconCache()
    private var cache: [String: NSImage?] = [:]

    func icon(for exe: URL) async -> NSImage? {
        if let cached = cache[exe.path] { return cached }
        // Read + parse off the main thread (Data is Sendable); build the NSImage back on the main actor.
        let ico: Data? = await Task.detached(priority: .utility) {
            guard let data = try? Data(contentsOf: exe, options: .mappedIfSafe) else { return nil }
            return PEIcon.icoData(fromExecutable: data)
        }.value
        let image = ico.flatMap { NSImage(data: $0) }
        cache[exe.path] = image
        return image
    }
}
