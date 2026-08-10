import SwiftUI

struct GameSettingsSheet: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    let game: SteamApp
    @State private var vm: GameSettingsViewModel?
    @State private var executables: [String] = []
    /// Whether the game needs D3D12 — decided once when the sheet opens, off the main actor, and handed to
    /// the note as a plain value. Computing it inside the note (keyed on an executable that arrived a render
    /// later) never produced a visible warning.
    @State private var needsD3D12 = false
    /// Non-nil while the shared-save picker is up. Populated when the Media Foundation toggle is turned ON:
    /// that bottle is a clone, so from the first launch on that side the game keeps a SECOND set of saves.
    @State private var saveCandidates: [SharedSaveCandidate]?
    /// The shared folders as PERSISTED when the sheet opened. `vm.config` is edited in place by the picker,
    /// so this is the only record of what was shared before — and unsharing is a diff against it.
    @State private var sharedSavesAtOpen: [SharedSaveFolder] = []

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
                                await applySharedSaveChanges(
                                    vm.config.sharedSaveFolders,
                                    mfEnabled: vm.config.envFlags.mediaFoundationNative)
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
            sharedSavesAtOpen = vm?.config.sharedSaveFolders ?? []
            // Off the main actor: a large game's install dir can hold tens of thousands of files and may
            // sit on a slow/external volume, and the exe scan is a full recursive walk — running it inline
            // would jank the sheet as it opens.
            let installURL = game.installURL
            executables = await Task.detached { ExecutableResolver.allExecutables(in: installURL) }.value
            if let config = vm?.config,
               let exe = env.orchestrator.resolvedExecutable(app: game, config: config) {
                // Reading a PE's imports and walking the install tree is disk work, and the game may be on
                // an external drive.
                needsD3D12 = await Task.detached { BackendChooser.needsD3D12(exe: exe) }.value
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
                DXMTMismatchNote(choice: vm.config.graphics, needsD3D12: needsD3D12)
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
                        .onChange(of: vm.config.envFlags.mediaFoundationNative) { _, isOn in
                            // Only on the way ON, and only when nothing is shared yet — re-opening the sheet
                            // on an already-configured game must not nag. The row below is the way back in.
                            guard isOn, vm.config.sharedSaveFolders.isEmpty else { return }
                            presentSaveFolderPicker(sharing: vm.config.sharedSaveFolders)
                        }
                    if vm.config.envFlags.mediaFoundationNative {
                        // Without this there is NO way back to the picker: the sheet above fires once, so a
                        // wrong folder (or a second one a game turned out to need) could only be fixed by
                        // editing config.json by hand. Shows 0 when "Not now" was chosen.
                        Button {
                            presentSaveFolderPicker(sharing: vm.config.sharedSaveFolders)
                        } label: {
                            HStack {
                                Text(String(localized:
                                    "Shared save folders: \(vm.config.sharedSaveFolders.count)"))
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption).foregroundStyle(.tertiary)
                            }
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                    }
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
        .sheet(isPresented: Binding(
            get: { saveCandidates != nil },
            set: { if !$0 { saveCandidates = nil } })) {
            SharedSaveFolderPicker(
                gameName: game.name,
                candidates: saveCandidates ?? [],
                selected: Set(vm.config.sharedSaveFolders.map(\.id))) { folders in
                    vm.config.sharedSaveFolders = folders
                }
        }
    }

    /// Build the candidate list off the main actor, then raise the picker. Shared by the toggle turning ON
    /// and the "Shared save folders" row, so both paths see the same list — and both pass the ALREADY-CHOSEN
    /// folders through `keeping`, which is what keeps a chosen folder visible even if its name is one the
    /// exclusion list drops.
    /// Make the MF bottle match what was just saved: drop the symlink for every folder that was shared when
    /// the sheet opened and no longer is, and create the ones now listed.
    ///
    /// BOTH directions, deliberately. Linking used to happen only at launch (`GameLibraryViewModel`), from
    /// when the picker didn't exist and the next launch was the only moment available — so unticking took
    /// effect at once while re-ticking did nothing visible until the game was next played. The disk didn't
    /// match what the settings said, which is exactly what someone checking with `ls` after saving finds.
    /// The launch-time call stays as a safety net; it's idempotent, so an already-correct link costs a stat.
    ///
    /// On SAVE rather than on the picker's confirm: leaving the sheet with Cancel after unticking something
    /// must not touch the disk. And `ensure` only runs when the toggle is ON — creating links inside a
    /// bottle the game doesn't use would be pointless — while unlinking runs either way, being cleanup of
    /// something that already exists.
    private func applySharedSaveChanges(_ nowShared: [SharedSaveFolder], mfEnabled: Bool) async {
        let keptIDs = Set(nowShared.map(\.id))
        let removed = sharedSavesAtOpen.filter { !keptIDs.contains($0.id) }
        let toLink = mfEnabled ? nowShared : []
        guard !removed.isEmpty || !toLink.isEmpty else { return }
        let paths = env.paths
        await Task.detached { () -> Void in
            // Explicitly Void: without it the closure returns the linker's `[SharedSaveFolder]`, so the Task
            // carries a value nobody reads. `@discardableResult` applies to the call, not to the Task.
            let linker = SharedSaveLinker()
            // Unlink FIRST: the two sets are disjoint, but doing removals before creations means a folder
            // can never be linked and then immediately torn down by a stale entry.
            linker.unlink(removed, mfPrefix: paths.steamBottleMF, canonicalPrefix: paths.steamBottle)
            linker.ensure(toLink, mfPrefix: paths.steamBottleMF, canonicalPrefix: paths.steamBottle)
        }.value
        sharedSavesAtOpen = nowShared
    }

    /// - Parameter shared: the game's current folders. Passed IN rather than read from `vm`: the
    ///   non-optional view model exists only inside `form(_:)`, which rebinds it with `@Bindable` — out
    ///   here `vm` is the `@State` optional, and this method doesn't need the model at all.
    private func presentSaveFolderPicker(sharing shared: [SharedSaveFolder]) {
        let paths = env.paths
        Task {
            // Two directory listings across both prefixes, one of which may be on an external volume.
            saveCandidates = await Task.detached {
                SharedSaveCandidates().candidates(mfPrefix: paths.steamBottleMF,
                                                  canonicalPrefix: paths.steamBottle,
                                                  keeping: shared)
            }.value
        }
    }
}
