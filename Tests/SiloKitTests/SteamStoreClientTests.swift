import Foundation
import Testing
@testable import SiloKit

@Suite("SteamStoreClient parsing")
struct SteamStoreClientTests {

    @Test("Parses description, developer, genres, art from the appdetails response")
    func parses() {
        let json = """
        {"220":{"success":true,"data":{
          "name":"Half-Life 2",
          "short_description":"1998. HL.",
          "developers":["Valve"],
          "publishers":["Valve"],
          "genres":[{"id":"1","description":"Action"},{"id":"25","description":"Adventure"}],
          "header_image":"https://cdn.example/220/header.jpg",
          "release_date":{"coming_soon":false,"date":"16 Nov, 2004"}
        }}}
        """
        let d = try! #require(SteamStoreClient.parse(Data(json.utf8), appID: 220))
        #expect(d.shortDescription == "1998. HL.")
        #expect(d.developers == ["Valve"])
        #expect(d.genres == ["Action", "Adventure"])
        #expect(d.headerImageURL?.absoluteString == "https://cdn.example/220/header.jpg")
        #expect(d.releaseDate == "16 Nov, 2004")
    }

    @Test("Returns nil when the app isn't found (success:false)")
    func notFound() {
        let json = #"{"999":{"success":false}}"#
        #expect(SteamStoreClient.parse(Data(json.utf8), appID: 999) == nil)
    }

    /// The shape Steam returns now (measured 2026-09-25): keyed by a DIFFERENT id than the one asked for,
    /// with the requested id only inside `data.steam_appid`. Before this, every detail sheet came up empty.
    @Test("parses a response keyed by a different id, matching on data.steam_appid")
    func parsesResponseKeyedByAnotherID() throws {
        let json = #"{"2083110":{"success":true,"data":{"steam_appid":1817070,"name":"Marvel’s Spider-Man Remastered","short_description":"Ciao","header_image":"https://cdn.example/seasonal.jpg"}}}"#
        let d = try #require(SteamStoreClient.parse(Data(json.utf8), appID: 1817070))
        #expect(d.shortDescription == "Ciao")
        #expect(d.headerImageURL?.absoluteString == "https://cdn.example/seasonal.jpg")
    }

    /// Matching is on the id that was asked for, never "whatever came back": a response about another game
    /// must not be shown as this one's.
    @Test("rejects an entry whose steam_appid is a different game")
    func rejectsAnotherGamesEntry() {
        let json = #"{"2083110":{"success":true,"data":{"steam_appid":999,"name":"Other"}}}"#
        #expect(SteamStoreClient.parse(Data(json.utf8), appID: 1817070) == nil)
    }
}
