import Foundation

/// Keeps a game's save directories SHARED between the normal Steam bottle and the Media Foundation bottle.
///
/// A game with the MF toggle on runs in `SteamBottleMF`, a clone of `SteamBottle` — so from that moment the
/// two prefixes accumulate separate saves for the same game. This replaces the MF bottle's copy with a
/// symlink to the normal bottle's, which stays canonical.
public struct SharedSaveLinker: Sendable {
    // Computed (not stored): FileManager isn't Sendable, but the shared instance is fine to use.
    private var fileManager: FileManager { .default }

    public init() {}

    /// The Windows user directory inside a prefix — DISCOVERED, never assumed. Wine names it after whoever
    /// booted the prefix: `crossover` for a CrossOver-derived runtime, the macOS user name for a plain Wine
    /// build, so hard-coding either one breaks the moment the runtime changes. `Public` is Windows' shared
    /// profile, not a user. Returns nil if the prefix has no user profile yet (never booted).
    public func windowsUserDir(inPrefix prefix: URL) -> URL? {
        let users = prefix.appendingPathComponent("drive_c/users", isDirectory: true)
        let names = ((try? fileManager.contentsOfDirectory(atPath: users.path)) ?? [])
            .filter { $0 != "Public" && !$0.hasPrefix(".") }
            .sorted()
        guard let name = names.first else { return nil }
        return users.appendingPathComponent(name, isDirectory: true)
    }

    /// Ensure every declared folder in the MF bottle is a symlink to its counterpart in the canonical
    /// bottle. Returns the folders it REFUSED to touch because the MF side holds real data — the caller
    /// surfaces those; everything else is silent success.
    ///
    /// Deliberately never deletes a non-empty directory. An empty one is removed and linked (nothing to
    /// lose); a populated one is left exactly as it is, because Silo cannot know whether that copy exists
    /// anywhere else. No expected flow produces it: `removeBottle()` clears `mediaFoundationNative` on
    /// every game, so a rebuilt MF bottle starts with no toggles on and the links are made afresh when they
    /// are turned back on. If this ever fires, something happened outside Silo.
    @discardableResult
    public func ensure(_ folders: [SharedSaveFolder],
                       mfPrefix: URL, canonicalPrefix: URL) -> [SharedSaveFolder] {
        guard !folders.isEmpty,
              let mfUser = windowsUserDir(inPrefix: mfPrefix),
              let canonicalUser = windowsUserDir(inPrefix: canonicalPrefix) else { return [] }

        var blocked: [SharedSaveFolder] = []
        for folder in folders {
            let target = canonicalUser
                .appendingPathComponent(folder.root.relativePath, isDirectory: true)
                .appendingPathComponent(folder.name, isDirectory: true)
            let link = mfUser
                .appendingPathComponent(folder.root.relativePath, isDirectory: true)
                .appendingPathComponent(folder.name, isDirectory: true)

            switch state(of: link, expecting: target) {
            case .correct:
                continue
            case .populatedDirectory:
                blocked.append(folder)
            case .absent, .emptyDirectory, .wrongLink, .identicalDirectory:
                // The target may not exist yet — a brand-new user profile after a runtime switch, or a game
                // whose first run happens on the MF side. Create it so the very first launch still shares
                // instead of quietly falling back to two separate copies.
                try? fileManager.createDirectory(at: target, withIntermediateDirectories: true)
                try? fileManager.createDirectory(at: link.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
                // No-op when absent; safe for an empty dir, a bad link, or a copy proven identical to the
                // target. NEVER reached for a populated directory whose contents differ.
                try? fileManager.removeItem(at: link)
                guard (try? fileManager.createSymbolicLink(at: link, withDestinationURL: target)) != nil else {
                    blocked.append(folder)
                    continue
                }
            }
        }
        return blocked
    }

    /// Undo the sharing for `folders`: remove the MF-side symlink so that game keeps its own saves there
    /// again. Returns the folders actually unlinked.
    ///
    /// Removes a path ONLY when it is a symlink pointing at this folder's counterpart in the canonical
    /// bottle — the exact condition `ensure` reads as "already correct". A real directory is never touched,
    /// nor is a link aimed somewhere else: unticking a checkbox must not be able to delete save data.
    ///
    /// What's left behind is nothing, not an empty stub: the saves live in the canonical bottle, which is
    /// what the link pointed at all along. The game recreates the folder on its next launch in the MF
    /// bottle and starts its own set there, which is what "no longer shared" means.
    @discardableResult
    public func unlink(_ folders: [SharedSaveFolder],
                       mfPrefix: URL, canonicalPrefix: URL) -> [SharedSaveFolder] {
        guard !folders.isEmpty,
              let mfUser = windowsUserDir(inPrefix: mfPrefix),
              let canonicalUser = windowsUserDir(inPrefix: canonicalPrefix) else { return [] }

        var removed: [SharedSaveFolder] = []
        for folder in folders {
            let target = canonicalUser
                .appendingPathComponent(folder.root.relativePath, isDirectory: true)
                .appendingPathComponent(folder.name, isDirectory: true)
            let link = mfUser
                .appendingPathComponent(folder.root.relativePath, isDirectory: true)
                .appendingPathComponent(folder.name, isDirectory: true)
            guard state(of: link, expecting: target) == .correct else { continue }
            if (try? fileManager.removeItem(at: link)) != nil { removed.append(folder) }
        }
        return removed
    }

    // MARK: - what is at the link path right now

    private enum LinkState {
        case absent
        case correct
        case wrongLink
        case emptyDirectory
        /// A real directory whose contents are byte-identical to the canonical side — the state a freshly
        /// cloned MF bottle is in. Nothing to reconcile and nothing to lose, so it's replaced by the link.
        case identicalDirectory
        case populatedDirectory
    }

    private func state(of link: URL, expecting target: URL) -> LinkState {
        guard let attributes = try? fileManager.attributesOfItem(atPath: link.path) else { return .absent }
        if attributes[.type] as? FileAttributeType == .typeSymbolicLink {
            let destination = try? fileManager.destinationOfSymbolicLink(atPath: link.path)
            // Compare resolved paths: the link may be relative, and either side may sit under /var vs
            // /private/var, which are the same directory by two names on macOS.
            let resolved = destination.map {
                URL(fileURLWithPath: $0, relativeTo: link.deletingLastPathComponent()).standardizedFileURL
            }
            return resolved?.resolvingSymlinksInPath() == target.resolvingSymlinksInPath()
                ? .correct : .wrongLink
        }
        let contents = (try? fileManager.contentsOfDirectory(atPath: link.path)) ?? []
        if contents.isEmpty { return .emptyDirectory }
        // The MF bottle is a CLONE, so right after building it every save folder exists on both sides with
        // identical contents — which looked exactly like the "played on both sides" case and blocked the
        // link in the single most common situation. `contentsEqual` walks the directories and compares file
        // contents: a name-and-size heuristic would be faster but would call two different saves of the
        // same size identical, and the cost of that mistake is deleting the MF-side copy.
        if fileManager.contentsEqual(atPath: link.path, andPath: target.path) { return .identicalDirectory }
        return .populatedDirectory
    }
}
