import Foundation
import Testing
@testable import SiloKit

/// The MF recipe writes into the PREFIX, and a Wine change regenerates the prefix's fakedlls over the top
/// of it — so a bottle can look installed while the videos it exists for are black again. These cover the
/// stamp that makes that detectable, and the tolerance that stops it crying wolf.
@Suite("Media Foundation staleness")
struct MediaFoundationStaleTests {

    private let fm = FileManager.default

    private func stamp(_ prefix: URL, _ contents: String) throws {
        try fm.createDirectory(at: prefix, withIntermediateDirectories: true)
        try contents.write(to: MediaFoundationInstaller.marker(inPrefix: prefix),
                           atomically: true, encoding: .utf8)
    }

    @Test("a bottle built under a DIFFERENT runtime reads as stale")
    func differentRuntimeIsStale() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let prefix = tmp.url.appendingPathComponent("SteamBottleMF")
        try stamp(prefix, "wine-crossover-26.3")

        #expect(MediaFoundationInstaller.builtRuntimeName(inPrefix: prefix) == "wine-crossover-26.3")
        #expect(MediaFoundationInstaller.isStale(inPrefix: prefix, currentRuntime: "wine-cx-26.3.0"))
        #expect(!MediaFoundationInstaller.isStale(inPrefix: prefix, currentRuntime: "wine-crossover-26.3"))
    }

    @Test("a LEGACY empty marker is unknown, NOT stale — no false alarm on a working bottle")
    func legacyMarkerIsNotStale() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let prefix = tmp.url.appendingPathComponent("SteamBottleMF")
        try stamp(prefix, "")

        #expect(MediaFoundationInstaller.isInstalled(inPrefix: prefix))   // still counts as installed
        #expect(MediaFoundationInstaller.builtRuntimeName(inPrefix: prefix) == nil)
        #expect(!MediaFoundationInstaller.isStale(inPrefix: prefix, currentRuntime: "wine-cx-26.3.0"))
    }

    @Test("no configured runtime, or no bottle at all, is never stale")
    func unknownsAreNeverStale() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let prefix = tmp.url.appendingPathComponent("SteamBottleMF")
        try stamp(prefix, "wine-crossover-26.3")

        #expect(!MediaFoundationInstaller.isStale(inPrefix: prefix, currentRuntime: nil))
        // A prefix with no marker isn't installed, so there's nothing to be stale about.
        let empty = tmp.url.appendingPathComponent("NoBottle")
        #expect(!MediaFoundationInstaller.isStale(inPrefix: empty, currentRuntime: "wine-crossover-26.3"))
    }

    @Test("whitespace around the stamped name doesn't create a false mismatch")
    func stampIsTrimmed() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let prefix = tmp.url.appendingPathComponent("SteamBottleMF")
        try stamp(prefix, "  wine-crossover-26.3\n")
        #expect(!MediaFoundationInstaller.isStale(inPrefix: prefix, currentRuntime: "wine-crossover-26.3"))
    }
}
