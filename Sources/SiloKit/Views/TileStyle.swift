import SwiftUI

/// How a Library tile lays out its artwork, picked in the toolbar's filter menu (Tile Style). `.classic` is the
/// default. Persisted by raw value; an unknown one (a style tried out and dropped, like the 2026-11-06
/// `fullHeader`/`glassHeader` experiments) reads as the default.
enum TileStyle: String, CaseIterable, Identifiable {
    /// The whole header, at its own 460×215 ratio — nothing cropped. (Replaced the original tile, whose
    /// 92-pt band cropped the header top and bottom and cut UNCHARTED's title off.)
    case classic
    /// A row like Apple's Games app: the game's app icon, its title, and a Play capsule. No card.
    case icons
    /// Steam's portrait cover filling the tile, the info on a glass panel at its foot.
    case portrait

    var id: String { rawValue }

    static let storageKey = "libraryTileStyle"

    /// Steam's `header.jpg` is 460×215.
    static let headerAspect: CGFloat = 460.0 / 215.0
    /// The icon's side in the `.icons` layout.
    static let iconSize: CGFloat = 84
}

extension View {
    /// Liquid Glass where the system has it (macOS 26), a blurred material before that.
    @ViewBuilder
    func tileGlass(cornerRadius: CGFloat) -> some View {
        if #available(macOS 26, *) {
            glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
        } else {
            background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius))
        }
    }
}
