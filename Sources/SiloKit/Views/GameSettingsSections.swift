import SwiftUI

/// The per-game performance-flags form section shared by the Steam (`GameSettingsSheet`) and manual
/// (`ManualGameSettingsSheet`) settings sheets — one place for the flag list and its guidance text.
struct PerformanceFlagsSection: View {
    @Binding var flags: EnvFlags

    var body: some View {
        Section {
            Picker("Sync", selection: $flags.syncMode) {
                ForEach(SyncMode.allCases) { Text(LocalizedStringKey($0.displayName)).tag($0) }
            }
            Toggle("Advertise AVX (Rosetta)", isOn: $flags.advertiseAVX)
            Toggle("Performance HUD (FPS / frame time)", isOn: $flags.metalHUD)
            Toggle("MetalFX upscaling", isOn: $flags.metalFX)
            Toggle("DirectX Raytracing (M3+)", isOn: $flags.dxr)
            // The "Media Foundation" toggle lived here and has been removed for now: it no longer does
            // anything on its own (see EnvFlags.mediaFoundationNative). It comes back once the MF bottle
            // can actually be created and selected — a toggle that silently does nothing is worse than
            // no toggle. The `EnvFlags` field itself stays, so existing config.json values survive.
        } header: {
            Text("Performance")
        } footer: {
            Text("MSync + advertise-AVX is the recommended Apple-Silicon baseline. The Performance HUD overlays live FPS/frame time on the game. MetalFX upscales for more FPS; Raytracing needs an M3 or newer.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// The launch-options form section shared by both settings sheets.
struct LaunchOptionsSection: View {
    @Binding var text: String

    var body: some View {
        Section {
            TextField("Launch options", text: $text, axis: .vertical)
                .labelsHidden()
                .lineLimit(1...3)
                .multilineTextAlignment(.leading)
                .autocorrectionDisabled()
        } header: {
            Text("Launch options")
        } footer: {
            Text("Extra arguments passed to the game executable (space-separated).")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
