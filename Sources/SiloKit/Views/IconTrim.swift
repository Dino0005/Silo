import AppKit

/// App icons as macOS hands them over carry their own transparent margin, and it differs from icon to icon (an
/// `.icns` Silo made from a game's exe, one Steam made, one in the system's icon shape): side by side in the
/// library's icon tiles they came out 115 to 122 px wide where Apple's Games app shows every one at the same size
/// (user, 2026-11-23). Trimming that margin lets every icon fill the same box.
enum IconTrim {
    /// `image` rendered at `side` px, cropped to the bounding box of its visible pixels and made square around it.
    /// The original when there is nothing to trim or it can't be rendered.
    static func trimmed(_ image: NSImage, side: Int = 512) -> NSImage {
        guard let cg = render(image, side: side), let box = visibleBounds(cg) else { return image }
        // Square, centred on the visible pixels, so a slightly non-square icon keeps its proportions.
        let edge = max(box.width, box.height)
        let square = CGRect(x: box.midX - edge / 2, y: box.midY - edge / 2, width: edge, height: edge)
            .intersection(CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        guard square.width < CGFloat(cg.width) || square.height < CGFloat(cg.height),
              let cropped = cg.cropping(to: square.integral) else { return image }
        return NSImage(cgImage: cropped, size: NSSize(width: cropped.width, height: cropped.height))
    }

    /// `image` drawn into a `side`×`side` RGBA bitmap.
    static func render(_ image: NSImage, side: Int) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        var rect = CGRect(x: 0, y: 0, width: side, height: side)
        guard let source = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { return nil }
        ctx.draw(source, in: rect)
        return ctx.makeImage()
    }

    /// The smallest rectangle (in the image's top-left pixel coordinates) holding every pixel whose alpha is above
    /// `threshold`; nil for an image with none.
    static func visibleBounds(_ image: CGImage, threshold: UInt8 = 8) -> CGRect? {
        let w = image.width, h = image.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let data = ctx.data else { return nil }
        let px = data.bindMemory(to: UInt8.self, capacity: w * h * 4)
        var minX = w, minY = h, maxX = -1, maxY = -1
        for y in 0..<h {
            for x in 0..<w where px[(y * w + x) * 4 + 3] > threshold {
                if x < minX { minX = x }
                if x > maxX { maxX = x }
                if y < minY { minY = y }
                if y > maxY { maxY = y }
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        // The bitmap's rows run top to bottom in memory, which is CGImage.cropping's coordinate space.
        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }
}
