import SwiftUI
import AppKit

/// The **Steam for macOS** settings tab (`NativeSteamSettingsModel`): play Windows games from macOS Steam through Silo.
struct NativeSteamSettingsView: View {
    @ViewState private var model = NativeSteamSettingsModel()
    @ViewState private var confirmingBottleRemoval = false

    var body: some View {
        Form {
            Section {
                Toggle(isOn: Binding(get: { model.status.enabled },
                                     set: { on in Task { await model.setEnabled(on) } })) {
                    Text("Use Steam for macOS")
                    SettingsDescription("Play your Windows games from Steam for macOS: Silo installs “Steam (Silo)” in your Applications folder — open Steam from there — and becomes Steam’s compatibility tool for every Windows game.")
                }
                // Off and no macOS Steam on this Mac: nothing to switch on yet. Once on, it can always be turned off.
                .disabled(model.isWorking || (!model.status.enabled && !model.status.steamInstalled))
                if !model.status.enabled && !model.status.steamInstalled {
                    LabeledContent {
                        Link("Download Steam", destination: URL(string: "https://store.steampowered.com/about/")!)
                    } label: {
                        Text("Steam for macOS isn't installed")
                        SettingsDescription("Install Steam for Mac from Valve, open it once and sign in, then turn this on.")
                    }
                }
                if model.isWorking {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Working…").font(.callout).foregroundStyle(.secondary)
                    }
                }
                if let message = model.message {
                    Text(LocalizedStringKey(message)).font(.caption).foregroundStyle(.secondary)
                }
            } header: {
                Text("Steam for macOS")
            } footer: {
                Text("When you turn this on, macOS asks: «“Steam (Silo).app” would like to control this Mac and access your data». Choose Open System Settings and switch on “Steam (Silo)”, already listed under Privacy & Security → Device Control and Data Access — without it the DualSense doesn’t work through Steam Input. After a Silo update that changes the app, macOS asks again. Turning this off needs Steam closed; Windows games stay protected until you remove their library from Steam.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Status") {
                statusRow("Steam (Silo)", model.status.launcherApp)
                statusRow("Compatibility tool “Silo”", model.status.tool)
                statusRow("Protection of Windows games", model.status.guardAgent)
                LabeledContent("Games using Silo") { Text("\(model.status.gamesOnTool)").foregroundStyle(.secondary) }
            }

            if model.status.bottles {
                Section {
                    Button("Delete the bottles too…", role: .destructive) { confirmingBottleRemoval = true }
                        .disabled(model.status.enabled || model.isWorking)
                } header: {
                    Text("Bottles")
                } footer: {
                    Text("The bottles Silo uses for games started from Steam for macOS. They hold the saves of games without Steam Cloud. Available once Steam for macOS is off.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { model.refresh() }
        // Installed while Settings was open (Steam's installer, then back to Silo): the switch follows.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refresh()
        }
        .confirmationDialog("Delete the Steam for macOS bottles?", isPresented: $confirmingBottleRemoval) {
            Button("Delete", role: .destructive) { model.deleteBottles() }
        } message: {
            Text("Saves of games without Steam Cloud are lost. This can't be undone.")
        }
    }

    private func statusRow(_ title: LocalizedStringKey, _ on: Bool) -> some View {
        LabeledContent(title) {
            Label(on ? "Installed" : "Not installed", systemImage: on ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(on ? .green : .secondary)
        }
    }
}
