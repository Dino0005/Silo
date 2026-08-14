import SwiftUI

/// The "Wine" tab: install the latest prebuilt Wine (from Silo's CI releases) and manage installs.
struct WineDownloadView: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        @Bindable var vm = env.runtime
        Form {
            Section {
                Button {
                    Task { await vm.installLatest() }
                } label: {
                    Label("Install latest Wine", systemImage: "arrow.down.circle")
                }
                .disabled(vm.isInstalling)
                // Offered whenever CrossOver is installed, not just during onboarding: after a CrossOver
                // update this is how you pick the new one up. The runtime is named after the version, so
                // importing again installs alongside instead of replacing.
                if let offer = vm.crossOverWine {
                    Button {
                        Task { await vm.importFromCrossOver() }
                    } label: {
                        Label(String(localized: "Import Wine from CrossOver \(offer.version)"),
                              systemImage: "square.and.arrow.down.on.square")
                    }
                    .disabled(vm.isInstalling)
                }
                if vm.isInstalling { ProgressView().controlSize(.small) }
            } header: {
                Text("Wine")
            }

            RuntimeInstalledSection(title: "Installed Wine", vm: vm)

            if let message = vm.statusMessage {
                Section { Text(LocalizedStringKey(message)).font(.callout).foregroundStyle(.secondary) }
            }
        }
        .formStyle(.grouped)
        .task { await vm.refresh() }
    }
}
