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

    @Test("Steam Input on: its pads + Switch are hidden; raw controllers hides nothing and gives Silo's back")
    func plans() {
        let plan = SteamInputControllers.plan(environment: steamInputOn, flags: EnvFlags(), owned: [], inRegistry: [],
                                              hidrawSet: false, hidrawMarker: false)
        #expect(plan.hide == ["054c/05c4", "054c/0ce6", "057e/2006", "057e/2007", "057e/2009", "28de/11ff"])
        #expect(plan.unhide.isEmpty && plan.disableHidraw == nil && plan.owned == plan.hide)

        let raw = SteamInputControllers.plan(environment: steamInputOn, flags: EnvFlags(rawControllers: true),
                                             owned: ["054c/0ce6"], inRegistry: ["054c/0ce6"],
                                             hidrawSet: false, hidrawMarker: false)
        #expect(raw.hide.isEmpty && raw.unhide == ["054c/0ce6"] && raw.owned.isEmpty)
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
