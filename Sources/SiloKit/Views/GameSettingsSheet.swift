import SwiftUI

struct GameSettingsSheet: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    let game: SteamApp
    @State private var vm: GameSettingsViewModel?
    @State private var executables: [String] = []
    /// The exe the game would actually launch — resolved alongside the executable list (same walk, same
    /// off-main hop) so the DXMT note can read its imports.
    @State private var resolvedExe: URL?

    var body: some View {
        NavigationStack {
            Group {
                if let vm {
                    form(vm)
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .navigationTitle(game.name)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        if let vm {
                            Task {
                                guard await vm.save() else { return }
                                // The tile badges the saved choice, so they'd show the old one until
                                // the next full library load without this.
                                await env.gameLibrary.refreshSteamBadges()
                                dismiss()
                            }
                        }
                    }
                }
            }
        }
        .frame(width: 480, height: 540)
        .task {
            vm = await env.makeGameSettings(appID: game.appID)
            // Off the main actor: a large game's install dir can hold tens of thousands of files and may
            // sit on a slow/external volume, and the exe scan is a full recursive walk — running it inline
            // would jank the sheet as it opens.
            let installURL = game.installURL
            executables = await Task.detached { ExecutableResolver.allExecutables(in: installURL) }.value
            if let config = vm?.config {
                resolvedExe = env.orchestrator.resolvedExecutable(app: game, config: config)
            }
        }
    }

    @ViewBuilder
    private func form(_ model: GameSettingsViewModel) -> some View {
        @Bindable var vm = model
        Form {
            if let message = vm.errorMessage {
                Section { Text(LocalizedStringKey(message)).foregroundStyle(.red) }
            }
            Section {
                Picker("Graphics", selection: $vm.config.graphics) {
                    ForEach(GraphicsChoice.allCases) { Text(LocalizedStringKey($0.displayName)).tag($0) }
                }
                DXMTMismatchNote(choice: vm.config.graphics, executable: resolvedExe)
                if let learned = vm.learnedBackend {
                    HStack {
                        Text("Automatic is using \(learned.displayName) — GPTK couldn't run this game.")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Re-probe GPTK") { Task { await vm.reprobeGPTK() } }
                            .controlSize(.small)
                    }
                }
            } header: {
                Text("Graphics Backend")
            } footer: {
                Text("Automatic picks the best translation layer per game — 32-bit games use DXMT, others start on GPTK / D3DMetal and switch to DXMT if GPTK can't run them. Using DXMT requires installing it in Settings → DXMT. Takes effect next launch.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            PerformanceFlagsSection(flags: $vm.config.envFlags)

            // Only offered once the Media Foundation bottle exists — otherwise there's nothing to switch
            // to, and a toggle that does nothing is worse than no toggle. Removing that bottle turns the
            // flag off on every game, so this can't hide an enabled-but-invisible setting.
            // Checked against the bottle itself, not the MF tab's cached state: that state is only
            // refreshed when that tab is opened, so reading it here hid the toggle until the user had
            // visited Settings → Media Foundation at least once since launching.
            if MediaFoundationInstaller.isInstalled(inPrefix: env.paths.steamBottleMF) {
                Section {
                    Toggle("Run in the Media Foundation bottle",
                           isOn: $vm.config.envFlags.mediaFoundationNative)
                } footer: {
                    Text("For games whose in-game videos come up black. That bottle has its own Steam, and only one Steam runs at a time — Silo switches for you. Takes effect next launch.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            LaunchOptionsSection(text: $vm.config.launchOptionsString)

            Section("Executable") {
                if executables.isEmpty {
                    TextField("Relative path (blank = auto-detect)", text: Binding(
                        get: { vm.config.executableRelativePath ?? "" },
                        set: { vm.config.executableRelativePath = $0.isEmpty ? nil : $0 }))
                } else {
                    Picker("Executable", selection: Binding(
                        get: { vm.config.executableRelativePath ?? "" },
                        set: { vm.config.executableRelativePath = $0.isEmpty ? nil : $0 })) {
                        Text("Auto-detect").tag("")
                        ForEach(executables, id: \.self) { Text($0).tag($0) }
                    }
                }
            }

            Section {
                Picker("Strategy", selection: $vm.config.presence) {
                    ForEach(SteamPresenceStrategy.allCases) { Text(LocalizedStringKey($0.displayName)).tag($0) }
                }
            } header: {
                Text("Steam presence")
            } footer: {
                Text("steam_appid.txt is enough for most games. Titles that hard-require the Steam client (they quit with “Steam not initialized”) aren't supported yet — running a real Steam client in the prefix is planned.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
