import Foundation
import Testing
@testable import SiloKit

/// `LaunchLeftovers.census` against a REAL bottle — the part the unit tests can't fake, because the
/// question is whether `lsof`/`ps` on this machine attribute Wine's processes to the prefix at all.
///
/// Skipped unless `SILO_TEST_PREFIX` names a prefix directory:
///
///     SILO_TEST_PREFIX="$HOME/Library/Application Support/Silo/SteamBottle" Scripts/test.sh --filter LaunchLeftoversReal
@Suite("LaunchLeftovers against a real bottle")
struct LaunchLeftoversRealTests {
    @Test("census of a live prefix, printed")
    func censusOfARealPrefix() async throws {
        guard let path = ProcessInfo.processInfo.environment["SILO_TEST_PREFIX"], !path.isEmpty else {
            print("SILO_TEST_PREFIX non impostata — test saltato")
            return
        }
        let prefix = URL(fileURLWithPath: path, isDirectory: true)
        print("server dir: \(WineServerProbe.serverDirectory(for: prefix)?.path ?? "NESSUNA")")
        let census = await LaunchLeftovers(runner: SystemProcessRunner()).census(prefix: prefix, gameExecutables: [])
        print("giochi: \(census.games.map { "\($0.id) \($0.command.prefix(60))" })")
        print("relitti: \(census.leftovers.map { "\($0.id) \($0.command.prefix(60))" })")
        print("isOnlyLeftovers: \(census.isOnlyLeftovers)")
    }
}
