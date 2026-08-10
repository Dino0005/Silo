import SwiftUI

/// Pick the directories whose saves both bottles should share. The MF bottle is a clone, so without this
/// the same game keeps two separate save sets.
///
/// Raised when Media Foundation is turned ON, and again from the "Shared save folders" row — which is the
/// only way back in once a choice has been made, so it opens with the current choices already ticked.
struct SharedSaveFolderPicker: View {
    @Environment(\.dismiss) private var dismiss
    let gameName: String
    let candidates: [SharedSaveCandidate]
    /// Called with the chosen folders. Dismissing without confirming leaves the game's list untouched.
    let onShare: ([SharedSaveFolder]) -> Void

    /// What was already shared when the sheet opened — the baseline "Share" is compared against.
    private let initialSelection: Set<String>
    @State private var selected: Set<String>

    init(gameName: String,
         candidates: [SharedSaveCandidate],
         selected: Set<String> = [],
         onShare: @escaping ([SharedSaveFolder]) -> Void) {
        self.gameName = gameName
        self.candidates = candidates
        self.onShare = onShare
        self.initialSelection = selected
        _selected = State(initialValue: selected)
    }

    private var chosen: [SharedSaveCandidate] {
        candidates.filter { selected.contains($0.id) }
    }

    var body: some View {
        NavigationStack {
            Group {
                if candidates.isEmpty {
                    ContentUnavailableView {
                        Text("Shared save folders")
                    } description: {
                        Text(String(localized:
                            "No folders to show yet. Play \(gameName) once, then open this again."))
                    }
                } else {
                    list
                }
            }
            .navigationTitle(Text("Shared save folders"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Not now") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Share") {
                        onShare(chosen.map(\.folder))
                        dismiss()
                    }
                    // Enabled when there's a CHANGE to apply, not merely a non-empty selection. On a first
                    // open the baseline is empty so this behaves as before; on a re-open it also allows
                    // clearing every tick to stop sharing, which an `isEmpty` check made impossible.
                    .disabled(selected == initialSelection)
                }
            }
        }
        .frame(width: 480, height: 520)
    }

    private var list: some View {
        List {
            Section {
                Text(String(localized:
                    "The Media Foundation bottle keeps its own copy of everything. Choose where \(gameName) saves, so both bottles use one set."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(SharedSaveCandidates.offeredRoots, id: \.self) { root in
                let rows = candidates.filter { $0.folder.root == root }
                if !rows.isEmpty {
                    // The literal Windows path, not translated text.
                    Section(root.relativePath.replacingOccurrences(of: "/", with: "\\")) {
                        ForEach(rows) { row($0) }
                    }
                }
            }
            if chosen.contains(where: \.divergent) {
                Section {
                    Label(String(localized:
                        "This folder has saves in both bottles. Silo won't merge them — copy the one you want to keep into the Steam bottle first."),
                          systemImage: "exclamationmark.triangle")
                        .font(.caption)
                }
            }
        }
    }

    @ViewBuilder
    private func row(_ candidate: SharedSaveCandidate) -> some View {
        Toggle(isOn: Binding(
            get: { selected.contains(candidate.id) },
            set: { on in
                if on { selected.insert(candidate.id) } else { selected.remove(candidate.id) }
            })) {
            VStack(alignment: .leading, spacing: 2) {
                Text(candidate.folder.name)
                HStack(spacing: 6) {
                    Text(LocalizedStringKey(Self.describe(candidate.presence)))
                    if let modified = candidate.modified {
                        Text("·")
                        Text(String(localized: "Modified \(modified.formatted(date: .abbreviated, time: .shortened))"))
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    static func describe(_ presence: SharedSaveCandidate.Presence) -> String {
        switch presence {
        case .both:                "In both bottles"
        case .canonicalOnly:       "Only in the Steam bottle"
        case .mediaFoundationOnly: "Only in the Media Foundation bottle"
        }
    }
}
