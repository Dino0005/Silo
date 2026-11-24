import Foundation

/// What an earlier Silo left under upstream's identifiers (`com.mikael.silo…`, until 2026-11-19), moved to the fork's
/// own (`Silo.bundleID`). Bundles Silo writes — game hosts and apps, shortcuts, "Steam (Silo)" — are rewritten under the
/// new identifiers by their own code (which still recognizes the old ones as Silo's); what is left here is what nothing
/// else would carry over: the preferences, and the guard's LaunchAgent with its label.
public enum LegacyIdentifiers {
    public static let appID = "com.mikael.silo"
    /// Set in the new preferences once the old ones were copied, so a later run never copies them again.
    static let migratedKey = "migratedFromLegacyIdentifier"

    /// Copies the preferences of `legacy` (the old domain) into `defaults` once — the onboarding flag, the library's
    /// filter and tile style, window frames. A key the new domain already has is kept. Returns the keys copied.
    @discardableResult
    public static func migratePreferences(into defaults: UserDefaults = .standard,
                                          legacy: [String: Any]? = UserDefaults.standard.persistentDomain(forName: appID))
        -> [String] {
        guard !defaults.bool(forKey: migratedKey) else { return [] }
        defer { defaults.set(true, forKey: migratedKey) }
        var copied: [String] = []
        for (key, value) in legacy ?? [:] where defaults.object(forKey: key) == nil {
            defaults.set(value, forKey: key)
            copied.append(key)
        }
        return copied.sorted()
    }

    static let guardLabel = appID + ".native-steam-guard"
    static let launcherIdentifier = appID + ".steam-launcher"

    /// Stops and removes the guard's LaunchAgent written under the old label (the new one is installed by
    /// `NativeSteamSetup.repointIfMoved`, which finds it missing), and clears the privacy grant macOS still lists for
    /// the old "Steam (Silo)" — else Privacy & Security shows two of them. Returns whether there was an old agent file.
    ///
    /// The job is booted out at every start, file or not: on the dev Mac (2026-11-19) the old guard was still loaded and
    /// running after its file was gone, next to the new one. A no-op when nothing is loaded under the old label.
    @discardableResult
    public static func retireGuard(home: URL, runner: ProcessRunning, fileManager: FileManager = .default) async -> Bool {
        let agent = home.appendingPathComponent("Library/LaunchAgents/\(guardLabel).plist")
        _ = try? await runner.run(executable: URL(fileURLWithPath: "/bin/launchctl"),
                                  arguments: ["bootout", "gui/\(getuid())/\(guardLabel)"], environment: [:], currentDirectory: nil)
        guard fileManager.fileExists(atPath: agent.path) else { return false }
        try? fileManager.removeItem(at: agent)
        _ = try? await runner.run(executable: URL(fileURLWithPath: "/usr/bin/tccutil"),
                                  arguments: ["reset", SteamLauncherApp.privacyService, launcherIdentifier],
                                  environment: [:], currentDirectory: nil)
        return true
    }

    // MARK: - Metal shader caches

    /// The folder macOS keeps each bundle's caches in (`<user cache dir>/<bundle id>/…`).
    public static var userCacheDirectory: URL {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        let n = confstr(_CS_DARWIN_USER_CACHE_DIR, &buffer, buffer.count)
        guard n > 0, n <= buffer.count else { return URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true) }
        let path = String(decoding: buffer.prefix(n - 1).map { UInt8(bitPattern: $0) }, as: UTF8.self)   // n counts the NUL
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    /// Metal keeps the shaders it compiled per bundle identifier, in `<id>/com.apple.metal/<GPU and macOS>/` as
    /// `functions.data` + `functions.list` (and `libraries.*`). So the rename left every game's compiled shaders under
    /// its old host and game identifiers, and each game compiled them all again (TEKKEN 8 on the dev Mac, 2026-11-20:
    /// 855 MB under the old host id, 502 MB under the old game id, 323 MB rebuilt under the new one).
    ///
    /// For each game, the fullest copy of each cache file among its old host and game folders goes into its new host
    /// and game folders — they hold the same game's shaders, and Metal checks each entry by its key. A copy is an APFS
    /// clone, so it takes no space of its own. A new file is left alone when it is already as full, or while a process
    /// holds it: Metal keeps an exclusive `flock` on the file for as long as it uses it (measured 2026-11-20). An old
    /// folder is removed once nothing in it is still needed; one skipped for a running game is retried at the next
    /// start. Returns the new cache files written, as `<bundle id>/<GPU>/<file>`.
    @discardableResult
    public static func migrateMetalCaches(cacheRoot: URL = userCacheDirectory, fileManager: FileManager = .default) -> [String] {
        let legacyPrefixes = [appID + ".host.", appID + ".game."]
        let newPrefixes = [GameHostBundle.bundleIDPrefix, GameHostBundle.gameAppIDPrefix]
        let names = (try? fileManager.contentsOfDirectory(atPath: cacheRoot.path)) ?? []
        // The old folders of each game, by the id after the prefix.
        var legacy: [String: [URL]] = [:]
        for name in names.sorted() {
            guard let prefix = legacyPrefixes.first(where: { name.hasPrefix($0) }) else { continue }
            legacy[String(name.dropFirst(prefix.count)), default: []].append(cacheRoot.appendingPathComponent(name))
        }
        var written: [String] = []
        for (id, folders) in legacy.sorted(by: { $0.key < $1.key }) {
            // "<GPU>/<file>.data" → the fullest old copy; the .list beside it travels with it.
            var fullest: [String: (url: URL, size: Int)] = [:]
            var complete = true
            for folder in folders {
                let metal = folder.appendingPathComponent("com.apple.metal")
                for gpu in (try? fileManager.contentsOfDirectory(atPath: metal.path)) ?? [] {
                    let dir = metal.appendingPathComponent(gpu)
                    for file in (try? fileManager.contentsOfDirectory(atPath: dir.path)) ?? [] where file.hasSuffix(".data") {
                        let data = dir.appendingPathComponent(file)
                        guard fileManager.fileExists(atPath: listFile(for: data).path) else { continue }
                        if isHeld(data) { complete = false; continue }
                        let size = fileSize(data, fileManager)
                        let key = gpu + "/" + file
                        if size > (fullest[key]?.size ?? 0) { fullest[key] = (data, size) }
                    }
                }
            }
            // A manual game (a UUID) is never started from Steam for macOS: it gets no game-app cache.
            for prefix in newPrefixes where prefix != GameHostBundle.gameAppIDPrefix || ShaderCache.isSteamID(id) {
                for (key, source) in fullest.sorted(by: { $0.key < $1.key }) {
                    let dest = cacheRoot.appendingPathComponent(prefix + id).appendingPathComponent("com.apple.metal")
                        .appendingPathComponent(key)
                    if fileManager.fileExists(atPath: dest.path) {
                        if isHeld(dest) { complete = false; continue }
                        if fileSize(dest, fileManager) >= source.size { continue }
                    }
                    do {
                        try fileManager.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                        for (from, to) in [(source.url, dest), (listFile(for: source.url), listFile(for: dest))] {
                            try? fileManager.removeItem(at: to)
                            try fileManager.copyItem(at: from, to: to)   // clonefile on APFS
                        }
                        written.append(prefix + id + "/" + key)
                    } catch {
                        complete = false
                    }
                }
            }
            if complete { for folder in folders { try? fileManager.removeItem(at: folder) } }
        }
        return written
    }

    private static func listFile(for data: URL) -> URL {
        data.deletingPathExtension().appendingPathExtension("list")
    }

    private static func fileSize(_ url: URL, _ fileManager: FileManager) -> Int {
        ((try? fileManager.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.intValue ?? 0
    }

    /// Whether a process holds `url` the way Metal holds a cache file it is using (an exclusive `flock`).
    static func isHeld(_ url: URL) -> Bool {
        let fd = open(url.path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { return errno == EWOULDBLOCK }
        flock(fd, LOCK_UN)
        return false
    }
}
