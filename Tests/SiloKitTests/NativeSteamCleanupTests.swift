import Foundation
import Testing
@testable import SiloKit

struct NativeSteamCleanupTests {
    /// A library with `steamapps`, games `installed`, and a Silo-made compatdata for `compat`.
    private func library(_ tmp: TempDir, _ name: String, installed: [UInt32], compat: [UInt32]) throws -> URL {
        let root = tmp.url.appendingPathComponent(name)
        for id in installed { _ = try tmp.write("\(name)/steamapps/appmanifest_\(id).acf", "\"AppState\" {}") }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("steamapps"), withIntermediateDirectories: true)
        for id in compat {
            let user = root.appendingPathComponent("steamapps/compatdata/\(id)/pfx/drive_c/users/steamuser")
            try FileManager.default.createDirectory(at: user, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: user.appendingPathComponent("Saved Games"),
                                                       withDestinationURL: tmp.url.appendingPathComponent("bottle/Saved Games"))
            _ = try tmp.write("\(name)/steamapps/compatdata/\(id)/pfx/\(SteamCloudSaves.compatMarkerName)", "")
        }
        return root
    }

    @Test("An uninstalled game's app and Silo-made compatdata go; installed games and foreign prefixes stay")
    func leftovers() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let saves = try tmp.write("bottle/Saved Games/save.dat", "progress")
        let ssd = try library(tmp, "ssd", installed: [1778820], compat: [1778820, 391220])
        let main = try library(tmp, "main", installed: [], compat: [])
        let apps = tmp.url.appendingPathComponent("GameApps")
        for id in ["1778820", "391220", "notanid"] {
            try FileManager.default.createDirectory(at: apps.appendingPathComponent("\(id)/X.app"), withIntermediateDirectories: true)
        }
        // A real prefix of another tool, for a game no longer installed: not Silo's.
        _ = try tmp.write("ssd/steamapps/compatdata/555/pfx/system.reg", "WINE REGISTRY")
        let installed: Set<UInt32> = [1778820]

        let found = NativeSteamCleanup.leftovers(gameAppsDir: apps, libraries: [main, ssd], installed: installed)
        #expect(NativeSteamCleanup.appBundles(in: found, gameAppsDir: apps).map(\.lastPathComponent) == ["X.app"])
        #expect(NativeSteamCleanup.lsregisterArguments(unregistering: apps.appendingPathComponent("391220/X.app"))
                == ["-u", apps.appendingPathComponent("391220/X.app").path])
        #expect(found.map { $0.path.replacingOccurrences(of: tmp.url.path, with: "") }
                == ["/GameApps/391220", "/ssd/steamapps/compatdata/391220"])
        #expect(NativeSteamCleanup.remove(found).count == 2)
        #expect(!FileManager.default.fileExists(atPath: apps.appendingPathComponent("391220").path))
        #expect(FileManager.default.fileExists(atPath: apps.appendingPathComponent("1778820").path))
        #expect(FileManager.default.fileExists(atPath: ssd.appendingPathComponent("steamapps/compatdata/555/pfx/system.reg").path))
        #expect(try String(contentsOf: saves, encoding: .utf8) == "progress")   // the link went, never its target
    }

    @Test("Nothing is touched while a library is unreachable (an unplugged disk)")
    func missingLibrary() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let main = try library(tmp, "main", installed: [], compat: [])
        let apps = tmp.url.appendingPathComponent("GameApps")
        try FileManager.default.createDirectory(at: apps.appendingPathComponent("391220"), withIntermediateDirectories: true)
        let unplugged = URL(fileURLWithPath: "/Volumes/Not Here/SteamLibrary")
        #expect(NativeSteamCleanup.leftovers(gameAppsDir: apps, libraries: [main, unplugged], installed: []).isEmpty)
    }
}
