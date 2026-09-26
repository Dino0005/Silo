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
        Button("Create Shortcut") {
            Task {
                guard let app = await env.gameLibrary.makeShortcut(for: game) else { return }
                // A hand-supplied icon wins outright and keeps its own shape — the same escape hatch Steam
                // titles have, and reached for more often here: there's no store artwork to fall back on.
                if let mine = ShortcutFinalize.userIcon(id: game.id.uuidString,
                                                        coversDir: env.paths.coversDir) {
                    ShortcutFinalize.apply(icon: mine, to: app, shaped: false)
                    return
                }
                // Otherwise the game's own icon, parsed from its .exe and built like its host bundle's:
                // the bundle's own `.icns`, no mask (see `ShortcutFinalize.executableIcns`).
                if let icns = await ShortcutFinalize.executableIcns(at: game.executablePath),
                   ShortcutFinalize.apply(icns: icns, to: app) { return }
                ShortcutFinalize.apply(icon: nil, to: app)
            }
        }
        Button("View in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([game.executablePath])
        }
        Divider()
        Button("Remove…", role: .destructive) { confirmingRemove = true }
    }
}

/// A manual game's tile artwork: a chosen cover, else the icon embedded in its `.exe` if one can be
/// extracted, else the generic placeholder. Both files are read off the main thread, once, and cached.
struct ManualGameArtwork: View {
    let exe: URL
    /// A chosen cover, already resolved to an existing file. Wins over the `.exe` icon and fills the tile
    /// the way Steam artwork does; a cover deleted from Finder resolves to nil and the icon comes back.
    var cover: URL? = nil
    @State private var icon: NSImage?
    @State private var art: NSImage?

    var body: some View {
        // The gradient always; the controller only when there's nothing else. The placeholder draws that
        // glyph itself, so leaving it on put a controller UNDER the game's own icon — both visible at once,
        // since an icon is padded rather than full-bleed. Invisible until `PEIcon` started returning icons.
        let hasArt = art != nil || icon != nil
        ZStack {
            GameArtworkPlaceholder(showsGlyph: !hasArt)
            if let art {
                Image(nsImage: art).resizable().aspectRatio(contentMode: .fill)
            } else if let icon {
                Image(nsImage: icon).resizable().aspectRatio(contentMode: .fit).padding(14)
            }
        }
        // Both images are loaded HERE, not in `body`. The cover used to be read with
        // `NSImage(contentsOf:)` inline, which meant every redraw of the grid re-read it from disk on the
        // main thread — and the grid redraws on anything the library publishes, a keystroke in the search
        // field included. The id covers everything the two loads depend on, the cover's own mtime among
        // them, so a replaced cover still reloads.
        .task(id: [exe.path, ManualIconCache.coverStamp(cover)]) { await load() }
    }

    private func load() async {
        if let cover {
            art = await ManualIconCache.shared.cover(at: cover, stamp: ManualIconCache.coverStamp(cover))
        } else {
            art = nil
        }
        // Only when no cover is drawn — a cover wins, and `nil` art from an unreadable file still falls
        // back to the icon, the way the inline read did.
        icon = art == nil ? await ManualIconCache.shared.icon(for: exe) : nil
    }
}

/// Caches a manual game's tile images — the icon extracted from its `.exe`, and a chosen cover — so a tile
/// (or a re-render) reads each file at most once. A parsed "no icon" result is cached too (stored as
/// `.some(nil)`), so files without an icon aren't re-parsed.
@MainActor
final class ManualIconCache {
    static let shared = ManualIconCache()
    private var cache: [String: NSImage?] = [:]
    private var covers: [String: NSImage?] = [:]

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

    /// A chosen cover, keyed by `stamp` rather than by path: `CoverArtStore` names the file after the game,
    /// so picking a second cover with the same extension lands on the very same path. The stamp carries the
    /// file's own modification date and size, which a replacement changes — see `coverStamp`.
    func cover(at url: URL, stamp: String) async -> NSImage? {
        if let cached = covers[stamp] { return cached }
        let data: Data? = await Task.detached(priority: .utility) { try? Data(contentsOf: url) }.value
        let image = data.flatMap { NSImage(data: $0) }
        covers[stamp] = image
        return image
    }

    /// Identity of the file at `url` for cache/task-id purposes: path, modification date, size. "" when
    /// there's no file, so a game without a cover — and one whose cover was deleted in Finder — has one
    /// stable key.
    ///
    /// Asked of `FileManager`, not of `URL.resourceValues`: a `URL` CACHES the values it has already been
    /// asked for, so the same instance kept answering with the old date and size after the file underneath
    /// it had been replaced — which is the one thing this has to notice.
    static func coverStamp(_ url: URL?) -> String {
        guard let url,
              let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        else { return "" }
        let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let size = (attributes[.size] as? Int) ?? 0
        return "\(url.path)|\(modified)|\(size)"
    }
}
