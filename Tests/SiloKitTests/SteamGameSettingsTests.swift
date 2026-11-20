import Foundation
import Testing
@testable import SiloKit

struct SteamGameSettingsTests {
    @Test("The page gets every saved game's values, with the backend Automatic learned only when it still applies")
    func snapshot() throws {
        var state = AppState()
        state.backend.gptkRuntimeName = "GPTK-4"
        var tekken = state.config(for: 1778820); tekken.graphics = .dxmt
        var gow = state.config(for: 1593500); gow.learnedBackend = .dxmt; gow.learnedUnderRuntime = "GPTK-4"
        var old = state.config(for: 7); old.learnedBackend = .dxmt; old.learnedUnderRuntime = "GPTK-3"
        state.upsert(tekken); state.upsert(gow); state.upsert(old)
        let js = SteamGameSettings.snapshotScript(state: state, mediaFoundation: true)
        #expect(js.contains(#""1778820":{"advertiseAVX":"#))
        #expect(js.contains(#""graphics":"dxmt","learned":"","mediaFoundationNative":"0","metalBackend":"auto""#))
        #expect(js.contains(#""graphics":"auto","learned":"DXMT""#))
        #expect(js.contains(#""mediaFoundation":true"#))
        #expect(js.contains(#""defaults":{"#))
        #expect(js.hasPrefix("String(!!(window.__siloCompat && window.__siloCompat.setSettings"))
    }

    @Test("Changes from the page: read, applied to their own game, invalid ones skipped")
    func changes() throws {
        let reply = #"[{"appid":391220,"key":"graphics","value":"dxmt"},{"appid":391220,"key":"graphics","value":"bogus"},{"appid":391220,"key":"nope","value":"1"},{"appid":5,"key":"graphics","value":"gptk"}]"#
        let all = SteamGameSettings.changes(fromReply: reply)
        #expect(all.count == 4)
        #expect(SteamGameSettings.changes(fromReply: "not json").isEmpty)
        var config = AppState().config(for: 391220)
        let lines = SteamGameSettings.apply(all, to: &config)
        #expect(lines == ["settings 391220: graphics = dxmt"])
        #expect(config.graphics == .dxmt)
        // Every field round-trips through the page's text values.
        var edited = AppState().config(for: 1)
        let flips: [SteamGameSettings.Change] = [
            .init(appid: 1, key: "syncMode", value: "esync"), .init(appid: 1, key: "advertiseAVX", value: "0"),
            .init(appid: 1, key: "metalHUD", value: "1"), .init(appid: 1, key: "metalFX", value: "1"),
            .init(appid: 1, key: "dxr", value: "1"), .init(appid: 1, key: "metalBackend", value: "metal3"),
            .init(appid: 1, key: "depthFix", value: "1"), .init(appid: 1, key: "disableHidraw", value: "1"),
            .init(appid: 1, key: "mediaFoundationNative", value: "1"), .init(appid: 1, key: "dxr", value: "yes"),
        ]
        #expect(SteamGameSettings.apply(flips, to: &edited).count == 9)   // "yes" isn't a bit
        let f = edited.envFlags
        #expect(f.syncMode == .esync && !f.advertiseAVX && f.metalHUD && f.metalFX && f.dxr && f.metalBackend == .metal3)
        #expect(f.depthFix && f.disableHidraw && f.mediaFoundationNative)
        for field in SteamGameSettings.Field.allCases {
            #expect(SteamGameSettings.set(field, to: SteamGameSettings.value(field, of: edited), in: &edited))
        }
    }

    @Test("The page script knows Silo's tool and carries the Silo section")
    func pageScript() {
        let js = SteamCompatibilityPage.script(tools: [(name: SiloCompatTool.name, display: "Silo")], windowsOnly: [], windowsBuild: [])
        #expect(js.contains("S.siloTool = '\(SiloCompatTool.name)';"))
        for needle in ["S.setSettings = ", "S.takeChanges = ", "S.changes.push({ appid, key, value })", "picker('metalBackend'", "toggle('mediaFoundationNative'", "data-silo-settings"] {
            #expect(js.contains(needle), "\(needle)")
        }
    }
}
