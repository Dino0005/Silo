import Foundation

/// Keeps a game started from **macOS Steam** and Steam itself from driving the same controller (NotProton's
/// `plan_hidden_controllers` + `plan_disable_hidraw`, commit 98d2929, upstream 1.1.0).
///
/// When Steam Input handles a pad for a game, Steam lists it in `SDL_GAMECONTROLLER_IGNORE_DEVICES`. Wine's SDL bus
/// honors that list, but CrossOver's Wine also reads DualSense, DualShock 4 and Switch pads directly through hidraw —
/// measured 2026-11-10: FATAL FURY did so while Steam held a Bluetooth DualSense, and the pad went dark and dead for
/// Steam as well until it was re-identified. So every listed pad
/// gets `WineBus\Devices\<vid/pid>` `Hidraw=0` in the bottle (as Proton does on Linux), and Switch pads always do.
/// With Steam Input off Steam lists no physical pad, so nothing is hidden and the game reads the pad directly
/// (PlayStation glyphs). The keys Silo wrote are listed in the bottle, so only Silo's own are removed later and a key
/// the user set by hand is never touched. `EnvFlags.disableHidraw` adds `WineBus` `DisableHidraw=1`, removed again
/// only if Silo set it.
///
/// A manual (non-Steam) game gets only the `DisableHidraw` part (`hideSteamInputPads: false`): no Steam Input runs
/// for it, so no pad is hidden, Switch pads included.
public enum SteamInputControllers {
    /// Switch Pro Controller and Joy-Cons: hidden even with Steam Input off (NotProton: most games break otherwise).
    static let alwaysHidden: Set<String> = ["057e/2006", "057e/2007", "057e/2009"]
    static let ownedListName = ".silo-hidden-controllers"
    static let hidrawMarkerName = ".silo-disable-hidraw"
    static let busKey = #"HKEY_LOCAL_MACHINE\System\CurrentControlSet\Services\WineBus"#

    /// `0xVVVV/0xPPPP` entries of an SDL device list, as lowercase `vvvv/pppp`.
    static func ids(_ list: String?) -> Set<String> {
        Set((list ?? "").split(separator: ",").compactMap { entry in
            let parts = entry.trimmingCharacters(in: .whitespaces).lowercased().split(separator: "/")
            guard parts.count == 2, parts.allSatisfy({ $0.hasPrefix("0x") && $0.count == 6 }),
                  parts.allSatisfy({ $0.dropFirst(2).allSatisfy(\.isHexDigit) }) else { return nil }
            return "\(parts[0].dropFirst(2))/\(parts[1].dropFirst(2))"
        })
    }

    /// The `WineBus\Devices\<vid/pid>` keys already in `system.reg`, and whether `DisableHidraw` is set.
    static func registryState(systemReg text: String) -> (devices: Set<String>, disableHidraw: Bool) {
        let devicePrefix = #"[system\\controlset001\\services\\winebus\\devices\\"#
        let bus = #"[system\\controlset001\\services\\winebus]"#
        var devices: Set<String> = [], inBus = false, hidraw = false
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces).lowercased()
            guard line.hasPrefix("[") else {
                if inBus, line == #""disablehidraw"=dword:00000001"# { hidraw = true }
                continue
            }
            inBus = line.hasPrefix(bus)
            if line.hasPrefix(devicePrefix) {
                let rest = line.dropFirst(devicePrefix.count)
                if let end = rest.firstIndex(of: "]") {
                    let id = String(rest[..<end])
                    if ids("0x" + id.replacingOccurrences(of: "/", with: "/0x")) == [id] { devices.insert(id) }
                }
            }
        }
        return (devices, hidraw)
    }

    /// What to change this launch.
    public struct Plan: Sendable, Equatable {
        public var hide: [String]
        public var unhide: [String]
        /// The list to record once the import succeeded.
        public var owned: [String]
        /// `true` set `DisableHidraw`, `false` remove it, `nil` leave it.
        public var disableHidraw: Bool?
        public var isEmpty: Bool { hide.isEmpty && unhide.isEmpty && disableHidraw == nil }
    }

    /// Pure: NotProton's rules over Steam's environment, the game's flags and the bottle's current state.
    static func plan(environment: [String: String], flags: EnvFlags, owned: Set<String>,
                     inRegistry: Set<String>, hidrawSet: Bool, hidrawMarker: Bool,
                     hideSteamInputPads: Bool = true) -> Plan {
        // Always (NotProton's raw-controllers escape hatch was dropped, 2026-11-13). Keys the user set by hand stay theirs.
        let wanted = hideSteamInputPads
            ? ids(environment["SDL_GAMECONTROLLER_IGNORE_DEVICES"])
                .subtracting(ids(environment["SDL_GAMECONTROLLER_IGNORE_DEVICES_EXCEPT"]))
                .union(alwaysHidden)
                .subtracting(inRegistry.subtracting(owned))
            : []
        var hidraw: Bool?
        if flags.disableHidraw, !hidrawSet { hidraw = true }
        if !flags.disableHidraw, hidrawMarker, hidrawSet { hidraw = false }
        return Plan(hide: wanted.subtracting(inRegistry).sorted(), unhide: owned.subtracting(wanted).sorted(),
                    owned: wanted.sorted(), disableHidraw: hidraw)
    }

    /// REGEDIT4 text for `plan`.
    static func registryText(_ plan: Plan) -> String {
        var reg = "REGEDIT4\r\n\r\n"
        for id in plan.hide { reg += "[\(busKey)\\Devices\\\(id)]\r\n\"Hidraw\"=dword:00000000\r\n\r\n" }
        for id in plan.unhide { reg += "[-\(busKey)\\Devices\\\(id)]\r\n\r\n" }
        if let hidraw = plan.disableHidraw {
            reg += "[\(busKey)]\r\n\"DisableHidraw\"=\(hidraw ? "dword:00000001" : "-")\r\n\r\n"
        }
        return reg
    }

    /// Applies the plan to `prefix` with one `wine regedit /S` (nothing runs when there is nothing to change) and
    /// records what Silo now owns. Returns a line for the launch log, or nil when nothing changed.
    ///
    /// After an import Silo waits — up to `waitLimit` — for the bottle's wineserver to exit before returning. The
    /// `regedit` starts the bottle's services, and `winebus.sys` reads its settings then, i.e. possibly BEFORE the
    /// import landed; that server would live on into the game, which then saw the pads as the previous game wanted
    /// (likely cause of TEKKEN 8's Xbox glyphs on the first launch after a game with Steam Input on, 2026-11-13).
    /// Skipped when the bottle was already running something: then waiting can't help and could last the whole game.
    @discardableResult
    public static func apply(environment: [String: String], flags: EnvFlags, prefix: URL, wine: URL,
                             runner: ProcessRunning, hideSteamInputPads: Bool = true,
                             fileManager: FileManager = .default,
                             isLive: @Sendable (URL) -> Bool = { WineServerProbe.isLive(prefix: $0) },
                             waitLimit: Duration = .seconds(20),
                             pollInterval: Duration = .milliseconds(250)) async -> String? {
        let wasLive = isLive(prefix)
        let ownedURL = prefix.appendingPathComponent(ownedListName)
        let markerURL = prefix.appendingPathComponent(hidrawMarkerName)
        let owned = Set(((try? String(contentsOf: ownedURL, encoding: .utf8)) ?? "")
            .split(whereSeparator: \.isNewline).map(String.init).filter { ids("0x" + $0.replacingOccurrences(of: "/", with: "/0x")) == [$0] })
        let state = registryState(systemReg: (try? String(contentsOf: prefix.appendingPathComponent("system.reg"),
                                                          encoding: .utf8)) ?? "")
        let plan = plan(environment: environment, flags: flags, owned: owned, inRegistry: state.devices,
                        hidrawSet: state.disableHidraw, hidrawMarker: fileManager.fileExists(atPath: markerURL.path),
                        hideSteamInputPads: hideSteamInputPads)
        if !plan.isEmpty {
            let name = "silo-controllers.reg"
            let file = prefix.appendingPathComponent("drive_c/\(name)")
            guard (try? registryText(plan).write(to: file, atomically: true, encoding: .utf8)) != nil else {
                return "controllers: could not write the registry file"
            }
            let result = try? await runner.run(
                executable: wine, arguments: ["regedit", "/S", "C:\\\(name)"],
                environment: Silo.syncWineEnvironment(prefix: prefix, wine: wine, syncMode: flags.syncMode),
                currentDirectory: prefix)
            try? fileManager.removeItem(at: file)
            guard result?.succeeded == true else { return "controllers: registry import failed, left as they were" }
            if !wasLive {
                let clock = ContinuousClock(), deadline = clock.now.advanced(by: waitLimit)
                while isLive(prefix), clock.now < deadline { try? await Task.sleep(for: pollInterval) }
            }
        }
        try? (plan.owned.joined(separator: "\n") + (plan.owned.isEmpty ? "" : "\n"))
            .write(to: ownedURL, atomically: true, encoding: .utf8)
        if plan.disableHidraw == true { fileManager.createFile(atPath: markerURL.path, contents: Data()) }
        if plan.disableHidraw == false || (!flags.disableHidraw && !state.disableHidraw) {
            try? fileManager.removeItem(at: markerURL)
        }
        guard !plan.isEmpty else { return nil }
        var parts = hideSteamInputPads || !plan.owned.isEmpty ? ["\(plan.owned.count) kept off hidraw"] : []
        if !plan.unhide.isEmpty { parts.append("\(plan.unhide.count) given back") }
        if let hidraw = plan.disableHidraw { parts.append(hidraw ? "hidraw disabled" : "hidraw re-enabled") }
        return "controllers: " + parts.joined(separator: ", ")
    }
}
