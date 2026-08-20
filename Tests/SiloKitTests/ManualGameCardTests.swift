import Foundation
import Testing
@testable import SiloKit

/// The Steam association a manual game can carry, so its tile opens a card instead of the settings sheet.
@Suite("Manual game card")
struct ManualGameCardTests {

    @Test("steamAppID round-trips, and a config written before cards decodes fine")
    func appIDRoundTrips() throws {
        let game = ManualGame(name: "Batman", executablePath: URL(fileURLWithPath: "/g/b.exe"),
                              steamAppID: 208650)
        let back = try JSONDecoder().decode(ManualGame.self, from: JSONEncoder().encode(game))
        #expect(back.steamAppID == 208650)

        // No steamAppID key at all — every entry that exists today.
        let json = #"{"id":"\#(UUID().uuidString)","bottleID":"\#(UUID().uuidString)","name":"X","executablePath":"file:///g/x.exe","envFlags":{},"graphics":"auto","customArgs":[]}"#
        let legacy = try JSONDecoder().decode(ManualGame.self, from: Data(json.utf8))
        #expect(legacy.steamAppID == nil)      // nil = no card, the behaviour that was always there
    }

    @Test("the association is independent of the cover — one can exist without the other")
    func associationAndCoverAreIndependent() throws {
        let withCard = ManualGame(name: "A", executablePath: URL(fileURLWithPath: "/a.exe"),
                                  steamAppID: 1, coverArtFileName: nil)
        let withCover = ManualGame(name: "B", executablePath: URL(fileURLWithPath: "/b.exe"),
                                   steamAppID: nil, coverArtFileName: "b.png")
        for game in [withCard, withCover] {
            let back = try JSONDecoder().decode(ManualGame.self, from: JSONEncoder().encode(game))
            #expect(back.steamAppID == game.steamAppID)
            #expect(back.coverArtFileName == game.coverArtFileName)
        }
    }
}
