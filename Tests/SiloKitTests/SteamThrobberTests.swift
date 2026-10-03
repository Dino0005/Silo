import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Testing
@testable import SiloKit

@Suite("SteamThrobber")
struct SteamThrobberTests {

    // MARK: - Fixtures

    /// An 8×8 frame: left half `left` (grey level, opaque), right half Steam blue.
    static func frame(left: CGFloat) -> CGImage {
        let ctx = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 32,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(red: left, green: left, blue: left, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: 4, height: 8))
        ctx.setFillColor(red: 0.1, green: 0.6, blue: 1, alpha: 1)
        ctx.fill(CGRect(x: 4, y: 0, width: 4, height: 8))
        return ctx.makeImage()!
    }

    /// Writes a PNG with ImageIO: one frame is a plain PNG, several make an APNG.
    static func writePNG(_ url: URL, frames: [CGImage], delay: Double = 1.0 / 60.0) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let dest = try #require(CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, frames.count, nil))
        if frames.count > 1 {
            CGImageDestinationSetProperties(dest, [kCGImagePropertyPNGDictionary:
                [kCGImagePropertyAPNGLoopCount: 0]] as CFDictionary)
        }
        for frame in frames {
            CGImageDestinationAddImage(dest, frame, [kCGImagePropertyPNGDictionary:
                [kCGImagePropertyAPNGDelayTime: delay, kCGImagePropertyAPNGUnclampedDelayTime: delay]]
                as CFDictionary)
        }
        #expect(CGImageDestinationFinalize(dest))
    }

    /// RGBA (premultiplied) of one pixel, `y` counted from the top.
    static func pixel(_ image: CGImage, x: Int, y: Int) -> [UInt8] {
        let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                            bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let data = ctx.data!.bindMemory(to: UInt8.self, capacity: image.width * image.height * 4)
        let i = (y * image.width + x) * 4
        return [data[i], data[i + 1], data[i + 2], data[i + 3]]
    }

    static func steamDir(_ tmp: TempDir) -> URL { tmp.url.appendingPathComponent("Steam") }
    static func imageURL(_ tmp: TempDir, _ name: String) -> URL {
        steamDir(tmp).appendingPathComponent("clientui/images/\(name)")
    }

    // MARK: - Finding the animation

    @Test("finds the animated PNG among plain ones, whatever its name")
    func findsAnimatedPNG() throws {
        let tmp = try TempDir()
        try Self.writePNG(Self.imageURL(tmp, "aaaa.png"), frames: [Self.frame(left: 1)])
        try Self.writePNG(Self.imageURL(tmp, "8669e97b.png"), frames: [Self.frame(left: 1), Self.frame(left: 0.5)])
        try tmp.write("Steam/clientui/images/notes.png", "not a png")

        let found = SteamThrobber.findAnimation(steamDir: Self.steamDir(tmp))
        #expect(found?.lastPathComponent == "8669e97b.png")
    }

    @Test("no animation when Steam isn't installed or has only plain PNGs")
    func noAnimation() throws {
        let tmp = try TempDir()
        #expect(SteamThrobber.findAnimation(steamDir: Self.steamDir(tmp)) == nil)
        try Self.writePNG(Self.imageURL(tmp, "logo.png"), frames: [Self.frame(left: 1)])
        #expect(SteamThrobber.findAnimation(steamDir: Self.steamDir(tmp)) == nil)
    }

    @Test("acTL frame count read from the header; plain PNGs and non-PNGs give nil")
    func frameCountFromHeader() throws {
        let tmp = try TempDir()
        let apng = Self.imageURL(tmp, "a.png"), png = Self.imageURL(tmp, "p.png")
        try Self.writePNG(apng, frames: [Self.frame(left: 1), Self.frame(left: 0.5), Self.frame(left: 1)])
        try Self.writePNG(png, frames: [Self.frame(left: 1)])
        #expect(SteamThrobber.apngFrameCount(try Data(contentsOf: apng)) == 3)
        #expect(SteamThrobber.apngFrameCount(try Data(contentsOf: png)) == nil)
        #expect(SteamThrobber.apngFrameCount(Data("GIF89a".utf8)) == nil)
        #expect(SteamThrobber.apngFrameCount(Data()) == nil)
    }

    // MARK: - Decoding

    @Test("loads every frame with its real (unclamped) delay")
    func loadsFrames() async throws {
        let tmp = try TempDir()
        try Self.writePNG(Self.imageURL(tmp, "t.png"),
                          frames: [Self.frame(left: 1), Self.frame(left: 0.5), Self.frame(left: 1)])
        let animation = try #require(await SteamThrobber.load(steamDir: Self.steamDir(tmp), pointSize: 4, scale: 2))
        #expect(animation.frameCount == 3)
        #expect(animation.colors.count == 3)
        #expect(animation.masks.allSatisfy { $0.width == 8 && $0.height == 8 })
        for delay in animation.delays { #expect(abs(delay - 1.0 / 60.0) < 0.001) }
        #expect(animation.scale == 2)
    }

    @Test("neutral pixels go to the template mask (alpha = brightness), blue ones to the colour layer")
    func splitsLayers() throws {
        let white = try #require(SteamThrobber.split(Self.frame(left: 1), pixelSize: 8))
        #expect(Self.pixel(white.mask, x: 1, y: 3)[3] == 255)       // white logo → fully opaque in the mask
        #expect(Self.pixel(white.color, x: 1, y: 3)[3] == 0)        // …and absent from the colour layer
        #expect(Self.pixel(white.mask, x: 6, y: 3)[3] == 0)         // blue arc → not in the mask
        let blue = Self.pixel(white.color, x: 6, y: 3)
        #expect(blue[3] == 255 && blue[2] > 200 && blue[0] < 60)    // …kept blue in the colour layer

        let grey = try #require(SteamThrobber.split(Self.frame(left: 0.5), pixelSize: 8))
        let greyAlpha = Self.pixel(grey.mask, x: 1, y: 3)[3]
        #expect(greyAlpha > 100 && greyAlpha < 160)                 // grey ring → fainter than the logo
    }

    // MARK: - Timing

    @Test("frame index follows the delays and loops forever")
    func frameIndex() throws {
        let image = Self.frame(left: 1)
        let animation = SteamThrobber.Animation(masks: [image, image, image], colors: [image, image, image],
                                                delays: [0.1, 0.2, 0.1], scale: 2)
        #expect(animation.duration == 0.4)
        #expect(animation.frameIndex(at: 0) == 0)
        #expect(animation.frameIndex(at: 0.15) == 1)
        #expect(animation.frameIndex(at: 0.35) == 2)
        #expect(animation.frameIndex(at: 0.45) == 0)     // second loop
        #expect(animation.frameIndex(at: 4.25) == 1)
    }
}
