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
        Section {
            Toggle(isOn: $flags.dualSenseBluetoothAsWired) {
                Text("Bluetooth DualSense as wired")
                Text("The game reads a DualSense on Bluetooth as if it were on a cable: Sony's code in games such as UNCHARTED then reads it, with its trigger effects.")
            }
            Toggle(isOn: $flags.dualSenseRumbleOnActuators) {
                Text("Rumble on the HD actuators")
                Text("Over Bluetooth, the game's rumble played on the DualSense's HD actuators instead of its motors' emulation: stronger. A game's own haptics come first.")
            }
            Toggle(isOn: $flags.dualSenseAsXInput) {
                Text("DualSense as an XInput controller")
                Text("For games that read only Xbox controllers, such as TEKKEN 8: the DualSense is offered to them as one. They may show Xbox button prompts.")
            }
        } header: {
            Text("DualSense")
        } footer: {
            Text("With Steam Input off for the game, from Steam for macOS or Silo's Steam: then Wine reads the DualSense itself. With Steam Input on, the game gets Steam's controller and these don't apply. From MacGameFix, by Mathias Kowoll.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// Controller handling for a manual game: only "Disable hidraw" (`EnvFlags.disableHidraw`), applied to the game's
/// own bottle before each launch (`SteamInputControllers.apply`, `hideSteamInputPads: false`).
struct ManualControllersSection: View {
    @Binding var flags: EnvFlags

    var body: some View {
        Section {
            Toggle("Disable hidraw", isOn: $flags.disableHidraw)
        } header: {
            Text("Controllers")
        } footer: {
            Text("Wine reads every controller through SDL instead of reading PlayStation and Switch pads directly: Xbox button prompts, but a steadier pad for games such as God of War and Batman: Arkham Knight. Takes effect next launch.")
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

/// A game's compiled shaders (`ShaderCache`): one row per place it was started from, with the space it takes, a
/// warning when Metal's cache is full, and a button to clear it — plus one for both. Clearing is the user's choice,
/// since the next launch from there compiles the shaders again. Placed last in both settings sheets.
struct ShaderCacheSection: View {
    /// A Steam app id, or a manual game's UUID.
    let gameID: String
    /// The game's `EnvFlags.pipelineCache` — Steam games only (the cache runs in macOS Steam launches).
    var pipelineCache: Binding<Bool>?
    /// The game's executable file names, for D3DMetal's cache (`ShaderCache.Kind.translation`).
    var executables: [String] = []
    @ViewState private var status = ShaderCache.Status.empty
    /// The caches the user asked to clear, waiting for the confirmation.
    @ViewState private var pending: Set<ShaderCache.Kind> = []
    @ViewState private var message: String?

    private func size(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }

    private func title(_ kind: ShaderCache.Kind) -> LocalizedStringKey {
        switch kind {
        case .steam: "Launched from Steam for macOS"
        case .silo: "Launched from Silo"
        case .pipelines: "Silo's pipeline cache"
        case .translation: "D3DMetal (translated shaders)"
        }
    }

    var body: some View {
        Section {
            if let pipelineCache {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Silo's pipeline cache", isOn: pipelineCache)
                    Text("Keeps the pipelines Metal had to compile — the ones its own cache didn't have, or no longer has room for — in a cache of Silo's own, and uses them at the next launch. Launches from Steam for macOS only, GPTK only. Being tested.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if status.present.isEmpty {
                LabeledContent("Space used") { Text(size(0)) }
            }
            ForEach(status.present, id: \.self) { kind in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(title(kind))
                        Spacer()
                        Text(size(status[kind].bytes)).foregroundStyle(.secondary)
                        Button("Clear…") { pending = [kind] }
                    }
                    if status[kind].isFull {
                        Label("Full: Metal no longer keeps new shaders, so the game compiles some of them again at every launch.",
                              systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(.orange)
                    }
                }
            }
            if status.present.count > 1 || message != nil {
                HStack {
                    if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
                    Spacer()
                    if status.present.count > 1 {
                        Button("Clear All…") { pending = Set(ShaderCache.Kind.allCases) }
                    }
                }
            }
        } header: {
            Text("Shader cache")
        } footer: {
            Text("The game's shaders as Metal compiled them, so it doesn't compile them again. Clearing frees the space; the next launch compiles them again, so it loads slower and stutters for a while. Two caches made from the same one can share part of their space on disk, so the space freed can be less than their sum. D3DMetal keeps its translation of the game's shaders by executable name, so a game with the same executable name shares it; none of these caches is removed when a game is uninstalled.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .task(id: gameID + "|" + executables.joined(separator: "|")) {
            status = ShaderCache.status(forID: gameID, executables: executables)
        }
        .confirmationDialog("Clear the shader cache?",
                            isPresented: Binding(get: { !pending.isEmpty }, set: { if !$0 { pending = [] } }),
                            titleVisibility: .visible) {
            Button("Clear", role: .destructive) {
                switch ShaderCache.clear(pending, forID: gameID, executables: executables) {
                case .cleared(let freed): message = String(localized: "Freed \(size(freed)).")
                case .nothingToClear: message = nil
                case .inUse: message = String(localized: "The game is running: quit it first.")
                case .failed(let reason): message = reason
                }
                pending = []
                status = ShaderCache.status(forID: gameID, executables: executables)
            }
        } message: {
            Text("The next launch compiles the game's shaders again: it loads slower and stutters for a while.")
        }
    }
}
