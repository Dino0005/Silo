import SwiftUI

/// Plays a `SteamThrobber.Animation` in a loop: the neutral layer drawn in the current foreground colour
/// (so the logo reads in light and dark mode alike), the blue arcs on top in their own colour.
struct SteamThrobberView: View {
    let animation: SteamThrobber.Animation
    @State private var start = Date()

    var body: some View {
        TimelineView(.animation) { context in
            let index = animation.frameIndex(at: context.date.timeIntervalSince(start))
            ZStack {
                Image(decorative: animation.masks[index], scale: animation.scale)
                    .renderingMode(.template)
                    .resizable()
                    .foregroundStyle(.primary)
                Image(decorative: animation.colors[index], scale: animation.scale)
                    .resizable()
            }
            .scaledToFit()
        }
        .accessibilityLabel(Text("Starting Steam…"))
    }
}
