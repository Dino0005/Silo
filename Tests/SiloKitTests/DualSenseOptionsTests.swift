import Foundation
import Testing
@testable import SiloKit

/// `DualSenseOptions`: the game's DualSense options for Silo's Wine, written before each Steam launch.
@Suite("DualSense options")
struct DualSenseOptionsTests {
    @Test("Every key is written, defaults too: a Bluetooth pad as wired, rumble on the motors, no XInput")
    func defaults() {
        #expect(DualSenseOptions.lines(for: EnvFlags()) == ["bluetooth=wired", "rumble=motors", "xinput=off"])
        var flags = EnvFlags()
        flags.dualSenseBluetoothAsWired = false
        flags.dualSenseRumbleOnActuators = true
        flags.dualSenseAsXInput = true
        #expect(DualSenseOptions.lines(for: flags) == ["bluetooth=off", "rumble=haptics", "xinput=pad"])
    }

    @Test("The game's file is replaced at each launch; pad.conf is written once and then left as it is")
    func write() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let folder = DualSenseOptions.folder(supportDir: tmp.url)
        #expect(folder.path.hasSuffix("/DualSense"))
        var flags = EnvFlags()
        flags.dualSenseRumbleOnActuators = true
        #expect(DualSenseOptions.write(flags, appID: 1_659_420, folder: folder)
                == "dualsense: bluetooth=wired, rumble=haptics, xinput=off")
        let game = try String(contentsOf: folder.appendingPathComponent("pad.d/1659420.conf"), encoding: .utf8)
        #expect(game.hasSuffix("bluetooth=wired\nrumble=haptics\nxinput=off\n"))
        #expect(game.hasPrefix("#") && !game.components(separatedBy: "\n")[0].contains("="))   // a comment, never a setting
        let every = folder.appendingPathComponent("pad.conf")
        #expect(try String(contentsOf: every, encoding: .utf8).hasSuffix("bluetooth=wired\n"))
        try Data("bluetooth=off\n".utf8).write(to: every)
        flags.dualSenseRumbleOnActuators = false
        DualSenseOptions.write(flags, appID: 1_659_420, folder: folder)
        #expect(try String(contentsOf: every, encoding: .utf8) == "bluetooth=off\n")   // the user's own stays
        #expect(try String(contentsOf: folder.appendingPathComponent("pad.d/1659420.conf"), encoding: .utf8)
                    .contains("rumble=motors"))
    }

    @Test("Old configs read the DualSense options as their defaults, and the Compatibility page carries them")
    func decodingAndPage() throws {
        let old = try JSONDecoder().decode(EnvFlags.self, from: Data(#"{"syncMode":"msync"}"#.utf8))
        #expect(old.dualSenseBluetoothAsWired && !old.dualSenseRumbleOnActuators && !old.dualSenseAsXInput)
        var config = GameConfig(appID: 1_778_820)
        #expect(SteamGameSettings.set(.dualSenseAsXInput, to: "1", in: &config))
        #expect(config.envFlags.dualSenseAsXInput)
        #expect(SteamGameSettings.value(.dualSenseBluetoothAsWired, of: config) == "1")
    }
}
