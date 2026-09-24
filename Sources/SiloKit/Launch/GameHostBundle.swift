import CoreGraphics
import Foundation
import ImageIO

/// A per-game **host `.app`** — an icon and identity carrier for the Wine processes a game launch spawns.
///
/// Nothing launches this bundle. It exists because of how macOS 27 resolves window icons: the Dock still
/// honours the icon `winemac.drv` sets at runtime (`-[NSApp setApplicationIconImage:]`), but Mission
/// Control and Stage Manager read the icon of the process's **bundle** — and a Wine process has none, so
/// they draw the generic "exec" icon. Measured on device, including against CrossOver, whose own
/// `steam.exe` measures identically (`bundleIdentifier = nil`, generic icon) and only looks right because
/// a separate bundled app owns its window.
///
/// So Silo hands Wine a directory to put its loader link in — `Contents/MacOS` of one of these bundles,
/// via `SILO_LOADER_LINK_DIR` (`Scripts/patches/0001-loader-bundle-link-dir.patch`, which only widens a
/// mechanism CrossOver's FOSS source already has). Wine hard-links its loader there under the running
/// exe's name and execs it, so the window-owning process runs from inside a real bundle.
///
/// **One bundle serves every process the game spawns.** Measured: an executable inside a bundle reports
/// that bundle's identity, icon and `CFBundleName` even when its file name does NOT match
/// `CFBundleExecutable` — so `explorer.exe`, `steamwebhelper.exe` and the game exe all read as the game.
/// That is also why `CFBundleExecutable` here names a file that need not exist.
///
/// Pure builders (`infoPlist`, `fileSafeName`, `icnsData`) are unit-tested; `write` performs the I/O.
public struct GameHostBundle: Sendable {
    /// The game's display name — becomes `CFBundleName`, which is what macOS shows as the process name.
    public let name: String
    /// Stable per-game token for the bundle identifier and file name (Steam app ID, or a manual game's
    /// UUID string). Two games must never collide on one bundle: the icon would be wrong for one of them.
    public let id: String

    public init(name: String, id: String) {
        self.name = name
        self.id = id
    }

    /// Marks a bundle as ours, so `write` can replace its own previous output and nothing else.
    static let bundleIDPrefix = "com.mikael.silo.host."

    public enum HostBundleError: Error, Sendable, Equatable {
        case writeFailed(String)
        /// The destination is occupied by something that isn't one of our host bundles — refuse rather
        /// than delete it.
        case destinationOccupied(String)
    }

    // MARK: - Pure builders

    /// `Contents/Info.plist`. Deliberately NOT `LSUIElement`: this identity backs a real, visible game
    /// window, so it must be a regular app or the window would have no Dock tile at all. No
    /// `CFBundleIconName` — that key points at an asset catalog we don't have; `CFBundleIconFile` names the
    /// `.icns` written beside it.
    public func infoPlist() -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>CFBundleName</key><string>\(xmlEscaped(name))</string>
            <key>CFBundleDisplayName</key><string>\(xmlEscaped(name))</string>
            <key>CFBundleIdentifier</key><string>\(Self.bundleIDPrefix)\(bundleSafe(id))</string>
            <key>CFBundleExecutable</key><string>\(Self.executableName)</string>
            <key>CFBundleIconFile</key><string>\(Self.iconName)</string>
            <key>CFBundlePackageType</key><string>APPL</string>
            <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
            <key>CFBundleShortVersionString</key><string>1.0</string>
            <key>LSApplicationCategoryType</key><string>public.app-category.games</string>
            <key>LSMinimumSystemVersion</key><string>15.0</string>
        </dict>
        </plist>
        """
    }

    /// Named in `CFBundleExecutable`, and — since the alt-loader route was proven (2026-09-23) — the
    /// **actual host** copied here by `write(into:hostBinary:…)`: the binary LaunchServices starts, which
    /// then adopts the Wine process handed to it over `CX_ALT_LOADER_SOCKET` and becomes it.
    ///
    /// *(Under the older `SILO_LOADER_LINK_DIR` patch route this named a file that was never written —
    /// Wine hard-linked its loader in here instead. That still works: macOS resolves the bundle from the
    /// *running* executable's path, whatever its file name, so both routes can share one bundle.)*
    static let executableName = "SiloGameHost"
    /// Base name of the `.icns` in `Contents/Resources`, matching `CFBundleIconFile`.
    static let iconName = "AppIcon"

    /// A file-system-safe bundle name: path separators and colons neutralized, so `<name>.app` can't
    /// escape the parent directory. The *displayed* name (`CFBundleName`) keeps the original.
    var fileSafeName: String {
        let cleaned = String(name.map { "/:".contains($0) ? "-" : $0 }).trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? "Game" : cleaned
    }

    /// Where the bundle lives under `directory` (normally `AppPaths.hostAppsDir`):
    /// `<directory>/<id>/<name>.app`.
    ///
    /// **The id is the enclosing folder, not part of the `.app` name, and that is deliberate** — the Dock
    /// labels a tile with the bundle's **file name**, in preference to `CFBundleDisplayName` (measured on
    /// device 2026-09-24: a bundle named `Silo Host Check (BEEF0000-…).app` produced a tile reading
    /// exactly that, id and all). Putting the id one level up keeps the tile reading just the game's name
    /// while two games with the same display name still get a bundle each.
    public func bundleURL(in directory: URL) -> URL {
        directory
            .appendingPathComponent(bundleSafe(id), isDirectory: true)
            .appendingPathComponent("\(fileSafeName).app", isDirectory: true)
    }

    /// The value for `SILO_LOADER_LINK_DIR` — the `Contents/MacOS` Wine hard-links its loader into.
    public func loaderLinkDir(in directory: URL) -> URL {
        bundleURL(in: directory).appendingPathComponent("Contents/MacOS", isDirectory: true)
    }

    // MARK: - Icon conversion

    /// Convert a Windows `.ico` (as `PEIcon.icoData(fromExecutable:)` returns) into `.icns` bytes.
    ///
    /// Not a straight re-wrap: `.icns` only accepts specific square sizes, so the largest representation in
    /// the `.ico` is redrawn into each of them. Returns `nil` on anything unusable (no decodable image, a
    /// zero-sized one, or an ImageIO failure) — the caller then writes a bundle with no icon, which still
    /// fixes the process *name*.
    public static func icnsData(fromICO ico: Data) -> Data? {
        guard !ico.isEmpty,
              let source = CGImageSourceCreateWithData(ico as CFData, nil),
              let largest = largestImage(in: source)
        else { return nil }

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output, "com.apple.icns" as CFString, Self.icnsSizes.count, nil)
        else { return nil }

        var added = 0
        for size in Self.icnsSizes {
            guard let scaled = redraw(largest, to: size) else { continue }
            CGImageDestinationAddImage(destination, scaled, nil)
            added += 1
        }
        guard added > 0, CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }

    /// The square sizes an `.icns` may contain. Capped at 512: a Windows icon is rarely bigger than 256, so
    /// a 1024 entry would be pure upscale for four times the bytes.
    private static let icnsSizes = [16, 32, 64, 128, 256, 512]

    /// The biggest representation in a multi-image `.ico` — Windows icons pack several, and the largest is
    /// the only one worth rescaling from.
    private static func largestImage(in source: CGImageSource) -> CGImage? {
        var best: CGImage?
        for index in 0..<CGImageSourceGetCount(source) {
            guard let image = CGImageSourceCreateImageAtIndex(source, index, nil) else { continue }
            if image.width > (best?.width ?? 0) { best = image }
        }
        guard let best, best.width > 0, best.height > 0 else { return nil }
        return best
    }

    /// Redraw `image` into a `size`×`size` bitmap, letterboxed to preserve aspect ratio (a non-square
    /// Windows icon would otherwise come out stretched).
    private static func redraw(_ image: CGImage, to size: Int) -> CGImage? {
        guard let context = CGContext(
            data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.interpolationQuality = .high
        let scale = min(Double(size) / Double(image.width), Double(size) / Double(image.height))
        let width = Double(image.width) * scale, height = Double(image.height) * scale
        context.draw(image, in: CGRect(
            x: (Double(size) - width) / 2, y: (Double(size) - height) / 2, width: width, height: height))
        return context.makeImage()
    }

    // MARK: - I/O

    /// Create (or refresh) the bundle under `directory` and return its `Contents/MacOS`.
    ///
    /// - `hostBinary`: the alt-loader host to install as `Contents/MacOS/SiloGameHost` — the executable
    ///   LaunchServices launches. `nil` leaves `Contents/MacOS` empty, which is what the
    ///   `SILO_LOADER_LINK_DIR` route wants (Wine populates it itself).
    /// - `iconICO`: the game exe's icon as `PEIcon` extracts it; `nil` — or an icon we can't convert —
    ///   just means no `.icns`, which still leaves the process *named* after the game.
    ///
    /// Idempotent, and refuses to overwrite anything that isn't ours. Replacing the host binary while a
    /// previous launch is still running is safe: the running process keeps its own inode.
    @discardableResult
    public func write(
        into directory: URL, hostBinary: URL? = nil, iconICO: Data? = nil,
        fileManager: FileManager = .default
    ) throws -> URL {
        let bundle = bundleURL(in: directory)
        let macOS = bundle.appendingPathComponent("Contents/MacOS", isDirectory: true)

        if fileManager.fileExists(atPath: bundle.path),
           !Self.isHostBundle(at: bundle, fileManager: fileManager) {
            throw HostBundleError.destinationOccupied(bundle.lastPathComponent)
        }
        do {
            // Refresh in place rather than delete-and-recreate: a relaunch while the previous run is still
            // up must not pull the loader hard links out from under a running process.
            try fileManager.createDirectory(at: macOS, withIntermediateDirectories: true)
            try Data(infoPlist().utf8).write(
                to: bundle.appendingPathComponent("Contents/Info.plist"), options: .atomic)
            if let hostBinary {
                let installed = macOS.appendingPathComponent(Self.executableName)
                if fileManager.fileExists(atPath: installed.path) {
                    try fileManager.removeItem(at: installed)
                }
                try fileManager.copyItem(at: hostBinary, to: installed)
                try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: installed.path)
            }
            if let iconICO, let icns = Self.icnsData(fromICO: iconICO) {
                let resources = bundle.appendingPathComponent("Contents/Resources", isDirectory: true)
                try fileManager.createDirectory(at: resources, withIntermediateDirectories: true)
                try icns.write(
                    to: resources.appendingPathComponent("\(Self.iconName).icns"), options: .atomic)
            }
        } catch {
            throw HostBundleError.writeFailed((error as NSError).localizedDescription)
        }
        return macOS
    }

    /// Whether the item at `url` is one of Silo's host bundles — i.e. its `CFBundleIdentifier` carries our
    /// prefix. Anything else (a plain file, a third-party `.app`) reads `false`, so `write` never eats it.
    static func isHostBundle(at url: URL, fileManager: FileManager = .default) -> Bool {
        let plistURL = url.appendingPathComponent("Contents/Info.plist")
        guard let data = fileManager.contents(atPath: plistURL.path),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let id = (plist as? [String: Any])?["CFBundleIdentifier"] as? String
        else { return false }
        return id.hasPrefix(bundleIDPrefix)
    }

    // MARK: - Escaping

    private func xmlEscaped(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
         .replacingOccurrences(of: "<", with: "&lt;")
         .replacingOccurrences(of: ">", with: "&gt;")
    }

    /// A bundle-id-safe slug (alphanumerics, `.` and `-` kept; anything else → `-`).
    private func bundleSafe(_ s: String) -> String {
        String(s.unicodeScalars.map {
            CharacterSet.alphanumerics.contains($0) || $0 == "." || $0 == "-" ? Character($0) : "-"
        })
    }
}
