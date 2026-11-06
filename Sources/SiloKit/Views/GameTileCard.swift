import SwiftUI

/// The shared library-tile chrome both game kinds render: the artwork band, title + subtitle row, the
/// two-state primary button (Play / Launching…), the overflow menu, and the hover / shadow / rounded-corner
/// treatment. There is no Stop button — Silo launches games detached and lets them (and Steam) run
/// independently of the app, like CrossOver; a game is quit from inside the game or Steam. Type-specific
/// pieces — artwork, subtitle row, menu items, tap action, and any confirmation dialogs — are injected by
/// `SteamGameTileView` / `ManualGameTileView`.
struct GameTileCard<Artwork: View, Subtitle: View, MenuItems: View>: View {
    let title: String
    let isBusy: Bool
    let canLaunch: Bool
    /// A LocalizedStringResource, not a String: a String arrives already resolved and never reaches
    /// Localizable.strings — which is why these two tooltips once stayed English in an Italian UI. Resolved
    /// here (`String(localized:)`, main bundle) only to join it to the title. Callers pass literals.
    let helpText: LocalizedStringResource
    let onPlay: () -> Void
    let onTap: () -> Void
    /// Given the tile style, so an artwork view can pick the image that suits it (the portrait cover).
    @ViewBuilder let artwork: (TileStyle) -> Artwork
    @ViewBuilder let subtitle: () -> Subtitle
    @ViewBuilder let menuItems: () -> MenuItems

    @ViewState private var hovering = false
    @AppStorage(TileStyle.storageKey) private var style: TileStyle = .classic

    var body: some View {
        layout
            // The icon row has no card, like the Games app — just the icon and its text.
            .background(.quaternary.opacity(style == .icons ? 0 : 0.5), in: RoundedRectangle(cornerRadius: 12))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.tint.opacity(hovering ? 0.5 : 0), lineWidth: 1))
            .shadow(color: .black.opacity(hovering ? 0.22 : 0), radius: 9, y: 4)
            .scaleEffect(hovering ? 1.015 : 1)
            .animation(.easeOut(duration: 0.12), value: hovering)
            .contentShape(RoundedRectangle(cornerRadius: 12))
            .onTapGesture { onTap() }
            .onHover { hovering = $0 }
            // ONE tooltip for the whole card, the full title on top: a `.help` on the title alone never
            // shows, the card's own covers it — and a long title is cut to one line.
            .help(Text(verbatim: "\(title)\n\(String(localized: helpText))"))
            .contextMenu { menuItems() }
    }

    @ViewBuilder private var layout: some View {
        switch style {
        case .classic:
            VStack(alignment: .leading, spacing: 0) {
                artworkBox(aspect: TileStyle.headerAspect)
                info(titleLines: 1).padding()
            }
        case .icons:
            HStack(alignment: .top, spacing: 14) {
                artwork(style)
                    .frame(width: TileStyle.iconSize, height: TileStyle.iconSize)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.title3.weight(.semibold)).lineLimit(2)
                    HStack(spacing: 6) { subtitle() }
                    Spacer(minLength: 6)
                    iconsPlayButton
                }
                .frame(maxWidth: .infinity, minHeight: TileStyle.iconSize, alignment: .leading)
                Menu { menuItems() } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton).fixedSize()
            }
            .padding(8)
        case .portrait:
            artworkBox(aspect: 2.0 / 3.0)
                .overlay(alignment: .bottom) {
                    // A dark fade under the panel: glass alone over a bright cover doesn't keep the text
                    // legible (Apple's own note on clear glass asks for a dimming layer).
                    LinearGradient(colors: [.clear, .black.opacity(0.6)], startPoint: .top, endPoint: .bottom)
                        .frame(height: 170)
                        .allowsHitTesting(false)
                }
                .overlay(alignment: .bottom) {
                    info(titleLines: 1)
                        .padding(10)
                        .tileGlass(cornerRadius: 10)
                        .padding(8)
                        .environment(\.colorScheme, .dark)
                }
        }
    }

    /// The artwork filling a box of the given width:height, cropped to it.
    private func artworkBox(aspect: CGFloat) -> some View {
        Color.clear
            .aspectRatio(aspect, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .overlay { artwork(style) }
            .clipped()
    }

    private func info(titleLines: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline).lineLimit(titleLines)
            HStack(spacing: 6) { subtitle() }
            HStack(spacing: 8) {
                primaryButton
                Spacer()
                Menu { menuItems() } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton).fixedSize()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The Games app's Play capsule, in the blue of the other layouts' Play button.
    @ViewBuilder private var iconsPlayButton: some View {
        if isBusy {
            Button {} label: {
                HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Launching…") }
            }
            .buttonStyle(.borderedProminent).buttonBorderShape(.capsule).disabled(true)
        } else {
            Button(action: onPlay) { Text("Play").frame(minWidth: 56) }
                .buttonStyle(.borderedProminent).buttonBorderShape(.capsule).controlSize(.large)
                .disabled(!canLaunch)
        }
    }

    @ViewBuilder private var primaryButton: some View {
        if isBusy {
            Button {} label: {
                HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Launching…") }
            }.buttonStyle(.borderedProminent).disabled(true)
        } else {
            Button(action: onPlay) { Label("Play", systemImage: "play.fill") }
                .buttonStyle(.borderedProminent).disabled(!canLaunch)
        }
    }
}
