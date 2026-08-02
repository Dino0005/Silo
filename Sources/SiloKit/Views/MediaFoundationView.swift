import SwiftUI

/// The **Media Foundation** settings tab: import the MF package, then build the bottle that uses it.
///
/// Two steps rather than one because they're different kinds of operation — the first is a folder copy,
/// the second clones the Steam bottle and runs a dozen wine commands against the copy, and only works
/// once Steam itself is set up.
struct MediaFoundationView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var confirmingBottleRemoval = false

    var body: some View {
        @Bindable var vm = env.mediaFoundation
        Form {
            Section {
                if let package = vm.package {
                    LabeledContent("Package") { Text("Imported").foregroundStyle(.secondary) }
                    Text(package.installDir.path)
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    Button("Replace…") { pickPackage(vm) }.disabled(vm.isWorking)
                } else {
                    Button {
                        pickPackage(vm)
                    } label: {
                        Label("Choose Media Foundation folder…", systemImage: "folder.badge.plus")
                    }
                    .disabled(vm.isWorking)
                }
            } header: {
                Text("Media Foundation package")
            } footer: {
                Text("Some games' in-game videos come up black because Wine's own Media Foundation can't decode them. Silo can use the real Windows ones instead, but doesn't provide them: point it at a folder containing system32, syswow64, mf.reg and wmf.reg, taken from a Windows installation you're licensed for.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                if vm.bottleReady {
                    Label("Ready", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Button("Remove…", role: .destructive) { confirmingBottleRemoval = true }
                        .disabled(vm.isWorking)
                } else {
                    Button("Create Media Foundation bottle") { Task { await vm.buildBottle() } }
                        .disabled(!vm.canBuildBottle || vm.isWorking)
                }
                if vm.isWorking {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(LocalizedStringKey(vm.progress ?? "Working…"))
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Media Foundation bottle")
            } footer: {
                Text("A copy of the Steam bottle with those DLLs installed. It's a separate bottle because the two setups can't coexist — the one that fixes some games stops others from starting. Copying is near-instant and takes almost no extra disk. Its Steam signs in on its own, and only one Steam can run at a time. Turn it on per game in that game's settings.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            if let message = vm.statusMessage {
                Section { Text(LocalizedStringKey(message)).font(.callout).foregroundStyle(.secondary) }
            }
        }
        .formStyle(.grouped)
        .task { vm.refresh() }
        .confirmationDialog(
            "Remove the Media Foundation bottle?",
            isPresented: $confirmingBottleRemoval, titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive) { Task { await vm.removeBottle() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Its Steam sign-in goes with it, along with any saves for games you only played there. Games with Steam Cloud keep their progress.")
        }
    }

    private func pickPackage(_ vm: MediaFoundationViewModel) {
        guard let folder = chooseFolder(
            message: "Choose the folder with system32, syswow64, mf.reg and wmf.reg.") else { return }
        Task { await vm.importPackage(from: folder) }
    }
}
