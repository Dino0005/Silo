import Foundation
import Testing
@testable import SiloKit

/// `LaunchLeftovers` — what a bottle still has alive after a game, and what it is safe to offer to close.
/// The process lists below are verbatim from the on-device measurements of 2026-09-24 (a Spider-Man
/// session in the shared Steam bottle), so the classifier is tested against real command lines.
struct LaunchLeftoversTests {
    private let spiderMan = "/Volumes/Extreme Pro/CX Steam Library/SteamLibrary/steamapps/common/Marvel's Spider-Man Remastered/Spider-Man.exe"

    /// A bottle mid-session: Steam up, a game playing, plumbing running.
    private var liveSession: [LaunchLeftovers.Process] {
        [
            .init(id: 49206, command: #"C:\windows\system32\services.exe"#),
            .init(id: 49215, command: #"C:\windows\system32\winedevice.exe"#),
            .init(id: 49237, command: #"C:\windows\system32\plugplay.exe"#),
            .init(id: 49239, command: #"C:\windows\system32\svchost.exe -k LocalServiceNetworkRestricted"#),
            .init(id: 49243, command: #"C:\windows\system32\explorer.exe /desktop=Silo,3456x2234 C:\Steam\steam.exe"#),
            .init(id: 49246, command: #"/Users/x/Silo/SteamBottle/drive_c/Program Files (x86)/Steam/steam.exe -cef-disable-gpu"#),
            .init(id: 49283, command: #"C:\Program Files (x86)\Steam\bin\cef\cef.win64\steamwebhelper.exe -nocrashdialog"#),
            .init(id: 49712, command: "/Users/x/Silo/HostApps/1817070/Marvel’s Spider-Man Remastered.app/Contents/MacOS/SiloGameHost"),
            .init(id: 49716, command: spiderMan),
            .init(id: 49718, command: #"C:\windows\system32\explorer.exe /desktop"#),
        ]
    }

    /// The state after quitting the game: the desktop owner is still there, the game is not.
    private var afterQuitting: [LaunchLeftovers.Process] {
        liveSession.filter { $0.id != 49712 && $0.id != 49716 }
    }

    private let inPrefix: Set<Int32> = [49206, 49215, 49237, 49239, 49243, 49246, 49283, 49712, 49716, 49718]

    // MARK: - Classification

    /// While the game is playing there is nothing to offer: acting here would kill a running game.
    @Test func aPlayingGameIsNeverALeftover() {
        let census = LaunchLeftovers.classify(
            all: liveSession, inPrefix: inPrefix, gameExecutables: [spiderMan])
        // 49712 is the adopted host — the game itself. Its command line is the host binary, which is
        // precisely why it must be recognised by that and not by the game's exe path.
        #expect(census.games.map(\.id).sorted() == [49712, 49716])
        #expect(!census.isOnlyLeftovers)
        // The desktop owner IS a leftover even now — it just isn't actionable while a game runs.
        #expect(census.leftovers.map(\.id) == [49718])
    }

    /// The case the user hits: game gone, tile still in the Dock, Steam still running and to be kept.
    @Test func afterTheGameOnlyTheDesktopOwnerRemains() {
        let census = LaunchLeftovers.classify(
            all: afterQuitting, inPrefix: inPrefix, gameExecutables: [spiderMan])
        #expect(census.games.isEmpty)
        #expect(census.leftovers.map(\.id) == [49718])
        #expect(census.isOnlyLeftovers)
    }

    /// Steam and its tree must never appear — the whole point is "clear the remains, keep Steam". The
    /// client's virtual desktop shares the `explorer.exe` image name with the leftover, so the match has
    /// to be on `/desktop=`, not on the name.
    @Test func theSteamClientAndItsDesktopAreNeverTouched() {
        let census = LaunchLeftovers.classify(
            all: afterQuitting, inPrefix: inPrefix, gameExecutables: [spiderMan])
        let ids = Set(census.leftovers.map(\.id) + census.games.map(\.id))
        #expect(!ids.contains(49246))    // steam.exe
        #expect(!ids.contains(49283))    // steamwebhelper.exe
        #expect(!ids.contains(49243))    // the client's /desktop=Silo explorer
    }

    /// Wine's own plumbing belongs to the bottle, not to a launch: stopping it is what *Stop all bottle
    /// processes* is for, and pulling it out from under a live prefix is how a bottle gets hurt.
    @Test func theBottlesPlumbingIsNotALeftover() {
        let census = LaunchLeftovers.classify(
            all: afterQuitting, inPrefix: inPrefix, gameExecutables: [])
        let ids = Set(census.leftovers.map(\.id))
        #expect(ids.isDisjoint(with: [49206, 49215, 49237, 49239]))
    }

    /// A process of ANOTHER bottle must not be swept in with this one: attribution is the wineserver
    /// directory, and nothing else.
    @Test func processesOutsideThePrefixAreIgnored() {
        let foreign = LaunchLeftovers.Process(id: 99999, command: #"C:\windows\system32\explorer.exe /desktop"#)
        let census = LaunchLeftovers.classify(
            all: afterQuitting + [foreign], inPrefix: inPrefix, gameExecutables: [spiderMan])
        #expect(!census.leftovers.contains(foreign))
    }

    /// A game's own helper (Sony's crash handler here) is a leftover: it is what held the tile for the
    /// two seconds measured on a warm bottle.
    @Test func aGamesOwnHelperCountsAsALeftover() {
        let helper = LaunchLeftovers.Process(
            id: 49751, command: #"Y:\SteamLibrary\steamapps\common\Marvel's Spider-Man Remastered\crs-handler.exe"#)
        let census = LaunchLeftovers.classify(
            all: afterQuitting + [helper], inPrefix: inPrefix.union([49751]),
            gameExecutables: [spiderMan])
        #expect(census.leftovers.map(\.id).sorted() == [49718, 49751])
    }

    /// Even with NO game list at all, an adopted game is still recognised — the host binary in its
    /// command line is the tell. That is the safety net that matters: a caller that forgets to pass its
    /// library can still never be told to kill a playing game.
    @Test func anAdoptedGameIsRecognisedWithoutAnyGameList() {
        let census = LaunchLeftovers.classify(
            all: liveSession, inPrefix: inPrefix, gameExecutables: [])
        #expect(census.games.map(\.id) == [49712])
        #expect(!census.isOnlyLeftovers)
        // A non-adopted auxiliary process of the game is only known from the library, so without it 49716
        // does read as a leftover — which is why the caller passes its executables.
        #expect(census.leftovers.map(\.id).sorted() == [49716, 49718])
    }

    // MARK: - Parsing

    @Test func parsesPSLinesAndSkipsTheHeader() {
        let output = """
              PID COMMAND
             1234 C:\\windows\\system32\\explorer.exe /desktop
            49246 /Users/x/Steam/steam.exe -cef-disable-gpu
            """
        let parsed = LaunchLeftovers.parsePS(output)
        #expect(parsed.map(\.id) == [1234, 49246])
        #expect(parsed[0].command == #"C:\windows\system32\explorer.exe /desktop"#)
    }

    @Test func parsesLsofPIDList() {
        #expect(LaunchLeftovers.parsePIDs("49206\n49718\n\n") == [49206, 49718])
        #expect(LaunchLeftovers.parsePIDs("").isEmpty)
    }

    // MARK: - The probe degrades

    /// A prefix with no live wineserver has no directory to attribute processes by, so the census must be
    /// empty — offering a cleanup there would be offering to kill unrelated processes.
    @Test func aDeadPrefixYieldsAnEmptyCensus() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let runner = FakeProcessRunner()
        let census = await LaunchLeftovers(runner: runner).census(
            prefix: tmp.url.appendingPathComponent("never-booted"), gameExecutables: [])
        #expect(census.leftovers.isEmpty)
        #expect(runner.invocations.isEmpty)      // not even asked
    }
}

/// The aggregation `AppEnvironment` does over the bottles: which censuses may be offered for cleanup.
struct LeftoverAggregationTests {
    private func census(games: [Int32], leftovers: [Int32]) -> LaunchLeftovers.Census {
        .init(games: games.map { .init(id: $0, command: "game") },
              leftovers: leftovers.map { .init(id: $0, command: "leftover") })
    }

    /// A bottle where someone is playing has leftovers too (the desktop owner), but it must NOT be
    /// offered: the action would then sit one click away from a running game.
    @Test func aBottleWithAGameRunningContributesNothing() {
        #expect(AppEnvironment.leftoverCount(from: [census(games: [1], leftovers: [2, 3])]) == 0)
    }

    @Test func onlyBottlesWithNoGameRunningAreCounted() {
        let counted = AppEnvironment.leftoverCount(from: [
            census(games: [], leftovers: [10, 11]),      // a finished launch → offered
            census(games: [20], leftovers: [21]),        // playing → not offered
            census(games: [], leftovers: []),            // clean
        ])
        #expect(counted == 2)
    }

    /// Nothing alive means nothing to offer — the menu entry stays hidden.
    @Test func anEmptyMachineOffersNothing() {
        #expect(AppEnvironment.leftoverCount(from: []) == 0)
        #expect(AppEnvironment.leftoverCount(from: [census(games: [], leftovers: [])]) == 0)
    }
}
