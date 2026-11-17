import SwiftUI

/// A release's notes, read inside Silo (Settings → General → Updates → What's New…): the update notice in the
/// Library makes it easy to update without ever opening them on GitHub. Laid out from `ReleaseNotesDocument`'s
/// blocks; each block's inline Markdown (bold, italics, code, links) is SwiftUI's own.
struct ReleaseNotesSheet: View {
    let notes: Updater.ReleaseNotes
    /// Shown when `notes` are a newer version's: installs it.
    var onUpdate: (() -> Void)?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(ReleaseNotesDocument.blocks(notes.markdown).enumerated()), id: \.offset) { _, block in
                        blockView(block)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(24)
                .textSelection(.enabled)
            }
            Divider()
            HStack {
                if let page = notes.pageURL {
                    Link("Open on GitHub", destination: page)
                }
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                if let onUpdate {
                    Button("Update & Relaunch") { dismiss(); onUpdate() }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(16)
        }
        .frame(width: 620, height: 560)
    }

    @ViewBuilder private func blockView(_ block: ReleaseNotesDocument.Block) -> some View {
        switch block {
        case .heading(let level, let text):
            Text(Self.inline(text))
                .font(level == 1 ? .title2.bold() : level == 2 ? .title3.weight(.semibold) : .headline)
                .padding(.top, level == 1 ? 0 : 8)
        case .bullet(let text):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(verbatim: "•").foregroundStyle(.secondary)
                Text(Self.inline(text)).fixedSize(horizontal: false, vertical: true)
            }
        case .paragraph(let text):
            Text(Self.inline(text)).fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The block's inline Markdown; the plain text when it doesn't parse.
    private static func inline(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }
}
