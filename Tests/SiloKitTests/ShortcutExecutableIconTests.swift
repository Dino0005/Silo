import AppKit
import Foundation
import Testing
@testable import SiloKit

/// A shortcut's icon from the game's executable is built like its host bundle's — the user noticed the
/// host's looked better (2026-09-25): all `.icns` sizes, the icon's own shape, no mask.
struct ShortcutExecutableIconTests {
    private func makeICO(size: Int) throws -> Data {
        let context = try #require(CGContext(
            data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.8, green: 0.2, blue: 0.2, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: size, height: size))
        let image = try #require(context.makeImage())
        let out = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(out, "com.microsoft.ico" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return out as Data
    }

    /// The standard sizes macOS picks from — not the one 512 px image the mask used to produce. (64 is
    /// drawn too but the `.icns` container drops it: it isn't one of the iconset sizes; measured.)
    @Test func anExecutableIconCarriesEveryStandardSizeUpTo512() throws {
        let icns = try #require(GameHostBundle.icnsData(fromICO: try makeICO(size: 256)))
        let image = try #require(NSImage(data: icns))
        let widths = Set(image.representations.map(\.pixelsWide))
        #expect(widths.isSuperset(of: [16, 32, 128, 256, 512]))
    }

    /// The icon is the bundle's own, like the host's — `CFBundleIconFile` naming the `.icns` in Resources —
    /// not a Finder custom icon, which macOS draws as-is instead of fitting it to the system shape: the
    /// shortcut came out square next to the host's rounded one (user, 2026-09-26).
    @Test func theIconIsInstalledWhereTheBundleSaysItIs() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let app = try GameShortcut(name: "TEKKEN 8", link: .playSteam(appID: 1778820)).write(into: tmp.url)
        let icns = try #require(GameHostBundle.icnsData(fromICO: try makeICO(size: 256)))
        try GameShortcut.installIcon(icns, in: app)

        let plistData = try Data(contentsOf: app.appendingPathComponent("Contents/Info.plist"))
        let plist = try #require(
            try PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any])
        let iconFile = try #require(plist["CFBundleIconFile"] as? String)
        let installed = app.appendingPathComponent("Contents/Resources/\(iconFile).icns")
        #expect(try Data(contentsOf: installed) == icns)
        // And no Finder custom icon: that's the file `setIcon` leaves, and it would override the bundle's.
        #expect(!FileManager.default.fileExists(atPath: app.appendingPathComponent("Icon\r").path))
    }

    /// Something unusable still yields nothing rather than a broken icon.
    @Test func garbageYieldsNoIcon() {
        #expect(GameHostBundle.icnsData(fromICO: Data("not an icon".utf8)) == nil)
    }
}
