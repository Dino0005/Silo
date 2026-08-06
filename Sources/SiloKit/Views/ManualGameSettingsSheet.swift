import SwiftUI
import AppKit

/// Edit a manual (non-Steam) game: name, executable, its isolated bottle, performance flags, and launch
/// options. Saving persists the edited copy through the library view model.
struct ManualGameSettingsSheet: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    /// A local editable copy — only written back on Save.
    @State var game: ManualGame
    /// Whether the chosen executable needs D3D12 (drives the DXMT warning). Recomputed whenever the user
    /// picks a different exe, since that changes the answer.
    @State private var needsD3D12 = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("Name", text: $game.name)
                }

                Section("Executable") {
                    Text(game.executablePath.path)
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                    Button("Change .exe…") {
                        if let exe = chooseExecutable(
                            message: "Choose the game's .exe.",
                            directory: game.executablePath.deletingLastPathComponent()) {
                            game.executablePath = exe
                        }
                    }
                }

                Section {
                    Button("Run Installer in this bottle…") {
                        if let installer = chooseExecutable(
                            message: "Choose a setup .exe or .msi to run in this game's bottle.",
                            installer: true) {
                            Task { await env.gameLibrary.runInstaller(installer, forBottle: game.bottleID) }
                        }
                    }
                    Button("Show bottle in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([env.paths.manualBottle(game.bottleID)])
                    }
                } header: {
                    Text("Bottle")
                } footer: {
                    Text("This game runs in its own isolated Wine prefix — install runtimes or patch it here without affecting other games.")
                }

                Section {
                    Picker("Graphics", selection: $game.graphics) {
                        ForEach(GraphicsChoice.allCases) { Text(LocalizedStringKey($0.displayName)).tag($0) }
                    }
                    Text(LocalizedStringKey(game.graphics.recommendedFor))
                        .font(.caption).foregroundStyle(.secondary)
                    DXMTMismatchNote(choice: game.graphics, needsD3D12: needsD3D12)
                } header: {
                    Text("Graphics Backend")
                } footer: {
                    Text("Automatic picks the backend per game — 32-bit games use DXMT, others use GPTK / D3DMetal. Using DXMT requires installing it in Settings → DXMT. Takes effect next launch.")
                }

                PerformanceFlagsSection(flags: $game.envFlags)
                LaunchOptionsSection(text: $game.launchOptionsString)
            }
            .formStyle(.grouped)
            .navigationTitle(game.name)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await env.gameLibrary.updateManual(game); dismiss() } }
                }
            }
        }
        .frame(width: 480, height: 560)
        // Keyed on the executable so picking a different one re-answers the question. Off the main actor:
        // reading a PE's imports and walking the install tree is disk work, and the game may live on an
        // external drive.
        .task(id: game.executablePath) {
            let exe = game.executablePath
            needsD3D12 = await Task.detached { BackendChooser.needsD3D12(exe: exe) }.value
        }
    }
}
