import SwiftUI

/// Warns when DXMT is picked for a game that needs Direct3D 12.
///
/// DXMT translates D3D10/11 only. Choosing it for a D3D12 title doesn't route the game through DXMT —
/// it leaves a SPLIT stack: d3d12 still handled by GPTK's D3DMetal, but `dxgi` (swapchain and
/// presentation) replaced by DXMT's. Observed on Fatal Fury: the picture sat offset to the right until
/// the game was moved off DXMT. The game still runs, which is what makes this worth saying out loud —
/// nothing fails outright, it just looks subtly wrong.
///
/// A game's own D3D11 mode (Unreal takes `-d3d11`) sidesteps the split entirely, and then either
/// backend translates it — measured on Fatal Fury, whose intro video plays under GPTK and DXMT alike
/// once the game is in D3D11, and under neither while it's in D3D12.
///
/// Only shown for an EXPLICIT DXMT choice: Automatic already consults the same check and routes a D3D12
/// game to GPTK on its own, so there'd be nothing to warn about.
///
/// The check reads the executable's import table, so it needs the file: for a game on a disconnected
/// external drive it can't run, and then nothing is shown rather than a guess.
struct DXMTMismatchNote: View {
    let choice: GraphicsChoice
    /// Whether the game needs D3D12 — computed by the sheet (see `BackendChooser.needsD3D12`), not here.
    /// It used to be resolved inside this view's own `.task`, keyed on an executable that arrives from the
    /// parent one render later; that never produced a visible note, and there was no way to tell from the
    /// outside whether the check had run at all. A plain input can be tested.
    let needsD3D12: Bool

    var body: some View {
        if choice == .dxmt, needsD3D12 {
            Label {
                Text("This game uses Direct3D 12, which DXMT doesn't translate: the graphics still go through GPTK, with DXMT covering only part of the stack — a mix that can cause display problems. Switch to GPTK. If the game also offers a Direct3D 11 mode (Unreal titles take the launch option -d3d11), that avoids the split altogether and either backend will handle it.")
                    .font(.caption)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
            }
            .foregroundStyle(.orange)
        }
    }
}
