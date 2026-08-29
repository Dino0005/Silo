import SwiftUI
import AppKit
import UniformTypeIdentifiers

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
    /// What's typed in the Steam app ID field, before it's been checked against the store.
    @State private var appIDField = ""
    @State private var checkingCard = false
    /// Set when a lookup fails, so the sheet can say so without borrowing the library's status bar.
    @State private var cardProblem: String?

    /// Check the entered app ID against the Steam store and, if it resolves, keep it.
    ///
    /// The lookup is the confirmation: a number that returns nothing is a typo or the wrong game, and
    /// storing it would leave a card that renders empty every time it's opened.
    ///
    /// On success, and only when no cover has been chosen, Steam's artwork is downloaded and archived like
    /// any other cover. Copying it beats relying on the URL cache — a file on disk still shows with no
    /// network, which is exactly when a game library is least useful if it can't draw itself.
    private func createCard() async {
        guard let appID = Int(appIDField.trimmingCharacters(in: .whitespaces)) else { return }
        checkingCard = true
        cardProblem = nil
        defer { checkingCard = false }

        guard let details = await SteamStoreClient().details(appID: appID) else {
            cardProblem = String(localized: "No Steam game found with ID \(appIDField).")
            return
        }
        game.steamAppID = appID

        if game.coverArtFileName == nil, let art = details.headerImageURL {
            let store = CoverArtStore(coversDir: env.paths.coversDir)
            let id = game.id
            game.coverArtFileName = await Task.detached { () -> String? in
                guard let (data, _) = try? await URLSession.shared.data(from: art) else { return nil }
                let scratch = FileManager.default.temporaryDirectory
                    .appendingPathComponent("silo-cover-\(id.uuidString).jpg")
                guard (try? data.write(to: scratch)) != nil else { return nil }
                defer { try? FileManager.default.removeItem(at: scratch) }
                return store.store(scratch, for: id)
            }.value
        }
    }

    /// Pick an image file for the tile. Mirrors `chooseExecutable`, restricted to image types.
    private func chooseCoverImage() -> URL? {
        let panel = NSOpenPanel()
        panel.message = String(localized: "Choose a cover image for this game.")
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        return panel.runModal() == .OK ? panel.url : nil
    }

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
                    if let cover = CoverArtStore(coversDir: env.paths.coversDir)
                        .url(named: game.coverArtFileName) {
                        Text(cover.lastPathComponent)
                            .font(.caption).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                    } else {
                        Text("No cover set — the game's icon is used.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Button("Choose image…") {
                        guard let picked = chooseCoverImage() else { return }
                        // Copied in at CHOOSE time, not on Save: the row above then shows the real stored
                        // file, and a cancelled sheet at worst leaves one file the next choice overwrites.
                        game.coverArtFileName = CoverArtStore(coversDir: env.paths.coversDir)
                            .store(picked, for: game.id)
                    }
                    if game.coverArtFileName != nil {
                        Button("Remove cover", role: .destructive) {
                            CoverArtStore(coversDir: env.paths.coversDir).remove(for: game.id)
                            game.coverArtFileName = nil
                        }
                    }
                } header: {
                    Text("Cover")
                }

                Section {
                    if let appID = game.steamAppID {
                        HStack {
                            Text(verbatim: "\(appID)").foregroundStyle(.secondary)
                            Spacer()
                            Button("Remove card", role: .destructive) {
                                // The cover stays: once downloaded it's just an image like any other, and
                                // deleting it here would be a surprise. Its own button removes it.
                                game.steamAppID = nil
                                cardProblem = nil
                            }
                        }
                    } else {
                        TextField("Steam app ID", text: $appIDField)
                            .disabled(checkingCard)
                        Button("Create game card") { Task { await createCard() } }
                            .disabled(checkingCard || Int(appIDField.trimmingCharacters(in: .whitespaces)) == nil)
                        if checkingCard { ProgressView().controlSize(.small) }
                    }
                    if let cardProblem {
                        Text(LocalizedStringKey(cardProblem)).font(.caption).foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Game card")
                } footer: {
                    Text("Silo fetches the description, developer, genres and release date from Steam, and uses Steam's artwork if you haven't chosen a cover. The app ID is the number in the game's Steam store page address.")
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
                    DXMTMismatchNote(choice: game.graphics, needsD3D12: needsD3D12,
                                     launchOptions: game.launchOptionsString)
                } header: {
                    Text("Graphics Backend")
                } footer: {
                    Text("Automatic picks the backend per game — 32-bit games use DXMT, others use GPTK / D3DMetal. Using DXMT requires installing it in Settings → DXMT. Takes effect next launch.")
                }

                PerformanceFlagsSection(flags: $game.envFlags, graphics: game.graphics)
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
