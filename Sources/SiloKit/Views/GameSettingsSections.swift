import SwiftUI

/// The per-game performance-flags form section shared by the Steam (`GameSettingsSheet`) and manual
/// (`ManualGameSettingsSheet`) settings sheets — one place for the flag list and its guidance text.
struct PerformanceFlagsSection: View {
    @Binding var flags: EnvFlags
    /// The graphics choice, so the Metal-backend picker can stay out of the way under DXMT — it sets
    /// `D3DM_MTL4`, a D3DMetal option, and does nothing there. `.auto` still shows it: it resolves to GPTK
    /// for most games, and hiding it there would remove a choice that does apply.
    var graphics: GraphicsChoice = .auto
    private var metalBackendApplies: Bool { graphics != .dxmt }

    var body: some View {
        Section {
            Picker("Sync", selection: $flags.syncMode) {
                ForEach(SyncMode.allCases) { Text(LocalizedStringKey($0.displayName)).tag($0) }
            }
            Toggle("Advertise AVX (Rosetta)", isOn: $flags.advertiseAVX)
            Toggle("Performance HUD (FPS / frame time)", isOn: $flags.metalHUD)
            Toggle("MetalFX upscaling", isOn: $flags.metalFX)
            Toggle("DirectX Raytracing (M3+)", isOn: $flags.dxr)
            if metalBackendApplies {
                Picker("Metal backend", selection: $flags.metalBackend) {
                    // LocalizedStringKey, like every other picker here: `Text(someString)` takes the
                    // verbatim initialiser and never consults the strings table, so the labels stayed in
                    // English.
                    ForEach(MetalBackendChoice.allCases) { Text(LocalizedStringKey($0.displayName)).tag($0) }
                }
            }
            // The "Media Foundation" toggle lived here and has been removed for now: it no longer does
            // anything on its own (see EnvFlags.mediaFoundationNative). It comes back once the MF bottle
            // can actually be created and selected — a toggle that silently does nothing is worse than
            // no toggle. The `EnvFlags` field itself stays, so existing config.json values survive.
        } header: {
            Text("Performance")
        } footer: {
            // Two versions: the picker's explanation has no business here when the picker isn't.
            Text(metalBackendApplies
                 ? "MSync + advertise-AVX is the recommended Apple-Silicon baseline. The Performance HUD overlays live FPS/frame time on the game. MetalFX upscales for more FPS; Raytracing needs an M3 or newer. Metal backend picks the renderer GPTK's DirectX 12 path translates through: Automatic follows Apple's default — Metal 3 on macOS 26, Metal 4 on macOS 27 and later. If a game regressed after a GPTK update, try Metal 3 first. GPTK only."
                 : "MSync + advertise-AVX is the recommended Apple-Silicon baseline. The Performance HUD overlays live FPS/frame time on the game. MetalFX upscales for more FPS; Raytracing needs an M3 or newer.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// The depth-fix toggle (`EnvFlags.depthFix`), shared by both settings sheets and offered for God of War only
/// (`DepthFix.offered`). Its own section, because it is a per-game workaround rather than a performance flag.
struct DepthFixSection: View {
    @Binding var flags: EnvFlags

    var body: some View {
        Section {
            Toggle("Depth fix", isOn: $flags.depthFix)
        } header: {
            Text("Rendering")
        } footer: {
            Text("Fixes white specks on characters in God of War: the game redraws the scene with an exact depth test, which a few pixels fail on Metal. God of War only, from Steam or GOG. Works with GPTK and DXMT.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// The Spider-Man 2 fix's toggle (`EnvFlags.spiderMan2Fix`), offered only for that game (`SpiderMan2Fix.appID`).
struct SpiderMan2FixSection: View {
    @Binding var flags: EnvFlags

    var body: some View {
        Section {
            Toggle("Spider-Man 2 fix", isOn: $flags.spiderMan2Fix)
        } header: {
            Text("Rendering")
        } footer: {
            Text("Fixes characters stuck in a T-pose, missing heads and the symbiote on M1–M4 Macs (macprotips' fix). Silo puts it in the game's folder before each launch and rebuilds its shaders from your copy of the game; the first time, it downloads Microsoft's shader tools (6 MB). Turned off, the folder goes back to how the game shipped it. GPTK only.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// The Uncharted fix's toggle (`EnvFlags.unchartedFix`), offered only for that game (`UnchartedFix.appID`).
struct UnchartedFixSection: View {
    @Binding var flags: EnvFlags

    var body: some View {
        Section {
            Toggle("Uncharted fix", isOn: $flags.unchartedFix)
        } header: {
            Text("Rendering")
        } footer: {
            Text("Fixes the crash when you quit from the game's menu, and the safe-mode prompt it left for the next start: the game releases some textures one time too many, and Silo keeps them alive a moment longer so the extra release does no harm. Silo puts a small d3d12.dll of its own in the game's folder before each launch; turned off, it takes it away. GPTK only.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// Controller handling for a game started from macOS Steam (`EnvFlags.disableHidraw`,
/// applied by `SteamInputControllers`). Steam games only: a manual game never runs next to macOS Steam.
struct ControllersSection: View {
    @Binding var flags: EnvFlags

    var body: some View {
        Section {
            Toggle("Disable hidraw", isOn: $flags.disableHidraw)
        } header: {
            Text("Controllers (macOS Steam)")
        } footer: {
            Text("For games started from macOS Steam. While Steam Input handles a controller, Silo hides it from the game so the two don't drive it together, and the game gets Steam's virtual controller instead, as an Xbox controller (games that ask Steam for the controller type still show PlayStation glyphs). \"Disable hidraw\" reads every controller through SDL (Xbox glyphs), for a pad that misbehaves — use it with Steam Input off.")
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
