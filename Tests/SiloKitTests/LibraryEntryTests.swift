import Foundation
import Testing
@testable import SiloKit

@Suite("LibraryEntry")
struct LibraryEntryTests {

    private func steam(_ appID: Int, _ name: String) -> SteamApp {
        SteamApp(appID: appID, name: name, installDir: name, stateFlags: StateFlags(rawValue: 4),
                 sizeOnDisk: 0, libraryPath: URL(fileURLWithPath: "/lib"))
    }

    private func manual(_ name: String) -> ManualGame {
        ManualGame(name: name, executablePath: URL(fileURLWithPath: "/g/\(name).exe"))
    }

    @Test("All merges both kinds into one alphabetical list")
    func allMergesAlphabetically() {
        let entries = LibraryEntry.merged(
            steam: [steam(1, "Devil May Cry 5"), steam(2, "TEKKEN 8")],
            manual: [manual("God of War"), manual("Batman Arkham Knight")],
            filter: .all)
        #expect(entries.map(\.name) == ["Batman Arkham Knight", "Devil May Cry 5", "God of War", "TEKKEN 8"])
    }

    @Test("The comparison ignores case")
    func caseInsensitive() {
        let entries = LibraryEntry.merged(steam: [steam(1, "UNCHARTED")], manual: [manual("batman")],
                                          filter: .all)
        #expect(entries.map(\.name) == ["batman", "UNCHARTED"])
    }

    @Test("Steam keeps only Steam games, Non-Steam only manual ones")
    func kindFilters() {
        let s = [steam(1, "B")], m = [manual("A")]
        #expect(LibraryEntry.merged(steam: s, manual: m, filter: .steam).map(\.id) == ["steam-1"])
        #expect(LibraryEntry.merged(steam: s, manual: m, filter: .nonSteam).map(\.id)
                == ["manual-\(m[0].id.uuidString)"])
    }

    @Test("Equal names keep a stable order")
    func stableTies() {
        let m = manual("Same")
        let first = LibraryEntry.merged(steam: [steam(7, "Same")], manual: [m], filter: .all)
        let again = LibraryEntry.merged(steam: [steam(7, "Same")], manual: [m], filter: .all)
        #expect(first.map(\.id) == again.map(\.id))
        #expect(first.count == 2)
    }

    @Test("Raw values are persisted — they must not change")
    func rawValues() {
        #expect(LibraryKindFilter.allCases.map(\.rawValue) == ["all", "steam", "nonSteam"])
    }
}
