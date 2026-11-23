import AppKit
import Testing
@testable import SiloKit

/// `IconTrim`: every library icon fills the same box once its own transparent margin is cut away.
@Suite("Library icon trim")
struct IconTrimTests {
    /// A `side`×`side` transparent image with an opaque rectangle at `rect` (top-left pixel coordinates).
    static func image(side: Int, opaque rect: CGRect) throws -> CGImage {
        let ctx = try #require(CGContext(data: nil, width: side, height: side, bitsPerComponent: 8,
                                         bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        // CoreGraphics draws bottom-up: flip the rect so `rect` is where it lands in the image's top-left space.
        ctx.fill(CGRect(x: rect.minX, y: CGFloat(side) - rect.maxY, width: rect.width, height: rect.height))
        return try #require(ctx.makeImage())
    }

    @Test("The visible box is found where it is, not mirrored")
    func bounds() throws {
        let cg = try Self.image(side: 100, opaque: CGRect(x: 20, y: 10, width: 40, height: 30))
        #expect(IconTrim.visibleBounds(cg) == CGRect(x: 20, y: 10, width: 40, height: 30))
    }

    @Test("A fully transparent image has nothing visible")
    func empty() throws {
        let cg = try Self.image(side: 32, opaque: .zero)
        #expect(IconTrim.visibleBounds(cg) == nil)
    }

    @Test("Icons with different margins come out the same: their visible part, squared")
    func sameSizeAfterTrim() throws {
        let wide = NSImage(cgImage: try Self.image(side: 512, opaque: CGRect(x: 20, y: 20, width: 472, height: 472)),
                           size: NSSize(width: 512, height: 512))
        let narrow = NSImage(cgImage: try Self.image(side: 512, opaque: CGRect(x: 60, y: 60, width: 392, height: 392)),
                             size: NSSize(width: 512, height: 512))
        for icon in [wide, narrow] {
            let trimmed = IconTrim.trimmed(icon)
            let cg = try #require(IconTrim.render(trimmed, side: 256))
            // After trimming, the visible part fills the whole image (within a pixel of scaling).
            let box = try #require(IconTrim.visibleBounds(cg))
            #expect(box.minX <= 1 && box.minY <= 1 && box.maxX >= 255 && box.maxY >= 255)
            #expect(trimmed.size.width == trimmed.size.height)
        }
    }

    @Test("Nothing to trim: the same image back")
    func fullBleed() throws {
        let full = NSImage(cgImage: try Self.image(side: 64, opaque: CGRect(x: 0, y: 0, width: 64, height: 64)),
                           size: NSSize(width: 64, height: 64))
        #expect(IconTrim.trimmed(full, side: 64) === full)
    }
}
