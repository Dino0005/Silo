import AppKit
import Foundation
import Testing
@testable import SiloKit

/// The rounded-square shape shortcut icons are given.
@Suite("Shortcut icon shape")
struct ShortcutIconMaskTests {

    private func solid(_ w: Int, _ h: Int, _ colour: NSColor) -> NSImage {
        let image = NSImage(size: NSSize(width: w, height: h))
        image.lockFocus()
        colour.setFill()
        NSRect(x: 0, y: 0, width: w, height: h).fill()
        image.unlockFocus()
        return image
    }

    private func pixel(_ image: NSImage, x: Int, y: Int) -> NSColor? {
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.colorAt(x: x, y: y)
    }

    @Test("the result is a square canvas whatever shape went in")
    func squaresARectangle() {
        // Header art is 460×215; a square icon can't show it whole without distorting it.
        let shaped = ShortcutFinalize.macOSShaped(solid(460, 215, .systemBlue))
        #expect(shaped.size.width == shaped.size.height)
    }

    @Test("the corners are clear and the middle is painted — the rounded body, not a full square")
    func roundsTheCorners() throws {
        let shaped = ShortcutFinalize.macOSShaped(solid(256, 256, .systemRed))
        let n = Int(shaped.size.width)

        // Dead centre: inside the body, so it carries the image.
        let middle = try #require(pixel(shaped, x: n / 2, y: n / 2))
        #expect(middle.alphaComponent > 0.9)

        // The tile's own corner sits outside the body entirely — icons don't fill their tile.
        let corner = try #require(pixel(shaped, x: 1, y: 1))
        #expect(corner.alphaComponent < 0.1)
    }

    @Test("a hand-supplied Covers/<appID>_icon.png is found; anything else isn't")
    func findsUserIcon() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let covers = tmp.url.appendingPathComponent("Covers", isDirectory: true)
        try FileManager.default.createDirectory(at: covers, withIntermediateDirectories: true)
        #expect(ShortcutFinalize.userIcon(appID: 3764200, coversDir: covers) == nil)

        let png = try #require(solid(64, 64, .systemGreen).tiffRepresentation
            .flatMap { NSBitmapImageRep(data: $0) }?.representation(using: .png, properties: [:]))
        try png.write(to: covers.appendingPathComponent("3764200_icon.png"))
        #expect(ShortcutFinalize.userIcon(appID: 3764200, coversDir: covers) != nil)
        // Per app ID: another game's shortcut must not pick up this one.
        #expect(ShortcutFinalize.userIcon(appID: 1778820, coversDir: covers) == nil)
    }

    @Test("a zero-sized image is returned untouched rather than crashing the draw")
    func degradesOnEmptyInput() {
        let empty = NSImage(size: .zero)
        #expect(ShortcutFinalize.macOSShaped(empty).size == .zero)
    }
}
