import SwiftUI

/// A small capsule tag on a library card showing its graphics-backend choice — `Auto`, `GPTK`, or `DXMT`.
///
/// Shows the choice as SET, never what Automatic later learned: the badge matching what the settings
/// sheet says matters more than naming the resolved backend, and one that changed by itself after a
/// launch would be hard to account for.
struct BackendTag: View {
    let choice: GraphicsChoice

    var body: some View {
        Text(LocalizedStringKey(choice.badge))
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.quaternary, in: Capsule())
            .help(choice == .auto ? "Silo picks the backend automatically" : "Runs under \(choice.displayName)")
    }
}

/// Marks a Steam game that launches in the Media Foundation bottle.
///
/// Only shown when that bottle is actually set up — see `GameLibraryViewModel.SteamGameBadges`. The
/// flag alone doesn't mean much: with no MF bottle the game runs in the normal one regardless, so the
/// badge would be describing something that isn't happening.
struct MediaFoundationTag: View {
    var body: some View {
        Text("MF")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.quaternary, in: Capsule())
            .help("Runs in the Media Foundation bottle")
    }
}
