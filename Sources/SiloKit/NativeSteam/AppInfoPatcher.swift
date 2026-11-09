import Foundation

/// The edits that make stock macOS Steam install and launch a Windows-only game through Silo, applied to one
/// app's `appinfo.vdf` entry (see `AppInfoCache`). Pure: no file I/O, so every rule is table-tested.
///
/// What it does, and why each part is needed (all measured on macOS Steam, 2026-11-08):
/// - `common.oslist` and every Windows depot's `oslist` gain `macos`, so Steam offers Install and downloads the
///   Windows depots as if they were the game's Mac build.
/// - A launch entry (`SiloLaunch.entryKey`) whose executable is Silo's shim, pinned to macOS + 64-bit; the
///   game's own entries are pinned to Windows, otherwise an entry without an `oslist` matches every platform
///   and Steam asks which one to run.
/// - `osarch = 64` on `common`, which Steam reads as "this macOS build is 64-bit".
/// - Steam Cloud: every `ufs.savefiles` rule is made to apply on all platforms, and `ufs.rootoverrides` maps the
///   Windows roots it uses onto the bottle's user folder for macOS — Steam's own mechanism (Feral's ports use
///   it) so cloud file names stay the Windows ones and saves remain shared with Windows PCs.
/// The approach is the one mont127/Neutron (Apache-2.0) proved; this is an independent implementation.
public enum AppInfoPatcher {
    /// Silo's launch entry key: far from Valve's own (which count up from 0).
    public static let entryKey = "9000"

    public struct Result: Sendable, Equatable {
        public var changes: [String] = []
        public var changed: Bool { !changes.isEmpty }
    }

    /// Prepares `app` to be installed and played through Silo.
    /// - Parameters:
    ///   - shim: the launch entry's executable, relative to the game's install dir (Steam resolves it there),
    ///     e.g. `../Silo Runtime/silo-launch`.
    ///   - preferWindows: for a game that ALSO has a macOS build, hide that build so Steam installs the Windows
    ///     one. Off: a game Steam already considers macOS-eligible is left alone (its native build wins).
    public static func enableSiloLaunch(_ app: inout AppInfoCache.App, shim: String,
                                        preferWindows: Bool = false) -> Result {
        var result = Result()
        var info = app.info
        // Already patched by Silo (a re-apply after Steam refreshed the entry, or a second run): the "macos" in
        // its oslist is ours, so it must not be mistaken for a native Mac build.
        // "Mac-eligible" = a real Mac build of its own, not a `macos` Silo added (an earlier protect/enable pass —
        // Steam keeps that edit across sessions, so the oslist alone can't tell the two apart).
        let wasMacEligible = hasNativeMacBuild(info)
        if wasMacEligible, !preferWindows { return result }
        // A game that never ran on macOS can still carry a dead Mac depot or launch entry (left over from a
        // dropped port); Steam would pick that over ours, so it is hidden exactly like an unwanted Mac build.
        let hideMacContent = preferWindows || !wasMacEligible

        info.editMap("common") { common in
            if addOS(&common, "oslist") { result.changes.append("common.oslist += macos") }
            if common.string("osarch") != "64" {
                common.setString("osarch", "64")
                result.changes.append("common.osarch = 64")
            }
            if addOS(&common, "osextended", "macos64") { result.changes.append("common.osextended += macos64") }
        }

        info.editMap("depots") { depots in
            for i in depots.indices {
                guard depots[i].key.allSatisfy(\.isNumber), case .map(var depot) = depots[i].value else { continue }
                let key = depots[i].key
                depot.editMap("config") { config in
                    let os = (config.string("oslist") ?? "").osList
                    if hideMacContent, os.contains("macos"), !os.contains("windows") {
                        if dropOS(&config, "oslist") { result.changes.append("depot \(key): mac build hidden") }
                    } else if os.contains("windows"), addOS(&config, "oslist") {
                        result.changes.append("depot \(key).oslist += macos")
                    }
                }
                depots[i].value = .map(depot)
            }
        }

        var windowsExe: String?
        info.editMap("config", create: true) { config in
            config.editMap("launch", create: true) { launches in
                let previous = launches.first { $0.key == entryKey }
                launches.remove(entryKey)
                for i in launches.indices {
                    guard case .map(var entry) = launches[i].value else { continue }
                    let key = launches[i].key
                    entry.editMap("config", create: true) { cfg in
                        let os = (cfg.string("oslist") ?? "").trimmingCharacters(in: .whitespaces)
                        if os.isEmpty {
                            cfg.setString("oslist", "windows")
                            result.changes.append("launch \(key) pinned to windows")
                        } else if hideMacContent, os.osList.contains("macos"), dropOS(&cfg, "oslist") {
                            result.changes.append("launch \(key): mac entry hidden")
                        }
                    }
                    let os = (entry.map("config")?.string("oslist") ?? "").osList
                    if windowsExe == nil, os.contains("windows"), let exe = entry.string("executable"),
                       !isHelperExecutable(exe) {
                        windowsExe = exe
                    }
                    launches[i].value = .map(entry)
                }
                var arguments = "--appid \(app.appID)"
                if let windowsExe { arguments += " --exe \"\(windowsExe)\"" }
                let entry = BinaryKVEntry(entryKey, .map([
                    BinaryKVEntry("executable", .string(shim)),
                    BinaryKVEntry("arguments", .string(arguments)),
                    BinaryKVEntry("type", .string("default")),
                    BinaryKVEntry("config", .map([
                        BinaryKVEntry("oslist", .string("macos")),
                        BinaryKVEntry("osarch", .string("64")),
                    ])),
                ]))
                launches.append(entry)
                // Re-applying an identical entry is no change (the guard runs this after every Steam exit).
                if previous != entry { result.changes.append("launch \(entryKey) -> \(shim)") }
            }
        }
        app.info = info
        return result
    }

    /// The minimal edit that keeps stock macOS Steam from DELETING an installed Windows-only game.
    ///
    /// Measured 2026-11-08/09 (five games lost, `content_log.txt`: "finished update, 0 mounted depots"): for a
    /// game whose depots are all `oslist windows`, the Mac depot set is empty, so the first auto-update or
    /// validate macOS Steam runs on it commits that empty set and removes every file. Adding `macos` to
    /// `common.oslist` and to each Windows depot makes Steam treat the Windows files as the Mac build — the same
    /// edit `enableSiloLaunch` makes, without its launch entry or cloud rules.
    /// Why the edit survives a running Steam (measured 2026-11-09): when Steam's servers announce a new change
    /// number it compares the entry's content hash (the header's text SHA-1, which Silo leaves untouched) and, if
    /// it is unchanged, keeps its local — patched — copy and only stores the new number. Only a real metadata
    /// change on Valve's side brings the unpatched entry back mid-session; `NativeSteamShadow` covers that case.
    /// `common.osextended` gains `macos64`, the flag Steam reads as "64-bit Mac build" (native 64-bit ports carry
    /// it: Dota 2, Tomb Raider…); without it Steam shows the red "macOS can't run 32-bit games like this" banner.
    /// Left alone: a game with a native Mac build (`hasNativeMacBuild`), and one with no `oslist` at all
    /// (Steam already counts its files for every platform).
    public static func protectWindowsInstall(_ app: inout AppInfoCache.App) -> Result {
        var result = Result()
        var info = app.info
        guard isWindowsGame(info) else { return result }
        info.editMap("common") { common in
            if addOS(&common, "oslist") { result.changes.append("common.oslist += macos") }
            if addOS(&common, "osextended", "macos64") { result.changes.append("common.osextended += macos64") }
        }
        info.editMap("depots") { depots in
            for i in depots.indices {
                guard depots[i].key.allSatisfy(\.isNumber), case .map(var depot) = depots[i].value else { continue }
                let key = depots[i].key
                depot.editMap("config") { config in
                    if (config.string("oslist") ?? "").osList.contains("windows"), addOS(&config, "oslist") {
                        result.changes.append("depot \(key).oslist += macos")
                    }
                }
                depots[i].value = .map(depot)
            }
        }
        app.info = info
        return result
    }

    /// Where each Windows Steam Cloud root lives inside a Wine user folder (`drive_c/users/<user>`).
    public static let windowsRootSubpaths: [String: String] = [
        "WinMyDocuments": "Documents",
        "WinAppDataLocal": "AppData/Local",
        "WinAppDataLocalLow": "AppData/LocalLow",
        "WinAppDataRoaming": "AppData/Roaming",
        "WinSavedGames": "Saved Games",
    ]

    /// Makes the app's Steam Cloud rules work on macOS against a bottle.
    /// - Parameter userFolderFromHome: the bottle's Wine user folder relative to the macOS home folder, e.g.
    ///   `Library/Application Support/Silo/SteamNative/drive_c/users/crossover` (Steam's `MacHome` root).
    /// Rules rooted at the game's install dir need nothing; a root Silo can't place is reported, not guessed.
    public static func enableCloud(_ app: inout AppInfoCache.App, userFolderFromHome: String) -> Result {
        var result = Result()
        var info = app.info
        guard info.map("ufs") != nil else { return result }
        var roots: [String] = []
        info.editMap("ufs") { ufs in
            ufs.editMap("savefiles") { rules in
                for i in rules.indices {
                    guard case .map(var rule) = rules[i].value else { continue }
                    if let root = rule.string("root"), !roots.contains(root) { roots.append(root) }
                    let platforms = rule.map("platforms")?.compactMap { $0.value.stringValue } ?? []
                    if !platforms.contains(where: { $0.caseInsensitiveCompare("all") == .orderedSame }) {
                        rule.set("platforms", .map([BinaryKVEntry("1", .string("all"))]))
                        result.changes.append("savefiles \(rules[i].key): all platforms")
                    }
                    rules[i].value = .map(rule)
                }
            }
            var overrides: [BinaryKVEntry] = []
            for root in roots {
                guard let sub = windowsRootSubpaths[root] else {
                    if root.caseInsensitiveCompare("gameinstall") != .orderedSame {
                        result.changes.append("root \(root): not mapped")
                    }
                    continue
                }
                overrides.append(BinaryKVEntry(String(overrides.count), .map([
                    BinaryKVEntry("root", .string(root)),
                    BinaryKVEntry("os", .string("MacOS")),
                    BinaryKVEntry("oscompare", .string("=")),
                    BinaryKVEntry("useinstead", .string("MacHome")),
                    BinaryKVEntry("addpath", .string("\(userFolderFromHome)/\(sub)")),
                ])))
                result.changes.append("root \(root) -> ~/\(userFolderFromHome)/\(sub)")
            }
            // Ours replace any macOS overrides Valve shipped (they point at a native port's folders); other
            // platforms' overrides are kept.
            var kept = (ufs.map("rootoverrides") ?? []).filter {
                ($0.value.children?.string("os") ?? "").caseInsensitiveCompare("MacOS") != .orderedSame
            }
            for entry in overrides { kept.append(BinaryKVEntry(String(kept.count), entry.value)) }
            if !kept.isEmpty {
                for i in kept.indices { kept[i].key = String(i) }
                ufs.set("rootoverrides", .map(kept))
            }
        }
        app.info = info
        return result
    }

    /// A Windows game Silo looks after: a Windows `oslist` and no native Mac build of its own.
    public static func isWindowsGame(_ info: [BinaryKVEntry]) -> Bool {
        (info.map("common")?.string("oslist") ?? "").osList.contains("windows") && !hasNativeMacBuild(info)
    }

    /// Whether the app ships its own Mac build: a depot for macOS but not Windows, or a launch entry for macOS
    /// other than Silo's. A Windows game Silo protected or enabled has neither (its depots read "windows,macos").
    static func hasNativeMacBuild(_ info: [BinaryKVEntry]) -> Bool {
        for depot in info.map("depots") ?? [] where depot.key.allSatisfy(\.isNumber) {
            guard case .map(let map) = depot.value else { continue }
            let os = (map.map("config")?.string("oslist") ?? "").osList
            if os.contains("macos"), !os.contains("windows") { return true }
        }
        for entry in info.map("config")?.map("launch") ?? [] where entry.key != entryKey {
            guard case .map(let map) = entry.value else { continue }
            if (map.map("config")?.string("oslist") ?? "").osList.contains("macos") { return true }
        }
        return false
    }

    /// Launchers, uninstallers and config tools a game lists next to its real executable.
    static func isHelperExecutable(_ exe: String) -> Bool {
        let lower = exe.lowercased()
        return ["legacy", "cfg.exe", "unins", "redist", "vcredist", "dxsetup"].contains { lower.contains($0) }
    }

    @discardableResult
    static func addOS(_ map: inout [BinaryKVEntry], _ key: String, _ os: String = "macos") -> Bool {
        var list = (map.string(key) ?? "").osList
        guard !list.contains(os) else { return false }
        list.append(os)
        map.setString(key, list.joined(separator: ","))
        return true
    }

    @discardableResult
    static func dropOS(_ map: inout [BinaryKVEntry], _ key: String, _ os: String = "macos") -> Bool {
        let list = (map.string(key) ?? "").osList
        guard list.contains(os) else { return false }
        map.setString(key, list.filter { $0 != os }.joined(separator: ","))
        return true
    }
}

extension String {
    /// A Steam `oslist` value ("windows,macos") as its lowercase parts.
    var osList: [String] {
        split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty }
    }
}
