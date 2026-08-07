import Foundation
import Testing
@testable import SiloKit

/// Provisioning state that used to be recorded as a bare "it happened" flag, and so could never notice it
/// was wrong: a half-booted prefix that read as booted, and an override set that could never be updated.
@Suite("Setup integrity")
struct SetupIntegrityTests {

    // MARK: - wine-defaults is versioned by its content

    @Test("the stamp is stable across calls (NOT String.hashValue, which is seeded per process)")
    func stampIsStable() {
        #expect(SteamBottle.wineDefaultsStamp == SteamBottle.wineDefaultsStamp)
        // "<count>:<64 hex>" — a per-process random hash would neither be reproducible nor this shape.
        let parts = SteamBottle.wineDefaultsStamp.split(separator: ":")
        #expect(parts.count == 2)
        #expect(parts[1].count == 64)
        #expect(Int(parts[0]) == Silo.defaultDllOverrides.count)
    }

    @Test("a LEGACY empty marker reads as not-applied, so a shipped override change reaches old bottles")
    func legacyMarkerIsNotAccepted() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let paths = AppPaths(supportDir: tmp.url.appendingPathComponent("Silo"))
        let bottle = SteamBottle(runner: FakeProcessRunner(), paths: paths)
        let markers = paths.steamBottle.appendingPathComponent(".silo-installed")
        try FileManager.default.createDirectory(at: markers, withIntermediateDirectories: true)
        let marker = markers.appendingPathComponent("wine-defaults")

        // What every already-set-up bottle has on disk today: an empty file.
        FileManager.default.createFile(atPath: marker.path, contents: Data())
        #expect(!bottle.hasWineDefaults)

        // A stamp from an older, different override set is likewise refused.
        try "3:0000".write(to: marker, atomically: true, encoding: .utf8)
        #expect(!bottle.hasWineDefaults)

        try SteamBottle.wineDefaultsStamp.write(to: marker, atomically: true, encoding: .utf8)
        #expect(bottle.hasWineDefaults)
    }

    // MARK: - an interrupted wineboot is retried

    @Test("the drive_c + system.reg SKELETON alone no longer counts as booted")
    func skeletonIsNotBooted() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let prefix = tmp.url.appendingPathComponent("Bottle")
        let provisioner = WinePrefixProvisioner(runner: FakeProcessRunner())
        let layout = PrefixLayout(prefix: prefix)

        // Exactly what wineboot leaves behind seconds in — quitting here used to mark the prefix
        // provisioned FOREVER, and every later Set up built on a half-booted prefix.
        try FileManager.default.createDirectory(at: layout.driveC, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: layout.systemReg.path, contents: Data())
        #expect(!provisioner.isProvisioned(prefix))

        // The marker is the authority once wineboot has actually returned.
        let marker = WinePrefixProvisioner.bootMarker(prefix)
        try FileManager.default.createDirectory(
            at: marker.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: marker.path, contents: Data())
        #expect(provisioner.isProvisioned(prefix))
    }

    @Test("a LEGACY prefix (populated system32, no marker) is still recognised, not re-booted")
    func legacyPrefixIsRecognised() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let prefix = tmp.url.appendingPathComponent("Bottle")
        let provisioner = WinePrefixProvisioner(runner: FakeProcessRunner())
        let layout = PrefixLayout(prefix: prefix)
        let system32 = layout.driveC.appendingPathComponent("windows/system32")
        try FileManager.default.createDirectory(at: system32, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: layout.systemReg.path, contents: Data())
        for i in 0..<60 {
            FileManager.default.createFile(
                atPath: system32.appendingPathComponent("dll\(i).dll").path, contents: Data())
        }
        #expect(provisioner.isProvisioned(prefix))
    }

    @Test("provision writes the boot marker, and a re-run is a no-op")
    func provisionWritesMarker() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let fake = FakeProcessRunner()
        let prefix = tmp.url.appendingPathComponent("Bottle")
        let provisioner = WinePrefixProvisioner(runner: fake)
        fake.onRun = { inv in
            guard inv.arguments == ["wineboot", "--init"] else { return }
            let layout = PrefixLayout(prefix: prefix)
            try? FileManager.default.createDirectory(at: layout.driveC, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: layout.systemReg.path, contents: Data())
        }

        try await provisioner.provision(prefix: prefix, wine: URL(fileURLWithPath: "/w/wine64"))
        #expect(FileManager.default.fileExists(atPath: WinePrefixProvisioner.bootMarker(prefix).path))

        // The skeleton the fake wrote would NOT satisfy the legacy fallback (system32 is empty), so a
        // second no-op here proves the marker — not the skeleton — is what's being read.
        try await provisioner.provision(prefix: prefix, wine: URL(fileURLWithPath: "/w/wine64"))
        #expect(fake.invocations.filter { $0.arguments == ["wineboot", "--init"] }.count == 1)
    }
}
