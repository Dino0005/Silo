import Foundation
import Testing
@testable import SiloKit

@Suite("SteamInputControllers")
struct SteamInputControllersTests {
    /// Steam Input ON for FATAL FURY (2026-11-10): Valve's own devices plus the DualSense.
    let steamInputOn = ["SDL_GAMECONTROLLER_IGNORE_DEVICES": "0x28de/0x11ff,0x054C/0x0CE6, 0x054c/0x05c4,junk,0x12/0x3456"]

    @Test("Steam's device list is read as lowercase vid/pid; malformed entries are skipped")
    func parsesIDs() {
        #expect(SteamInputControllers.ids(steamInputOn["SDL_GAMECONTROLLER_IGNORE_DEVICES"])
                == ["28de/11ff", "054c/0ce6", "054c/05c4"])
        #expect(SteamInputControllers.ids(nil).isEmpty)
    }

    @Test("system.reg: existing WineBus device keys and DisableHidraw are found")
    func readsRegistry() {
        let reg = #"""
            [System\\ControlSet001\\Services\\WineBus] 1786369847
            #time=1dd28d
            "DisableHidraw"=dword:00000001

            [System\\ControlSet001\\Services\\WineBus\\Devices\\054c/0ce6] 1794335365
            "Hidraw"=dword:00000000

            [System\\ControlSet001\\Services\\WineBus\\Devices\\not-an-id] 1
            """#
        let state = SteamInputControllers.registryState(systemReg: reg)
        #expect(state.devices == ["054c/0ce6"] && state.disableHidraw)
        #expect(!SteamInputControllers.registryState(systemReg: "[System\\\\ControlSet001\\\\Services\\\\WineBus]\n").disableHidraw)
    }

    @Test("Steam Input on: its pads + Switch are hidden")
    func plans() {
        let plan = SteamInputControllers.plan(environment: steamInputOn, flags: EnvFlags(), owned: [], inRegistry: [],
                                              hidrawSet: false, hidrawMarker: false)
        #expect(plan.hide == ["054c/05c4", "054c/0ce6", "057e/2006", "057e/2007", "057e/2009", "28de/11ff"])
        #expect(plan.unhide.isEmpty && plan.disableHidraw == nil && plan.owned == plan.hide)
    }

    @Test("Configs with the retired steamXboxPad / rawControllers keys still decode, and the key isn't written back")
    func retiredPadKeys() throws {
        let old = try JSONDecoder().decode(EnvFlags.self, from: Data(
            #"{"steamXboxPad": true, "rawControllers": true, "disableHidraw": true}"#.utf8))
        #expect(old.disableHidraw)
        let written = String(decoding: try JSONEncoder().encode(old), as: UTF8.self)
        #expect(!written.contains("steamXboxPad") && !written.contains("rawControllers"))
    }

    @Test("Steam's virtual pad always reaches Wine as Xbox: its description is dropped, the rest of Steam's env kept")
    func virtualPadAlwaysXbox() {
        let env = ["SteamVirtualGamepadInfo": "/x.txt", "SDL_GAMECONTROLLER_IGNORE_DEVICES": "0x054c/0x0ce6",
                   "SteamAppId": "1778820", "STEAM_COMPAT_PROTON": "1", "SteamVirtualGamepadInfo_Proton": "/x.txt"]
        #expect(NativeSteamBridge.withoutVirtualGamepadInfo(env)
                == ["SDL_GAMECONTROLLER_IGNORE_DEVICES": "0x054c/0x0ce6", "SteamAppId": "1778820"])
        #expect(NativeSteamBridge.withoutVirtualGamepadInfo([:]).isEmpty)
    }

    @Test("Steam Input off: the DualSense Silo hid before is given back; only Switch stays hidden")
    func steamInputOff() {
        let plan = SteamInputControllers.plan(
            environment: ["SDL_GAMECONTROLLER_IGNORE_DEVICES": "0x28de/0x11ff"], flags: EnvFlags(),
            owned: ["054c/0ce6", "28de/11ff"], inRegistry: ["054c/0ce6", "28de/11ff"], hidrawSet: false, hidrawMarker: false)
        #expect(plan.unhide == ["054c/0ce6"])
        #expect(plan.hide == ["057e/2006", "057e/2007", "057e/2009"])
    }

    @Test("A key the user set by hand is never taken over or removed; _EXCEPT entries are not hidden")
    func respectsUserKeys() {
        var env = steamInputOn
        env["SDL_GAMECONTROLLER_IGNORE_DEVICES_EXCEPT"] = "0x054c/0x05c4"
        let plan = SteamInputControllers.plan(environment: env, flags: EnvFlags(), owned: [],
                                              inRegistry: ["054c/0ce6"], hidrawSet: false, hidrawMarker: false)
        #expect(!plan.hide.contains("054c/0ce6") && !plan.owned.contains("054c/0ce6"))
        #expect(!plan.hide.contains("054c/05c4"))
    }

    @Test("Disattiva hidraw: set when asked; removed only when Silo set it")
    func disableHidraw() {
        func p(_ on: Bool, set: Bool, marker: Bool) -> Bool? {
            SteamInputControllers.plan(environment: [:], flags: EnvFlags(disableHidraw: on), owned: SteamInputControllers.alwaysHidden,
                                       inRegistry: SteamInputControllers.alwaysHidden, hidrawSet: set, hidrawMarker: marker).disableHidraw
        }
        #expect(p(true, set: false, marker: false) == true)
        #expect(p(true, set: true, marker: true) == nil)
        #expect(p(false, set: true, marker: true) == false)
        #expect(p(false, set: true, marker: false) == nil)   // the user's own value
    }

    @Test("Steam Input holds a DualSense when Steam lists one (or the Edge) among the pads it handles")
    func holdsDualSense() {
        #expect(SteamInputControllers.steamInputHoldsDualSense(steamInputOn))
        #expect(!SteamInputControllers.steamInputHoldsDualSense([:]))
        #expect(SteamInputControllers.steamInputHoldsDualSense(["SDL_GAMECONTROLLER_IGNORE_DEVICES": "0x054c/0x0df2"]))
        #expect(!SteamInputControllers.steamInputHoldsDualSense(["SDL_GAMECONTROLLER_IGNORE_DEVICES": "0x28de/0x11ff"]))
    }

    @Test("A manual game gets only DisableHidraw: no pad hidden, Switch pads included, even with Steam's lists")
    func manualGameOnlyTogglesHidraw() {
        let plan = SteamInputControllers.plan(environment: steamInputOn, flags: EnvFlags(disableHidraw: true), owned: [],
                                              inRegistry: [], hidrawSet: false, hidrawMarker: false,
                                              hideSteamInputPads: false)
        #expect(plan.hide.isEmpty && plan.owned.isEmpty && plan.unhide.isEmpty)
        #expect(plan.disableHidraw == true)
        #expect(SteamInputControllers.plan(environment: [:], flags: EnvFlags(), owned: [], inRegistry: [],
                                           hidrawSet: false, hidrawMarker: false, hideSteamInputPads: false).isEmpty)
    }

    @Test("For a manual game, apply writes DisableHidraw once, then removes only what it set")
    func manualGameApply() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let prefix = try tmp.makeDir("bottle")
        try tmp.makeDir("bottle/drive_c")
        let fake = FakeProcessRunner()
        let wine = URL(fileURLWithPath: "/w/bin/wine64")
        let on = await SteamInputControllers.apply(environment: [:], flags: EnvFlags(disableHidraw: true), prefix: prefix,
                                                   wine: wine, runner: fake, hideSteamInputPads: false,
                                                   isLive: { _ in false })
        #expect(on == "controllers: hidraw disabled")
        #expect(fake.invocations.count == 1)
        #expect(FileManager.default.fileExists(atPath: prefix.appendingPathComponent(".silo-disable-hidraw").path))
        // Wine wrote it; turned off, Silo takes back its own value.
        try tmp.write("bottle/system.reg", "[System\\\\ControlSet001\\\\Services\\\\winebus] 1\n\"DisableHidraw\"=dword:00000001\n")
        let off = await SteamInputControllers.apply(environment: [:], flags: EnvFlags(), prefix: prefix, wine: wine,
                                                    runner: fake, hideSteamInputPads: false, isLive: { _ in false })
        #expect(off == "controllers: hidraw re-enabled")
        #expect(!FileManager.default.fileExists(atPath: prefix.appendingPathComponent(".silo-disable-hidraw").path))
    }

    @Test("The registry text hides, gives back and toggles DisableHidraw in REGEDIT4 form")
    func registryText() {
        let text = SteamInputControllers.registryText(.init(hide: ["054c/0ce6"], unhide: ["28de/11ff"], owned: [], disableHidraw: false))
        #expect(text.hasPrefix("REGEDIT4\r\n"))
        #expect(text.contains(#"[HKEY_LOCAL_MACHINE\System\CurrentControlSet\Services\WineBus\Devices\054c/0ce6]"# + "\r\n\"Hidraw\"=dword:00000000"))
        #expect(text.contains(#"[-HKEY_LOCAL_MACHINE\System\CurrentControlSet\Services\WineBus\Devices\28de/11ff]"#))
        #expect(text.contains("\"DisableHidraw\"=-"))
    }

    @Test("apply imports once, records what Silo owns, and runs nothing when there is nothing to change")
    func applies() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let prefix = try tmp.makeDir("bottle")
        try tmp.makeDir("bottle/drive_c")
        let fake = FakeProcessRunner()
        let wine = URL(fileURLWithPath: "/w/bin/wine64")
        let line = await SteamInputControllers.apply(environment: steamInputOn, flags: EnvFlags(), prefix: prefix,
                                                     wine: wine, runner: fake)
        #expect(line == "controllers: 6 kept off hidraw")
        let call = try #require(fake.lastInvocation)
        #expect(call.arguments == ["regedit", "/S", #"C:\silo-controllers.reg"#])
        #expect(call.environment["WINEPREFIX"] == prefix.path)
        #expect(call.environment["WINEDLLOVERRIDES"] == "winebus.sys=d")   // an idle bottle: the import opens no pad
        let owned = try String(contentsOf: prefix.appendingPathComponent(".silo-hidden-controllers"), encoding: .utf8)
        #expect(owned.contains("054c/0ce6\n"))
        #expect(!FileManager.default.fileExists(atPath: prefix.appendingPathComponent("drive_c/silo-controllers.reg").path))
        // The registry now has them (as Wine would have written): nothing to do.
        try tmp.write("bottle/system.reg", SteamInputControllers.plan(
            environment: steamInputOn, flags: EnvFlags(), owned: [], inRegistry: [], hidrawSet: false, hidrawMarker: false)
            .hide.map { "[System\\\\ControlSet001\\\\Services\\\\WineBus\\\\Devices\\\\\($0)] 1\n" }.joined())
        #expect(await SteamInputControllers.apply(environment: steamInputOn, flags: EnvFlags(), prefix: prefix,
                                                  wine: wine, runner: fake) == nil)
        #expect(fake.invocations.count == 1)
    }

    @Test("After an import, Silo waits for the bottle's Wine to stop — unless it was already running")
    func waitsForWineToStop() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let prefix = try tmp.makeDir("bottle")
        try tmp.makeDir("bottle/drive_c")
        let wine = URL(fileURLWithPath: "/w/bin/wine64")
        // Idle before, then live for three checks after the import (regedit's services), then stopped.
        let checks = Counter()
        _ = await SteamInputControllers.apply(environment: steamInputOn, flags: EnvFlags(), prefix: prefix, wine: wine,
                                              runner: FakeProcessRunner(),
                                              isLive: { _ in let n = checks.next(); return n >= 1 && n <= 3 },
                                              pollInterval: .milliseconds(1))
        #expect(checks.value == 5)
        // Already running something: one check, no waiting.
        try? FileManager.default.removeItem(at: prefix.appendingPathComponent(".silo-hidden-controllers"))
        let busy = Counter()
        _ = await SteamInputControllers.apply(environment: steamInputOn, flags: EnvFlags(), prefix: prefix, wine: wine,
                                              runner: FakeProcessRunner(),
                                              isLive: { _ in _ = busy.next(); return true },
                                              pollInterval: .milliseconds(1))
        #expect(busy.value == 1)
    }

    @Test("An import server still up at the limit is stopped, so the game never joins a server without winebus")
    func stopsALingeringImportServer() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let prefix = try tmp.makeDir("bottle")
        try tmp.makeDir("bottle/drive_c")
        let fake = FakeProcessRunner()
        let checks = Counter()
        let line = await SteamInputControllers.apply(
            environment: steamInputOn, flags: EnvFlags(), prefix: prefix, wine: URL(fileURLWithPath: "/w/bin/wine64"),
            runner: fake, isLive: { _ in checks.next() >= 1 }, waitLimit: .milliseconds(20),
            pollInterval: .milliseconds(1))
        #expect(line == "controllers: 6 kept off hidraw, the import's wineserver stopped")
        let kill = try #require(fake.lastInvocation)
        #expect(kill.executable.path == "/w/bin/wineserver" && kill.arguments == ["-k"])
        #expect(kill.environment["WINEPREFIX"] == prefix.path)
    }

    @Test("A bottle already running: the import keeps winebus (its server is the running one) and nothing is stopped")
    func busyBottleKeepsWinebus() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let prefix = try tmp.makeDir("bottle")
        try tmp.makeDir("bottle/drive_c")
        let fake = FakeProcessRunner()
        _ = await SteamInputControllers.apply(environment: steamInputOn, flags: EnvFlags(), prefix: prefix,
                                              wine: URL(fileURLWithPath: "/w/bin/wine64"), runner: fake,
                                              isLive: { _ in true }, pollInterval: .milliseconds(1))
        #expect(fake.invocations.count == 1)
        #expect(fake.lastInvocation?.environment["WINEDLLOVERRIDES"] == nil)
    }

    @Test("A failed import changes nothing on Silo's side")
    func failedImport() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let prefix = try tmp.makeDir("bottle")
        try tmp.makeDir("bottle/drive_c")
        let fake = FakeProcessRunner()
        fake.queueResult(ProcessResult(exitCode: 1))
        let line = await SteamInputControllers.apply(environment: steamInputOn, flags: EnvFlags(), prefix: prefix,
                                                     wine: URL(fileURLWithPath: "/w"), runner: fake)
        #expect(line == "controllers: registry import failed, left as they were")
        #expect(!FileManager.default.fileExists(atPath: prefix.appendingPathComponent(".silo-hidden-controllers").path))
    }
}

/// A thread-safe counter for the `isLive` stubs above. `@unchecked` is safe: every access holds the lock.
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    /// Returns the count before this call, then increments it.
    func next() -> Int { lock.withLock { defer { count += 1 }; return count } }
}
