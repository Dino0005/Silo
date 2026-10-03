import Foundation
import CoreGraphics
import ImageIO

/// Steam's own loading animation — the logo with blue arcs circling it — for the toolbar's Steam button
/// while the client starts.
///
/// The animation is an APNG the Windows client ships in `clientui/images/` (180 frames, 60 fps, 210 px;
/// its file name is a content hash). It's Valve's artwork, so Silo never bundles or copies it: it is read
/// from the user's own Steam install, in the bottle, every time the app runs. No Steam installed, or a
/// client update that drops the file → `nil`, and the button keeps the system spinner.
///
/// Frames are split in two layers so the logo works in light mode too. Its white and grey pixels become a
/// template mask (drawn in the toolbar's own foreground colour: white in dark mode, as Steam draws it, and
/// black in light mode, where white would vanish); the blue arcs keep their colour.
public enum SteamThrobber {
    /// Where the client keeps its UI images, relative to the Steam install directory.
    static let imagesSubpath = "clientui/images"

    /// One decoded animation, downscaled to toolbar size.
    public struct Animation: Sendable {
        /// The neutral (white/grey) pixels of each frame, as an alpha mask to render as a template.
        public let masks: [CGImage]
        /// The coloured (blue) pixels of each frame, kept as they are.
        public let colors: [CGImage]
        /// How long each frame stays on screen, in seconds.
        public let delays: [Double]
        /// The pixel scale the frames were rendered at (pixels per point).
        public let scale: CGFloat

        public var frameCount: Int { masks.count }
        public var duration: Double { delays.reduce(0, +) }

        /// The frame to show `elapsed` seconds into a loop that repeats forever.
        public func frameIndex(at elapsed: Double) -> Int {
            guard duration > 0 else { return 0 }
            var t = elapsed.truncatingRemainder(dividingBy: duration)
            if t < 0 { t += duration }
            for (index, delay) in delays.enumerated() {
                if t < delay { return index }
                t -= delay
            }
            return delays.count - 1
        }
    }

    /// Finds the animation in a Steam install and decodes it at `pointSize` × `scale` pixels. Runs off the
    /// main actor: decoding 180 frames takes a noticeable fraction of a second.
    public static func load(steamDir: URL, pointSize: CGFloat = 16, scale: CGFloat = 2) async -> Animation? {
        await Task.detached(priority: .utility) {
            guard let url = findAnimation(steamDir: steamDir) else { return nil }
            return decode(url, pixelSize: Int((pointSize * scale).rounded()), scale: scale)
        }.value
    }

    /// The animated PNG in `clientui/images/` with the most frames. Located by content, not by name: the
    /// name is a hash that changes whenever Valve re-exports the artwork.
    static func findAnimation(steamDir: URL) -> URL? {
        let dir = steamDir.appendingPathComponent(imagesSubpath, isDirectory: true)
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return nil }
        var best: (url: URL, frames: Int)?
        for file in files where file.pathExtension.lowercased() == "png" {
            guard let handle = try? FileHandle(forReadingFrom: file) else { continue }
            let head = (try? handle.read(upToCount: 4096)) ?? Data()
            try? handle.close()
            guard let frames = apngFrameCount(head), frames > 1 else { continue }
            if best == nil || frames > best!.frames
                || (frames == best!.frames && file.lastPathComponent < best!.url.lastPathComponent) {
                best = (file, frames)
            }
        }
        return best?.url
    }

    /// The frame count an APNG declares in its `acTL` chunk, or `nil` for a plain PNG (or not a PNG). APNG
    /// requires `acTL` before the first `IDAT`, so the file's first few KB are enough.
    static func apngFrameCount(_ data: Data) -> Int? {
        let bytes = [UInt8](data)
        let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        guard bytes.count >= 8, Array(bytes[0..<8]) == signature else { return nil }
        func u32(_ i: Int) -> Int {
            Int(bytes[i]) << 24 | Int(bytes[i + 1]) << 16 | Int(bytes[i + 2]) << 8 | Int(bytes[i + 3])
        }
        var offset = 8
        while offset + 8 <= bytes.count {
            let length = u32(offset)
            let type = String(decoding: bytes[(offset + 4)..<(offset + 8)], as: UTF8.self)
            if type == "acTL" {
                return offset + 12 <= bytes.count ? u32(offset + 8) : nil
            }
            if type == "IDAT" || type == "IEND" { return nil }
            offset += 12 + length
        }
        return nil
    }

    /// Decodes every frame (ImageIO composites APNG frames onto each other), downscales it, and splits it
    /// into the two layers.
    static func decode(_ url: URL, pixelSize: Int, scale: CGFloat) -> Animation? {
        guard pixelSize > 0, let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let count = CGImageSourceGetCount(source)
        guard count > 1 else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: pixelSize,
        ]
        var masks: [CGImage] = [], colors: [CGImage] = [], delays: [Double] = []
        for index in 0..<count {
            guard let frame = CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary),
                  let (mask, color) = split(frame, pixelSize: pixelSize) else { return nil }
            masks.append(mask)
            colors.append(color)
            delays.append(frameDelay(source, index))
        }
        return Animation(masks: masks, colors: colors, delays: delays, scale: scale)
    }

    /// A frame's delay. The unclamped value is the real one (1/60 s for Steam's); the plain one is clamped
    /// by ImageIO to at least 0.05 s, which would play the animation at a third of its speed.
    static func frameDelay(_ source: CGImageSource, _ index: Int) -> Double {
        let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
        let png = properties?[kCGImagePropertyPNGDictionary] as? [CFString: Any]
        let delay = (png?[kCGImagePropertyAPNGUnclampedDelayTime] as? Double)
            ?? (png?[kCGImagePropertyAPNGDelayTime] as? Double) ?? 0
        return delay > 0 ? delay : 1.0 / 60.0
    }

    /// Below this saturation a pixel counts as neutral (white/grey logo and ring), above it as colour.
    static let saturationThreshold = 0.25

    /// Splits a frame into a template mask of its neutral pixels (alpha = how bright they are, so the grey
    /// ring stays fainter than the white logo) and an image of its coloured pixels.
    static func split(_ frame: CGImage, pixelSize: Int) -> (mask: CGImage, color: CGImage)? {
        let space = CGColorSpaceCreateDeviceRGB()
        let info = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let source = CGContext(data: nil, width: pixelSize, height: pixelSize, bitsPerComponent: 8,
                                     bytesPerRow: pixelSize * 4, space: space, bitmapInfo: info),
              let maskContext = CGContext(data: nil, width: pixelSize, height: pixelSize, bitsPerComponent: 8,
                                          bytesPerRow: pixelSize * 4, space: space, bitmapInfo: info),
              let colorContext = CGContext(data: nil, width: pixelSize, height: pixelSize, bitsPerComponent: 8,
                                           bytesPerRow: pixelSize * 4, space: space, bitmapInfo: info),
              let src = source.data, let maskData = maskContext.data, let colorData = colorContext.data
        else { return nil }
        // Centred, aspect kept: the thumbnail is at most pixelSize on its long side.
        let w = CGFloat(frame.width), h = CGFloat(frame.height), side = CGFloat(pixelSize)
        let fit = min(side / w, side / h)
        source.draw(frame, in: CGRect(x: (side - w * fit) / 2, y: (side - h * fit) / 2,
                                      width: w * fit, height: h * fit))
        let s = src.bindMemory(to: UInt8.self, capacity: pixelSize * pixelSize * 4)
        let m = maskData.bindMemory(to: UInt8.self, capacity: pixelSize * pixelSize * 4)
        let c = colorData.bindMemory(to: UInt8.self, capacity: pixelSize * pixelSize * 4)
        for p in 0..<(pixelSize * pixelSize) {
            let i = p * 4
            let a = s[i + 3]
            guard a > 0 else { continue }
            let maxC = max(s[i], s[i + 1], s[i + 2]), minC = min(s[i], s[i + 1], s[i + 2])
            let saturation = maxC == 0 ? 0 : Double(maxC - minC) / Double(maxC)
            if saturation < saturationThreshold {
                // Premultiplied, so the brightest channel already is alpha × brightness.
                m[i] = maxC; m[i + 1] = maxC; m[i + 2] = maxC; m[i + 3] = maxC
            } else {
                c[i] = s[i]; c[i + 1] = s[i + 1]; c[i + 2] = s[i + 2]; c[i + 3] = a
            }
        }
        guard let mask = maskContext.makeImage(), let color = colorContext.makeImage() else { return nil }
        return (mask, color)
    }
}
