import SwiftUI
import AppKit

/// Detail sheet for a manual (non-Steam) game whose owner has pointed Silo at a Steam app ID.
///
/// The Steam twin of `GameDetailView`, with two deliberate differences. There's no **Store** button: the
/// copy being played wasn't bought there, and sending someone to a shop page for a game they already own
/// is worse than omitting the button. And the destructive action is **Remove**, not Uninstall — for a
/// manual game it forgets the entry and its bottle and leaves the installed files alone, so calling it
/// Uninstall would promise something it doesn't do.
///
/// Only ever presented when `game.steamAppID` is set; without one the tile opens the settings sheet, as it
/// always has.
struct ManualGameDetailView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss
    let game: ManualGame
    let onSettings: () -> Void
    @State private var details: SteamStoreDetails?
    @State private var loading = true
    @State private var showRequirements = false
    @State private var confirmingRemove = false

    var body: some View {
        let lib = env.gameLibrary
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    hero
                    actions(lib)

                    if loading && details == nil {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Loading details…").foregroundStyle(.secondary)
                        }
                    }
                    if let d = details {
                        if !d.genres.isEmpty { chips(d.genres) }
                        if let desc = d.shortDescription, !desc.isEmpty {
                            Text(desc).font(.callout).foregroundStyle(.secondary)
                        }
                        metadata(d)
                        requirements(d)
                    }
                }
                .padding(20)
            }
            .navigationTitle(game.name)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .frame(width: 560, height: 620)
        .task {
            guard let appID = game.steamAppID else { loading = false; return }
            details = await env.steamStore.details(appID: appID)
            loading = false
        }
    }

    /// The stored cover wins over the store's header: it's the image the user chose (or the one the
    /// association downloaded), it lives on disk, and it draws with no network.
    @ViewBuilder private var hero: some View {
        let cover = CoverArtStore(coversDir: env.paths.coversDir).url(named: game.coverArtFileName)
        if let cover, let art = NSImage(contentsOf: cover) {
            Image(nsImage: art).resizable().aspectRatio(contentMode: .fit)
                .frame(maxWidth: .infinity).clipShape(RoundedRectangle(cornerRadius: 12))
        } else {
            AsyncImage(url: details?.headerImageURL) { phase in
                switch phase {
                case .success(let image): image.resizable().aspectRatio(contentMode: .fit)
                default: GameArtworkPlaceholder(iconFont: .largeTitle)
                        .aspectRatio(460.0 / 215.0, contentMode: .fit)
                }
            }
            .frame(maxWidth: .infinity).clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }

    @ViewBuilder private func actions(_ lib: GameLibraryViewModel) -> some View {
        HStack(spacing: 10) {
            Button { Task { await lib.playManual(game) } } label: { Label("Play", systemImage: "play.fill") }
                .buttonStyle(.borderedProminent).disabled(!lib.canLaunch || lib.isBusy(game))
            Button("Settings…", action: onSettings)
            Button("Log") {
                openWindow(id: LogTarget.windowID,
                           value: LogTarget(title: "\(game.name) — Log",
                                            url: env.paths.manualLog(game.id)))
            }
            Spacer()
            Button(role: .destructive) { confirmingRemove = true } label: {
                Label("Remove", systemImage: "trash")
            }
        }
        // Same wording as the tile's menu — it forgets the entry, it doesn't delete the game.
        .confirmationDialog("Remove \(game.name)?", isPresented: $confirmingRemove,
                            titleVisibility: .visible) {
            Button("Remove", role: .destructive) {
                Task { await lib.removeManual(game); dismiss() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Removes it from your library. The installed files on disk are left untouched.")
        }
    }

    @ViewBuilder private func chips(_ items: [String]) -> some View {
        HStack {
            ForEach(items.prefix(5), id: \.self) { genre in
                Text(genre).font(.caption)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(.quaternary, in: Capsule())
            }
        }
    }

    @ViewBuilder private func metadata(_ d: SteamStoreDetails) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if !d.developers.isEmpty {
                LabeledContent("Developer", value: d.developers.joined(separator: ", "))
            }
            if !d.publishers.isEmpty {
                LabeledContent("Publisher", value: d.publishers.joined(separator: ", "))
            }
            if let date = d.releaseDate, !date.isEmpty { LabeledContent("Released", value: date) }
            // No installed size here: a manual game's files live wherever the user put them, so the
            // store's minimum-spec figure is the only honest number available.
            if let space = d.diskSpace { LabeledContent("Disk size", value: space) }
            if let metacritic = d.metacritic { LabeledContent("Metacritic", value: "\(metacritic)") }
        }
        .font(.callout)
    }

    @ViewBuilder private func requirements(_ d: SteamStoreDetails) -> some View {
        if let req = d.minimumRequirements, !req.isEmpty {
            DisclosureGroup("Minimum requirements", isExpanded: $showRequirements) {
                Text(req).font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
            }
            .font(.callout)
        }
    }
}
