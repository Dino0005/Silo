import AppKit
import Foundation
import Testing
@testable import SiloKit

/// Runs `PEIcon` against a real Windows executable — the thing the unit tests can't fake, because the
/// question is precisely whether the parser copes with what real games ship.
///
/// Skipped unless `SILO_TEST_EXE` names a file, so a checkout without the game (or without the drive
/// mounted) still runs green. Point it at a game's `.exe`:
///
///     SILO_TEST_EXE="/…/BatmanAK.exe" swift test --filter PEIconReal
@Suite("PEIcon against a real executable")
struct PEIconRealExeTests {

    private var exe: URL? {
        guard let p = ProcessInfo.processInfo.environment["SILO_TEST_EXE"], !p.isEmpty,
              FileManager.default.fileExists(atPath: p) else { return nil }
        return URL(fileURLWithPath: p)
    }

    @Test("the executable's icon comes out, and AppKit can read it")
    func extractsFromRealExecutable() throws {
        guard let exe else {
            print("SILO_TEST_EXE non impostata o file assente — test saltato")
            return
        }
        let data = try Data(contentsOf: exe, options: .mappedIfSafe)
        print("file: \(data.count) byte — \(exe.lastPathComponent)")

        let ico = PEIcon.icoData(fromExecutable: data)
        print("icoData: \(ico.map { "\($0.count) byte" } ?? "nil")")
        let bytes = try #require(ico, "PEIcon non ha estratto nulla: il difetto è nel parser")

        // The wrapper must be a real ICO: reserved 0, type 1, one image.
        #expect(bytes.count > 22)
        #expect([UInt8](bytes.prefix(6)) == [0, 0, 1, 0, 1, 0])

        // And AppKit has to be able to turn it into an icon — the step the shortcut and the tile need.
        let image = NSImage(data: bytes)
        print("NSImage: \(image.map { "\(Int($0.size.width))x\(Int($0.size.height))" } ?? "nil")")
        let loaded = try #require(image, "l'ICO è stato costruito ma AppKit non lo legge")
        #expect(loaded.size.width >= 32)
    }
}
