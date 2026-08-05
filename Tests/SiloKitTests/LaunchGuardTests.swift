import Foundation
import Testing
@testable import SiloKit

@MainActor
@Suite("Launch guards")
struct LaunchGuardTests {

    /// A config written by a NEWER Silo (an unknown backend/sync value) must degrade, never throw — a throw
    /// propagates out of AppState and ConfigStore returns a FRESH one, wiping every runtime path, per-game
    /// setting and manual game, with the next save overwriting the file. This fork is exposed for real: a
    /// config touched by upstream Silo can carry a `dxvk` backend it has never heard of.
    /// (From upstream bacb7a1/9a7b4d2, minus the metalBackend field this fork doesn't carry.)
    @Test("an unknown enum value in config.json degrades instead of wiping the document")
    func unknownEnumValuesDoNotWipeConfig() throws {
        let json = """
        {"appID":220,"graphics":"dxvk","learnedBackend":"dxvk",
         "envFlags":{"syncMode":"future_sync"}}
        """
        let cfg = try JSONDecoder().decode(GameConfig.self, from: Data(json.utf8))
        #expect(cfg.appID == 220)                 // the document survived
        #expect(cfg.graphics == .auto)            // unknown choice → Automatic
        #expect(cfg.learnedBackend == nil)        // unknown hint → dropped
        #expect(cfg.envFlags.syncMode == .msync)  // unknown sync → the safe default
    }
}
