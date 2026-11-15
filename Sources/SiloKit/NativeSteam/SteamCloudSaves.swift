import Foundation

/// Steam Cloud for Windows games started from **macOS Steam** (decided with the user, 2026-11-14):
/// - the game's Steam Cloud rules point at ONE save folder per game, in the classic `SteamBottle`
///   (`AppInfoPatcher.enableCloud`, applied by the guard after every Steam session, so a refreshed appinfo can't drop
///   them — TEKKEN 8's hand-made override was lost that way);
/// - the macOS-Steam bottles (`SteamNative`, `SteamNativeMF`) link the game's folders to `SteamBottle`, so classic
///   Silo and macOS Steam read and write the same saves;
/// - cloud entries Steam marked Windows-only are made all-platform, or macOS Steam ignores them;
/// - nothing is ever lost: the classic folders are backed up before the first cloud launch, and a copy a
///   macOS-Steam bottle held on its own goes to the backup (or, if the classic side is empty, becomes the classic copy).
///   A remaining conflict between the local saves and the cloud is Steam's own dialog to settle.
public enum SteamCloudSaves {
    /// Steam's Windows save roots Silo links between bottles. `WinMyDocuments` is left out on purpose: a bottle's
    /// `Documents` is a link to the Mac's own Documents folder, so those saves are shared already.
    static let linkedRoots: [String: SharedSaveFolder.Root] = [
        "WinAppDataLocal": .appDataLocal,
        "WinAppDataRoaming": .appDataRoaming,
        "WinSavedGames": .savedGames,
    ]

    /// Pure: the save folders a game's Steam Cloud rules (`ufs.savefiles`) name under the Windows user profile — the
    /// first component of each rule's path (`TEKKEN 8/Saved/SaveGames/{64BitSteamID}` → `TEKKEN 8` in `AppData/Local`).
    /// A first component that is a Steam placeholder (`{64BitSteamID}`) or a root Silo doesn't link is skipped.
    public static func folders(savefiles: [BinaryKVEntry]?) -> [SharedSaveFolder] {
        var folders: [SharedSaveFolder] = []
        for rule in savefiles ?? [] {
            guard let entries = rule.value.children,
                  let root = entries.string("root").flatMap({ linkedRoots[$0] }),
                  let first = entries.string("path")?
                    .split(whereSeparator: { $0 == "/" || $0 == "\\" }).first.map(String.init),
                  !first.contains("{"), first != ".", first != ".." else { continue }
            let folder = SharedSaveFolder(root: root, name: first)
            if !folders.contains(folder) { folders.append(folder) }
        }
        return folders
    }

    /// Pure: `remotecache.vdf` with every `platformstosync2` set to -1 (all platforms), or nil when nothing changes.
    /// Steam writes 1 (Windows) for files it synced from a Windows client; macOS Steam then skips them (measured
    /// 2026-11-14: TEKKEN 8, 49 of 50 files; Spider-Man, all 12).
    public static func allPlatforms(remoteCache text: String) -> String? {
        var changed = false
        let lines = text.components(separatedBy: "\n").map { line -> String in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.lowercased().hasPrefix("\"platformstosync2\"") else { return line }
            let parts = trimmed.split(separator: "\"", omittingEmptySubsequences: true)
                .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            guard parts.count == 2, parts[1] != "-1",
                  let range = line.range(of: "\"\(parts[1])\"", options: .backwards) else { return line }
            changed = true
            return line.replacingCharacters(in: range, with: "\"-1\"")
        }
        return changed ? lines.joined(separator: "\n") : nil
    }

    /// The `remotecache.vdf` files Steam keeps for `appID`, one per Steam account on this Mac.
    public static func remoteCaches(steamRoot: URL, appID: UInt32, fileManager: FileManager = .default) -> [URL] {
        let userdata = steamRoot.appendingPathComponent("userdata", isDirectory: true)
        return ((try? fileManager.contentsOfDirectory(atPath: userdata.path)) ?? []).sorted().compactMap { account in
            let file = userdata.appendingPathComponent("\(account)/\(appID)/remotecache.vdf")
            return fileManager.fileExists(atPath: file.path) ? file : nil
        }
    }
}

extension SharedSaveLinker {
    /// For a macOS-Steam bottle: makes every folder in `bottle` a link to its counterpart in `canonical` (the classic
    /// `SteamBottle`), like `ensure`, but a folder the bottle holds with its own data is not left in place — the
    /// canonical side wins when it has data (the bottle's copy is MOVED into `backupDir`), and the bottle's copy BECOMES
    /// the canonical one when the canonical side is empty or missing. Returns one line per change, for the log.
    public func linkToCanonical(_ folders: [SharedSaveFolder], bottle: URL, canonical: URL, backupDir: URL) -> [String] {
        let fileManager = FileManager.default
        guard !folders.isEmpty, let bottleUser = windowsUserDir(inPrefix: bottle),
              let canonicalUser = windowsUserDir(inPrefix: canonical) else { return [] }
        var lines: [String] = []
        for folder in folders {
            let sub = "\(folder.root.relativePath)/\(folder.name)"
            let target = canonicalUser.appendingPathComponent(sub, isDirectory: true)
            let link = bottleUser.appendingPathComponent(sub, isDirectory: true)
            let isLink = (try? fileManager.attributesOfItem(atPath: link.path))?[.type] as? FileAttributeType
                == .typeSymbolicLink
            let holdsData = !isLink && !((try? fileManager.contentsOfDirectory(atPath: link.path)) ?? []).isEmpty
            if holdsData {
                let targetEmpty = ((try? fileManager.contentsOfDirectory(atPath: target.path)) ?? []).isEmpty
                if targetEmpty {
                    try? fileManager.removeItem(at: target)
                    try? fileManager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                    guard (try? fileManager.moveItem(at: link, to: target)) != nil else {
                        lines.append("\(sub): couldn't move \(bottle.lastPathComponent)'s saves to \(canonical.lastPathComponent)")
                        continue
                    }
                    lines.append("\(sub): \(bottle.lastPathComponent)'s saves became \(canonical.lastPathComponent)'s")
                } else {
                    let aside = backupDir.appendingPathComponent("\(bottle.lastPathComponent)/\(sub)", isDirectory: true)
                    try? fileManager.createDirectory(at: aside.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try? fileManager.removeItem(at: aside)
                    guard (try? fileManager.moveItem(at: link, to: aside)) != nil else {
                        lines.append("\(sub): couldn't back up \(bottle.lastPathComponent)'s saves, left as they are")
                        continue
                    }
                    lines.append("\(sub): \(bottle.lastPathComponent)'s own saves moved to \(aside.path)")
                }
            }
            // What's left is absent, empty, a link, or just moved away: `ensure` links it (and creates the target).
            if !ensure([folder], mfPrefix: bottle, canonicalPrefix: canonical).isEmpty {
                lines.append("\(sub): couldn't link to \(canonical.lastPathComponent)")
            }
        }
        return lines
    }

    /// Copies the canonical folders into `backupDir` once per game (a `.done` marker there), before the game's first
    /// launch with Steam Cloud on. Returns whether a backup was made now.
    @discardableResult
    public func backUpOnce(_ folders: [SharedSaveFolder], canonical: URL, backupDir: URL) -> Bool {
        let fileManager = FileManager.default
        let marker = backupDir.appendingPathComponent(".done")
        guard !folders.isEmpty, !fileManager.fileExists(atPath: marker.path),
              let canonicalUser = windowsUserDir(inPrefix: canonical) else { return false }
        try? fileManager.createDirectory(at: backupDir, withIntermediateDirectories: true)
        for folder in folders {
            let sub = "\(folder.root.relativePath)/\(folder.name)"
            let source = canonicalUser.appendingPathComponent(sub, isDirectory: true)
            guard fileManager.fileExists(atPath: source.path) else { continue }
            let copy = backupDir.appendingPathComponent(sub, isDirectory: true)
            try? fileManager.createDirectory(at: copy.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fileManager.copyItem(at: source, to: copy)
        }
        return fileManager.createFile(atPath: marker.path, contents: Data())
    }
}
