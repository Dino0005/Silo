import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import SiloKit

/// `GameHostBundle` — the per-game `.app` that carries the icon/identity for a launch's Wine processes.
/// Everything here is runtime-independent (no Wine, no GPTK): plist text, path shaping, ICO→ICNS
/// conversion via ImageIO, and bundle I/O in a temp dir.
struct GameHostBundleTests {

    // MARK: - Info.plist

    @Test func infoPlistCarriesNameIdentityAndIcon() {
        let plist = GameHostBundle(name: "Tekken 8", id: "1778820").infoPlist()
        #expect(plist.contains("<key>CFBundleName</key><string>Tekken 8</string>"))
        #expect(plist.contains("<key>CFBundleDisplayName</key><string>Tekken 8</string>"))
        #expect(plist.contains(
            "<key>CFBundleIdentifier</key><string>com.mikael.silo.host.1778820</string>"))
        #expect(plist.contains("<key>CFBundleIconFile</key><string>AppIcon</string>"))
        #expect(plist.contains("<key>CFBundlePackageType</key><string>APPL</string>"))
    }

    /// The opposite of `GameShortcut`: this identity backs a real, visible game window, so making it a
    /// background agent would leave that window with no Dock tile at all.
    @Test func infoPlistIsNotABackgroundAgent() {
        #expect(!GameHostBundle(name: "G", id: "1").infoPlist().contains("LSUIElement"))
    }

    /// `CFBundleIconName` points at an asset catalog this bundle doesn't have; only the `.icns` key belongs.
    @Test func infoPlistOmitsAssetCatalogIconKey() {
        #expect(!GameHostBundle(name: "G", id: "1").infoPlist().contains("CFBundleIconName"))
    }

    @Test func infoPlistEscapesXMLInTheName() {
        let plist = GameHostBundle(name: "Tom & Jerry <2>", id: "7").infoPlist()
        #expect(plist.contains("<string>Tom &amp; Jerry &lt;2&gt;</string>"))
        #expect(!plist.contains("Tom & Jerry <2>"))
    }

    @Test func identifierSlugsUnsafeCharactersInTheID() {
        let plist = GameHostBundle(name: "G", id: "A1B2/C3 D4").infoPlist()
        #expect(plist.contains("<string>com.mikael.silo.host.A1B2-C3-D4</string>"))
    }

    // MARK: - Paths

    /// A game whose name contains a path separator must not be able to place its bundle outside the
    /// directory it was handed.
    @Test func bundleNameCannotEscapeTheDirectory() {
        let root = URL(fileURLWithPath: "/tmp/hosts", isDirectory: true)
        let url = GameHostBundle(name: "../../evil/Game", id: "9").bundleURL(in: root)
        #expect(url.deletingLastPathComponent().path == root.appendingPathComponent("9").path)
        #expect(!url.lastPathComponent.contains("/"))
    }

    @Test func emptyNameStillYieldsAUsableBundleName() {
        let url = GameHostBundle(name: "   ", id: "9").bundleURL(in: URL(fileURLWithPath: "/tmp"))
        #expect(url.lastPathComponent == "Game.app")
    }

    /// The Dock labels a tile with the bundle's **file name**, ahead of `CFBundleDisplayName` (measured
    /// on device): so the `.app` is named after the game alone, and the id disambiguates one level up.
    @Test func theAppIsNamedAfterTheGameAndTheIDIsTheFolder() {
        let url = GameHostBundle(name: "God of War", id: "538C9332").bundleURL(
            in: URL(fileURLWithPath: "/tmp/hosts", isDirectory: true))
        #expect(url.lastPathComponent == "God of War.app")
        #expect(url.deletingLastPathComponent().lastPathComponent == "538C9332")
    }

    /// Two games sharing a display name must get one bundle each — otherwise one of them shows the
    /// other's icon.
    @Test func sameNameDifferentIDsDoNotCollide() {
        let root = URL(fileURLWithPath: "/tmp/hosts", isDirectory: true)
        let a = GameHostBundle(name: "Doom", id: "1").bundleURL(in: root)
        let b = GameHostBundle(name: "Doom", id: "2").bundleURL(in: root)
        #expect(a != b)
    }

    @Test func loaderLinkDirIsTheBundlesMacOSDir() {
        let root = URL(fileURLWithPath: "/tmp/hosts", isDirectory: true)
        let bundle = GameHostBundle(name: "Doom", id: "1")
        #expect(bundle.loaderLinkDir(in: root).path
                == bundle.bundleURL(in: root).appendingPathComponent("Contents/MacOS").path)
    }

    // MARK: - ICO → ICNS

    @Test func icnsConversionRejectsGarbage() {
        #expect(GameHostBundle.icnsData(fromICO: Data()) == nil)
        #expect(GameHostBundle.icnsData(fromICO: Data("not an icon at all".utf8)) == nil)
    }

    @Test func icnsConversionProducesADecodableICNS() throws {
        let ico = try #require(Self.makeICO(size: 48), "ImageIO could not write a test .ico")
        let icns = try #require(GameHostBundle.icnsData(fromICO: ico))

        // Round-trip it: a real .icns that ImageIO can read back, carrying several sizes.
        let source = try #require(CGImageSourceCreateWithData(icns as CFData, nil))
        #expect(CGImageSourceGetType(source) as String? == "com.apple.icns")
        #expect(CGImageSourceGetCount(source) > 1)
    }

    /// `.icns` only accepts square entries, so every emitted representation must be one — that's what
    /// `redraw` letterboxes for. (The non-square *input* path isn't reachable from a test: ImageIO refuses
    /// to encode a non-square `.ico`, so a genuinely oblong Windows icon can only be checked on device.)
    @Test func icnsRepresentationsAreSquare() throws {
        let ico = try #require(Self.makeICO(size: 48))
        let icns = try #require(GameHostBundle.icnsData(fromICO: ico))
        let source = try #require(CGImageSourceCreateWithData(icns as CFData, nil))
        for index in 0..<CGImageSourceGetCount(source) {
            let image = try #require(CGImageSourceCreateImageAtIndex(source, index, nil))
            #expect(image.width == image.height)
        }
    }

    // MARK: - write()

    @Test func writeCreatesTheBundleAndReturnsTheLinkDir() throws {
        let root = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = GameHostBundle(name: "Doom", id: "42")

        let linkDir = try bundle.write(into: root)

        #expect(linkDir == bundle.loaderLinkDir(in: root))
        // Contents/MacOS must exist and be EMPTY: Wine puts the loader links in it.
        #expect(FileManager.default.fileExists(atPath: linkDir.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: linkDir.path).isEmpty)
        let plist = bundle.bundleURL(in: root).appendingPathComponent("Contents/Info.plist")
        #expect(FileManager.default.fileExists(atPath: plist.path))
    }

    @Test func writeWithoutAnIconSkipsTheResourcesFile() throws {
        let root = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = GameHostBundle(name: "Doom", id: "42")
        try bundle.write(into: root, iconICO: nil)
        let icns = bundle.bundleURL(in: root)
            .appendingPathComponent("Contents/Resources/AppIcon.icns")
        #expect(!FileManager.default.fileExists(atPath: icns.path))
    }

    @Test func writeWithAnIconEmitsTheICNS() throws {
        let root = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = GameHostBundle(name: "Doom", id: "42")
        let ico = try #require(Self.makeICO(size: 64))

        try bundle.write(into: root, iconICO: ico)

        let icns = bundle.bundleURL(in: root)
            .appendingPathComponent("Contents/Resources/AppIcon.icns")
        #expect(FileManager.default.fileExists(atPath: icns.path))
        // The name must match CFBundleIconFile or macOS won't find it.
        #expect(bundle.infoPlist().contains("<string>AppIcon</string>"))
    }

    /// An unparseable icon degrades to "no icon", not to a failed write — the launch must still proceed.
    @Test func writeSurvivesAnUnusableIcon() throws {
        let root = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = GameHostBundle(name: "Doom", id: "42")
        let linkDir = try bundle.write(into: root, iconICO: Data([0x00, 0x01, 0x02]))
        #expect(FileManager.default.fileExists(atPath: linkDir.path))
    }

    /// Re-launching must refresh in place, NOT delete and recreate: the previous run may still be up with
    /// its loader hard links inside `Contents/MacOS`.
    @Test func writeIsIdempotentAndKeepsExistingLinkDirContents() throws {
        let root = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = GameHostBundle(name: "Doom", id: "42")
        let linkDir = try bundle.write(into: root)
        // stand in for a loader hard link Wine already made
        let planted = linkDir.appendingPathComponent("game.exe")
        try Data("loader".utf8).write(to: planted)

        try bundle.write(into: root)

        #expect(FileManager.default.fileExists(atPath: planted.path))
    }

    @Test func writeRefusesADestinationThatIsNotOurs() throws {
        let root = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = GameHostBundle(name: "Doom", id: "42")
        // an unrelated bundle squatting on the exact name
        let squatter = bundle.bundleURL(in: root)
        try FileManager.default.createDirectory(
            at: squatter.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        try Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <plist version="1.0"><dict>
        <key>CFBundleIdentifier</key><string>com.someone.else</string>
        </dict></plist>
        """.utf8).write(to: squatter.appendingPathComponent("Contents/Info.plist"))

        #expect(throws: GameHostBundle.HostBundleError.destinationOccupied(squatter.lastPathComponent)) {
            try bundle.write(into: root)
        }
    }

    /// Our OWN previous bundle is replaceable — that's what makes a re-launch idempotent.
    @Test func hostBundleDetectionRecognisesOnlyOurs() throws {
        let root = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = GameHostBundle(name: "Doom", id: "42")
        try bundle.write(into: root)
        #expect(GameHostBundle.isHostBundle(at: bundle.bundleURL(in: root)))
        // a plain file has no Contents/Info.plist at all
        let file = root.appendingPathComponent("plain.app")
        try Data("x".utf8).write(to: file)
        #expect(!GameHostBundle.isHostBundle(at: file))
    }

    // MARK: - The alt-loader host binary

    /// The host is what LaunchServices launches, so it must land at `Contents/MacOS/SiloGameHost`
    /// (the name `CFBundleExecutable` declares) and be executable.
    @Test func writeInstallsTheHostBinaryAsTheBundleExecutable() throws {
        let root = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let fake = root.appendingPathComponent("prebuilt-host")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: fake)
        let bundle = GameHostBundle(name: "Doom", id: "42")

        let macOS = try bundle.write(into: root, hostBinary: fake)

        let installed = macOS.appendingPathComponent("SiloGameHost")
        #expect(FileManager.default.fileExists(atPath: installed.path))
        #expect(FileManager.default.isExecutableFile(atPath: installed.path))
        #expect(bundle.infoPlist().contains("<key>CFBundleExecutable</key><string>SiloGameHost</string>"))
    }

    /// A relaunch must refresh the host in place — the previous run may still be executing from the old
    /// copy, which is safe because it keeps its own inode.
    @Test func writeReplacesAnOlderHostBinary() throws {
        let root = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let old = root.appendingPathComponent("v1"), new = root.appendingPathComponent("v2")
        try Data("old".utf8).write(to: old)
        try Data("a-much-newer-build".utf8).write(to: new)
        let bundle = GameHostBundle(name: "Doom", id: "42")

        try bundle.write(into: root, hostBinary: old)
        let macOS = try bundle.write(into: root, hostBinary: new)

        let installed = macOS.appendingPathComponent("SiloGameHost")
        #expect(try Data(contentsOf: installed) == Data("a-much-newer-build".utf8))
    }

    /// Without a host binary the directory stays empty — that is the `SILO_LOADER_LINK_DIR` route, where
    /// Wine hard-links its own loader in here instead.
    @Test func writeWithoutAHostBinaryLeavesTheDirectoryEmpty() throws {
        let root = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let macOS = try GameHostBundle(name: "Doom", id: "42").write(into: root)
        #expect(try FileManager.default.contentsOfDirectory(atPath: macOS.path).isEmpty)
    }

    // MARK: - Helpers

    private static func tempDir() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("silo-hostbundle-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Build a real `.ico` with ImageIO so the conversion is exercised on genuine input — no Wine, no
    /// fixture file, works on a machine with zero runtimes.
    private static func makeICO(size: Int) -> Data? {
        let h = size
        guard let context = CGContext(
            data: nil, width: size, height: h, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.9, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: size, height: h))
        guard let image = context.makeImage() else { return nil }

        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            out, "com.microsoft.ico" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return out as Data
    }
}
