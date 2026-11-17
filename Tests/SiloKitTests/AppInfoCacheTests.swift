import CryptoKit
import Foundation
import Testing
@testable import SiloKit

/// Fixtures shaped like the entries measured in a real macOS Steam `appinfo.vdf` on 2026-11-08.
enum AppInfoFixtures {
    static func header(changeNumber: UInt32 = 346) -> Data {
        var h = Data(count: 60)
        h.writeUInt32(2, at: 0)
        h.writeUInt32(changeNumber, at: 36)
        return h
    }

    static func launch(_ exe: String, os: String?) -> BinaryKV {
        var entry: [BinaryKVEntry] = [BinaryKVEntry("executable", .string(exe)), BinaryKVEntry("type", .string("default"))]
        if let os { entry.append(BinaryKVEntry("config", .map([BinaryKVEntry("oslist", .string(os))]))) }
        return .map(entry)
    }

    static func depot(_ os: String?) -> BinaryKV {
        guard let os else { return .map([BinaryKVEntry("maxsize", .string("1"))]) }
        return .map([BinaryKVEntry("config", .map([BinaryKVEntry("oslist", .string(os))]))])
    }

    /// TEKKEN 8 (1778820): Windows-only, one pinned launch entry, a Windows cloud rule.
    static var tekken: AppInfoCache.App {
        AppInfoCache.App(appID: 1_778_820, header: header(), root: [BinaryKVEntry("appinfo", .map([
            BinaryKVEntry("appid", .int32(1_778_820)),
            BinaryKVEntry("common", .map([
                BinaryKVEntry("name", .string("TEKKEN 8")),
                BinaryKVEntry("type", .string("Game")),
                BinaryKVEntry("oslist", .string("windows")),
            ])),
            BinaryKVEntry("config", .map([
                BinaryKVEntry("installdir", .string("TEKKEN 8")),
                BinaryKVEntry("launch", .map([BinaryKVEntry("0", launch("TEKKEN 8.exe", os: "windows"))])),
            ])),
            BinaryKVEntry("depots", .map([
                BinaryKVEntry("228989", depot("windows")),
                BinaryKVEntry("1778821", depot(nil)),
                BinaryKVEntry("branches", .map([BinaryKVEntry("public", .map([BinaryKVEntry("buildid", .string("1"))]))])),
            ])),
            BinaryKVEntry("ufs", .map([
                BinaryKVEntry("quota", .string("500000000")),
                BinaryKVEntry("savefiles", .map([BinaryKVEntry("0", .map([
                    BinaryKVEntry("root", .string("WinAppDataLocal")),
                    BinaryKVEntry("path", .string("TEKKEN 8/Saved/SaveGames/{64BitSteamID}")),
                    BinaryKVEntry("pattern", .string("*.sav")),
                    BinaryKVEntry("platforms", .map([BinaryKVEntry("1", .string("Windows"))])),
                ]))])),
            ])),
        ]))])
    }

    /// The Last of Us Part II (2531310): launch entries with NO oslist, the first one a launcher.
    static var tlou: AppInfoCache.App {
        AppInfoCache.App(appID: 2_531_310, header: header(), root: [BinaryKVEntry("appinfo", .map([
            BinaryKVEntry("common", .map([BinaryKVEntry("oslist", .string("windows"))])),
            BinaryKVEntry("config", .map([BinaryKVEntry("launch", .map([
                BinaryKVEntry("0", launch("launcher.exe", os: nil)),
                BinaryKVEntry("1", launch("tlou-ii.exe", os: nil)),
            ]))])),
            BinaryKVEntry("depots", .map([BinaryKVEntry("2531311", depot("windows"))])),
        ]))])
    }

    /// A game with both a native macOS build and a Windows one (Tomb Raider-like).
    static var dualBuild: AppInfoCache.App {
        AppInfoCache.App(appID: 203_160, header: header(), root: [BinaryKVEntry("appinfo", .map([
            BinaryKVEntry("common", .map([BinaryKVEntry("oslist", .string("windows,macos"))])),
            BinaryKVEntry("config", .map([BinaryKVEntry("launch", .map([
                BinaryKVEntry("0", launch("TombRaider.exe", os: "windows")),
                BinaryKVEntry("1", launch("Tomb Raider.app", os: "macos")),
            ]))])),
            BinaryKVEntry("depots", .map([
                BinaryKVEntry("203161", depot("windows")),
                BinaryKVEntry("203162", depot("macos")),
            ])),
        ]))])
    }

    static func cacheData(_ apps: [AppInfoCache.App], magic: UInt32 = AppInfoCache.magicV29) -> Data {
        AppInfoCache.encode(magic: magic, apps: apps)
    }
}

@Suite("AppInfoCache (binary appinfo.vdf)")
struct AppInfoCacheTests {
    @Test("v29 and v28 caches read back exactly what was written", arguments: [AppInfoCache.magicV29, AppInfoCache.magicV28])
    func roundTrip(magic: UInt32) throws {
        let apps = [AppInfoFixtures.tekken, AppInfoFixtures.tlou]
        let cache = try AppInfoCache(data: AppInfoFixtures.cacheData(apps, magic: magic))
        #expect(cache.magic == magic)
        #expect(cache.appIDs == [1_778_820, 2_531_310])
        let tekken = try #require(try cache.app(1_778_820))
        #expect(tekken.root == AppInfoFixtures.tekken.root)
        #expect(tekken.changeNumber == 346)
        #expect(try cache.app(42) == nil)
    }

    @Test("Replacing one app copies every other entry byte for byte and refreshes the blob SHA-1")
    func surgicalReplace() throws {
        let original = AppInfoFixtures.cacheData([AppInfoFixtures.tekken, AppInfoFixtures.tlou])
        let cache = try AppInfoCache(data: original)
        var tekken = try #require(try cache.app(1_778_820))
        tekken.info.editMap("common") { $0.setString("brandNewKey", "x") }
        let rewritten = try cache.replacing(tekken)

        let after = try AppInfoCache(data: rewritten)
        #expect(try after.app(1_778_820)?.info.map("common")?.string("brandNewKey") == "x")
        // The untouched app keeps its tree (and, with the string table only appended to, its key indexes).
        #expect(try after.app(2_531_310)?.root == AppInfoFixtures.tlou.root)
        // The header's second SHA-1 must match the new blob, or Steam throws the entry away.
        let header = try #require(try after.app(1_778_820)?.header)
        let blobStart = rewritten.range(of: header)!.upperBound
        let entrySize = Int(rewritten.readUInt32(at: blobStart - 60 - 4))
        let blob = rewritten.subdata(in: blobStart..<(blobStart + entrySize - 60))
        #expect(header.subdata(in: 40..<60) == Data(Insecure.SHA1.hash(data: blob)))
    }

    @Test("A file that isn't an appinfo cache is refused, not misread")
    func rejectsGarbage() {
        #expect(throws: AppInfoCache.Failure.unsupportedMagic(0x1234_5678)) {
            var d = Data(); d.appendUInt32(0x1234_5678); d.appendUInt32(1)
            return try AppInfoCache(data: d)
        }
        #expect(throws: (any Error).self) { try AppInfoCache(data: Data([0x29, 0x44])) }
    }
}

@Suite("AppInfoPatcher")
struct AppInfoPatcherTests {
    let shim = "../Silo Runtime/silo-launch"

    @Test("A Windows-only game gets a macOS launch entry through the shim, like the TEKKEN 8 test")
    func windowsOnly() throws {
        var app = AppInfoFixtures.tekken
        let result = AppInfoPatcher.enableSiloLaunch(&app, shim: shim)
        #expect(result.changed)
        let info = app.info
        #expect(info.map("common")?.string("oslist") == "windows,macos")
        #expect(info.map("common")?.string("osarch") == "64")
        #expect(info.map("depots")?.map("228989")?.map("config")?.string("oslist") == "windows,macos")
        #expect(info.map("depots")?.map("1778821")?.map("config") == nil)   // no-OS depots stay as they are
        let launches = try #require(info.map("config")?.map("launch"))
        #expect(launches.map("0")?.map("config")?.string("oslist") == "windows")
        let ours = try #require(launches.map(AppInfoPatcher.entryKey))
        #expect(ours.string("executable") == shim)
        #expect(ours.string("arguments") == "--appid 1778820 --exe \"TEKKEN 8.exe\"")
        #expect(ours.map("config")?.string("oslist") == "macos")
        #expect(ours.map("config")?.string("osarch") == "64")
    }

    @Test("Entries without an oslist are pinned to Windows; a launcher still names the exe Steam lists first")
    func pinsAnyPlatformEntries() throws {
        var app = AppInfoFixtures.tlou
        _ = AppInfoPatcher.enableSiloLaunch(&app, shim: shim)
        let launches = try #require(app.info.map("config")?.map("launch"))
        #expect(launches.map("0")?.map("config")?.string("oslist") == "windows")
        #expect(launches.map("1")?.map("config")?.string("oslist") == "windows")
        #expect(launches.map("9000")?.string("arguments") == "--appid 2531310 --exe \"launcher.exe\"")
    }

    @Test("Running it twice leaves one Silo entry and changes nothing else")
    func idempotent() throws {
        var app = AppInfoFixtures.tekken
        _ = AppInfoPatcher.enableSiloLaunch(&app, shim: shim)
        let once = app
        let again = AppInfoPatcher.enableSiloLaunch(&app, shim: shim)
        #expect(app.root == once.root)
        #expect(again.changes.isEmpty)   // an identical re-application is no change
        #expect(app.info.map("config")?.map("launch")?.filter { $0.key == "9000" }.count == 1)
    }

    @Test("A game with its own macOS build is left alone unless Windows is preferred")
    func dualBuild() throws {
        var native = AppInfoFixtures.dualBuild
        #expect(!AppInfoPatcher.enableSiloLaunch(&native, shim: shim).changed)
        #expect(native.root == AppInfoFixtures.dualBuild.root)

        var windows = AppInfoFixtures.dualBuild
        _ = AppInfoPatcher.enableSiloLaunch(&windows, shim: shim, preferWindows: true)
        let info = windows.info
        #expect(info.map("depots")?.map("203161")?.map("config")?.string("oslist") == "windows,macos")
        #expect(info.map("depots")?.map("203162")?.map("config")?.string("oslist") == "")   // mac build hidden
        let launches = try #require(info.map("config")?.map("launch"))
        #expect(launches.map("1")?.map("config")?.string("oslist") == "")
        #expect(launches.map("9000")?.string("arguments") == "--appid 203160 --exe \"TombRaider.exe\"")
    }

    @Test("Cloud rules run on every platform and the Windows root maps into the bottle on macOS")
    func cloud() throws {
        var app = AppInfoFixtures.tekken
        let user = "Library/Application Support/Silo/SteamNative/drive_c/users/crossover"
        let first = AppInfoPatcher.enableCloud(&app, userFolderFromHome: user)
        #expect(first.changed)
        // Re-applied by the guard after every Steam session: the same rules again change nothing.
        var again = app
        #expect(!AppInfoPatcher.enableCloud(&again, userFolderFromHome: user).changed)
        #expect(again.info == app.info)
        let ufs = try #require(app.info.map("ufs"))
        let rule = try #require(ufs.map("savefiles")?.map("0"))
        #expect(rule.map("platforms") == [BinaryKVEntry("1", .string("all"))])
        #expect(rule.string("path") == "TEKKEN 8/Saved/SaveGames/{64BitSteamID}")   // cloud names unchanged
        let override = try #require(ufs.map("rootoverrides")?.map("0"))
        #expect(override.string("root") == "WinAppDataLocal")
        #expect(override.string("os") == "MacOS")
        #expect(override.string("oscompare") == "=")
        #expect(override.string("useinstead") == "MacHome")
        #expect(override.string("addpath") == "\(user)/AppData/Local")
    }

    @Test("A native port's macOS overrides are replaced, other platforms' kept, odd roots reported")
    func cloudOverrides() throws {
        var app = AppInfoCache.App(appID: 56_400, header: AppInfoFixtures.header(), root: [BinaryKVEntry("appinfo", .map([
            BinaryKVEntry("ufs", .map([
                BinaryKVEntry("savefiles", .map([
                    BinaryKVEntry("1", .map([BinaryKVEntry("root", .string("WinMyDocuments")),
                                             BinaryKVEntry("platforms", .map([BinaryKVEntry("1", .string("all"))]))])),
                    BinaryKVEntry("2", .map([BinaryKVEntry("root", .string("gameinstall"))])),
                    BinaryKVEntry("3", .map([BinaryKVEntry("root", .string("WinProgramData"))])),
                ])),
                BinaryKVEntry("rootoverrides", .map([
                    BinaryKVEntry("0", .map([BinaryKVEntry("root", .string("WinMyDocuments")), BinaryKVEntry("os", .string("MacOS")),
                                             BinaryKVEntry("useinstead", .string("MacAppSupport"))])),
                    BinaryKVEntry("1", .map([BinaryKVEntry("root", .string("WinMyDocuments")), BinaryKVEntry("os", .string("Linux")),
                                             BinaryKVEntry("useinstead", .string("LinuxXdgDataHome"))])),
                ])),
            ])),
        ]))])
        let result = AppInfoPatcher.enableCloud(&app, userFolderFromHome: "B/drive_c/users/u")
        let overrides = try #require(app.info.map("ufs")?.map("rootoverrides"))
        #expect(overrides.map { $0.key } == ["0", "1"])
        #expect(overrides.map("0")?.string("os") == "Linux")
        #expect(overrides.map("1")?.string("addpath") == "B/drive_c/users/u/Documents")
        #expect(result.changes.contains("root WinProgramData: not mapped"))
        #expect(!result.changes.contains { $0.contains("gameinstall") })
    }

    @Test("The patched tree survives a round trip through the cache file")
    func patchedRoundTrip() throws {
        let cache = try AppInfoCache(data: AppInfoFixtures.cacheData([AppInfoFixtures.tekken]))
        var app = try #require(try cache.app(1_778_820))
        _ = AppInfoPatcher.enableSiloLaunch(&app, shim: shim)
        _ = AppInfoPatcher.enableCloud(&app, userFolderFromHome: "x")
        let reread = try #require(try AppInfoCache(data: cache.replacing(app)).app(1_778_820))
        #expect(reread.root == app.root)
        #expect(reread.changeNumber == app.changeNumber)
    }
}

/// Opt-in check against a REAL Steam cache (a copy — never Steam's own file): `SILO_REAL_APPINFO=<path>`.
/// Skipped on a clean machine, so constraint #4 holds.
@Suite("AppInfoCache on a real Steam cache (opt-in)")
struct AppInfoRealCacheTests {
    static let path = ProcessInfo.processInfo.environment["SILO_REAL_APPINFO"]

    @Test("Every app parses, and re-writing an unchanged app reproduces the file byte for byte",
          .enabled(if: path != nil))
    func realCache() throws {
        let data = try Data(contentsOf: URL(fileURLWithPath: try #require(Self.path)))
        let cache = try AppInfoCache(data: data)
        #expect(!cache.appIDs.isEmpty)
        for id in cache.appIDs { _ = try #require(try cache.app(id)) }
        let stride = max(1, cache.appIDs.count / 40)
        for id in Swift.stride(from: 0, to: cache.appIDs.count, by: stride).map({ cache.appIDs[$0] }) {
            let app = try #require(try cache.app(id))
            #expect(try cache.replacing(app) == data, "app \(id)")
        }
    }
}
