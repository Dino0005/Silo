import Foundation

/// One directory the picker can offer as a shared save folder.
public struct SharedSaveCandidate: Sendable, Hashable, Identifiable {

    /// Which bottle(s) the directory exists in — shown per row, because it's the only way to see, BEFORE
    /// choosing, which folders have already drifted apart.
    public enum Presence: Sendable, Hashable {
        case both
        case canonicalOnly
        case mediaFoundationOnly
    }

    public var id: String { folder.id }
    public let folder: SharedSaveFolder
    public let presence: Presence
    /// Newest modification date across the two sides — what the list sorts on.
    public let modified: Date?
    /// Both sides hold a REAL, non-empty directory. Silo won't merge them; the user picks which to keep.
    /// Catching it here means the launch-time refusal (`SharedSaveLinker`) should never be reached.
    public let divergent: Bool

    public init(folder: SharedSaveFolder, presence: Presence, modified: Date?, divergent: Bool) {
        self.folder = folder
        self.presence = presence
        self.modified = modified
        self.divergent = divergent
    }
}

/// Lists the directories that could plausibly hold a game's saves, in both bottles.
///
/// Deliberately UNFILTERED: `AppData/Local` in a Wine prefix also holds `Microsoft`, `Temp`, Steam's own
/// folders and assorted caches, so the list is longer than it needs to be. A name-based exclusion list
/// would shorten it, but it is a list to maintain and sooner or later it hides the one folder that
/// mattered — an extra row is cheap, a permanently invisible folder is not.
public struct SharedSaveCandidates: Sendable {
    // Computed (not stored): FileManager isn't Sendable, but the shared instance is fine to use.
    private var fileManager: FileManager { .default }
    private let linker = SharedSaveLinker()

    public init() {}

    /// Roots offered by the picker. Games in this library keep saves in `AppData\Local`, but different
    /// titles choose differently and the user shouldn't have to know which in advance.
    public static let offeredRoots: [SharedSaveFolder.Root] = [.appDataLocal, .appDataRoaming]

    /// Directories that CANNOT hold a game's saves, dropped from the list. Kept deliberately short and
    /// obvious — every name here is infrastructure whose contents a game never owns:
    ///
    /// - `Temp` — Wine's temp dir
    /// - `CEF` — the Steam client's embedded-browser cache
    /// - `Steam` — client logs and caches
    /// - `Microsoft` — system state (appears under BOTH roots)
    /// - `UnrealEngine` — engine shader cache and crash reports, never save data
    ///
    /// A longer list buys a shorter picker at the price of hiding something that mattered, which is why
    /// this stops at names with no plausible save content — and why an already-CHOSEN folder is shown
    /// regardless (see `candidates`).
    static let excludedNames: Set<String> = [
        "temp", "cef", "steam", "microsoft", "unrealengine",
    ]

    /// - Parameter keeping: folders already shared for this game. They are listed even when their name is
    ///   excluded: hiding a folder the user already chose would read as the saves having vanished, and a
    ///   name added to `excludedNames` in some later release must never be able to cause that.
    public func candidates(mfPrefix: URL, canonicalPrefix: URL,
                           keeping: [SharedSaveFolder] = []) -> [SharedSaveCandidate] {
        let kept = Set(keeping.map(\.id))
        let mfUser = linker.windowsUserDir(inPrefix: mfPrefix)
        let canonicalUser = linker.windowsUserDir(inPrefix: canonicalPrefix)
        guard mfUser != nil || canonicalUser != nil else { return [] }

        var found: [SharedSaveCandidate] = []
        for root in Self.offeredRoots {
            let mfDir = mfUser?.appendingPathComponent(root.relativePath, isDirectory: true)
            let canonicalDir = canonicalUser?.appendingPathComponent(root.relativePath, isDirectory: true)
            let names = Set(directoryNames(in: mfDir)).union(directoryNames(in: canonicalDir))
                // Case-insensitive: neither Wine nor Steam is consistent about capitalisation.
                .filter { name in
                    kept.contains(SharedSaveFolder(root: root, name: name).id)
                        || !Self.excludedNames.contains(name.lowercased())
                }

            for name in names {
                let mfEntry = mfDir?.appendingPathComponent(name, isDirectory: true)
                let canonicalEntry = canonicalDir?.appendingPathComponent(name, isDirectory: true)
                let inMF = exists(mfEntry)
                let inCanonical = exists(canonicalEntry)
                let presence: SharedSaveCandidate.Presence =
                    inMF && inCanonical ? .both : (inCanonical ? .canonicalOnly : .mediaFoundationOnly)
                // An MF side that is already a SYMLINK is the shared state, not a second copy — so a
                // folder linked by hand reads as `both` and never as divergent.
                let divergent = inMF && inCanonical
                    && !isSymlink(mfEntry) && hasContent(mfEntry) && hasContent(canonicalEntry)
                found.append(SharedSaveCandidate(
                    folder: SharedSaveFolder(root: root, name: name),
                    presence: presence,
                    modified: [modifiedDate(mfEntry), modifiedDate(canonicalEntry)].compactMap { $0 }.max(),
                    divergent: divergent))
            }
        }
        // Newest first — the folder a game just wrote to is the one being looked for. Ties by name so the
        // order is stable between openings of the sheet.
        return found.sorted {
            switch ($0.modified, $1.modified) {
            case let (l?, r?) where l != r: l > r
            case (nil, _?): false
            case (_?, nil): true
            default: $0.folder.name.localizedCaseInsensitiveCompare($1.folder.name) == .orderedAscending
            }
        }
    }

    // MARK: - disk

    private func directoryNames(in dir: URL?) -> [String] {
        guard let dir else { return [] }
        return ((try? fileManager.contentsOfDirectory(atPath: dir.path)) ?? [])
            .filter { !$0.hasPrefix(".") }
            .filter { exists(dir.appendingPathComponent($0, isDirectory: true)) }
    }

    private func exists(_ url: URL?) -> Bool {
        guard let url else { return false }
        var isDirectory: ObjCBool = false
        // `fileExists` FOLLOWS symlinks, which is what we want: a hand-made link counts as present.
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return false }
        return isDirectory.boolValue
    }

    private func isSymlink(_ url: URL?) -> Bool {
        guard let url,
              let attributes = try? fileManager.attributesOfItem(atPath: url.path) else { return false }
        return attributes[.type] as? FileAttributeType == .typeSymbolicLink
    }

    private func hasContent(_ url: URL?) -> Bool {
        guard let url else { return false }
        return !(((try? fileManager.contentsOfDirectory(atPath: url.path)) ?? []).isEmpty)
    }

    private func modifiedDate(_ url: URL?) -> Date? {
        guard let url,
              let attributes = try? fileManager.attributesOfItem(atPath: url.path) else { return nil }
        return attributes[.modificationDate] as? Date
    }
}
