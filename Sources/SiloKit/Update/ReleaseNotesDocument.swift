import Foundation

/// The Markdown of a release's notes cut into the blocks Silo shows them as: headings, bullets and paragraphs.
/// SwiftUI's `Text` reads Markdown inline only (bold, italics, code, links), so the block structure is taken from
/// the lines here, and each block's text keeps its inline Markdown. Covers what `RELEASE_NOTES.md` uses; anything
/// else reads as a paragraph.
public enum ReleaseNotesDocument {
    public enum Block: Equatable, Sendable {
        case heading(level: Int, text: String)
        case bullet(String)
        case paragraph(String)
    }

    /// Pure: the blocks of `markdown`, in order. A line indented under a bullet, or right after a paragraph line,
    /// continues it (the notes wrap at 120 columns); a blank line ends a block.
    public static func blocks(_ markdown: String) -> [Block] {
        var blocks: [Block] = []
        var open: Block?

        func close() {
            if let block = open { blocks.append(block) }
            open = nil
        }

        for raw in markdown.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { close(); continue }
            if let heading = Self.heading(line) {
                close()
                blocks.append(heading)
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
                close()
                open = .bullet(String(line.dropFirst(2)))
            } else if let block = open, raw.first == " " || raw.first == "\t" || !block.isBullet {
                open = block.appending(line)   // a wrapped line of the bullet or paragraph above
            } else {
                close()
                open = .paragraph(line)
            }
        }
        close()
        return blocks
    }

    /// `# Title` … `###### Title` → a heading of that level.
    private static func heading(_ line: String) -> Block? {
        let hashes = line.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes), line.dropFirst(hashes).first == " " else { return nil }
        return .heading(level: hashes, text: line.dropFirst(hashes + 1).trimmingCharacters(in: .whitespaces))
    }
}

private extension ReleaseNotesDocument.Block {
    var isBullet: Bool { if case .bullet = self { true } else { false } }

    func appending(_ line: String) -> Self {
        switch self {
        case .bullet(let text): .bullet(text + " " + line)
        case .paragraph(let text): .paragraph(text + " " + line)
        case .heading: self
        }
    }
}
