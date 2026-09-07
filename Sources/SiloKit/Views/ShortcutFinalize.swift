import AppKit
import Foundation

/// View-layer finishing touches for a freshly-written game shortcut `.app`: stamp a custom icon so it looks
/// like the game, then reveal it in Finder so the user sees where it landed. Kept out of the view model so
/// `GameLibraryViewModel` stays free of AppKit + networking — icon acquisition (a PE parse or a CDN fetch)
/// and `NSWorkspace` are UI concerns.
enum ShortcutFinalize {
    /// Stamp `icon` on the bundle (best-effort — a nil icon just leaves the generic app icon) and select it
    /// in Finder. `setIcon` writes the custom-icon resource directly on the file, so it needs no prior
    /// LaunchServices registration.
    @MainActor
    static func apply(icon: NSImage?, to app: URL, shaped: Bool = true) {
        // Every icon we derive ourselves goes through the mask — this is the one place they all reach.
        // A hand-supplied one doesn't: whoever made it already decided its shape and its transparency.
        if let icon {
            NSWorkspace.shared.setIcon(shaped ? macOSShaped(icon) : icon, forFile: app.path, options: [])
        }
        NSWorkspace.shared.activateFileViewerSelecting([app])
    }

    /// An icon the user dropped in themselves, as `Covers/<appID>_icon.png`.
    ///
    /// In `Covers/`, not `Artwork/`: the latter is a cache Silo writes and may empty, so a hand-made file
    /// would eventually vanish from it. This one is used verbatim and ahead of everything else — including
    /// the executable's own icon — because someone who puts a file there has already made the choice.
    static func userIcon(appID: Int, coversDir: URL) -> NSImage? {
        let url = coversDir.appendingPathComponent("\(appID)_icon.png", isDirectory: false)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return NSImage(contentsOf: url)
    }

    /// Redraw an image as a macOS app icon: a rounded square that doesn't fill its own tile.
    ///
    /// The proportions are the system's — the body covers about 82% of the side, corners rounded at 22.5%
    /// of the body — and they're what makes an icon sit right next to the others in the Dock rather than
    /// looking oversized. A full-bleed square reads as foreign there.
    ///
    /// A rectangular source is CROPPED to its centre, not squashed: header art is 460×215, and stretching
    /// it into a square distorted the game's own artwork. The sides usually carry background, so the crop
    /// costs little.
    static func macOSShaped(_ image: NSImage) -> NSImage {
        let side: CGFloat = 512, bodyFraction: CGFloat = 0.824, radiusFraction: CGFloat = 0.225
        let body = side * bodyFraction
        let inset = (side - body) / 2
        let frame = NSRect(x: inset, y: inset, width: body, height: body)

        // The centre square of the source, in the source's own coordinates.
        let s = image.size
        guard s.width > 0, s.height > 0 else { return image }
        let edge = min(s.width, s.height)
        let from = NSRect(x: (s.width - edge) / 2, y: (s.height - edge) / 2, width: edge, height: edge)

        let out = NSImage(size: NSSize(width: side, height: side))
        out.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        NSBezierPath(roundedRect: frame, xRadius: body * radiusFraction,
                     yRadius: body * radiusFraction).addClip()
        image.draw(in: frame, from: from, operation: .sourceOver, fraction: 1)
        out.unlockFocus()
        return out
    }

    /// Best-effort fetch of a remote image (a Steam title's header art) as an icon. Returns nil offline or on
    /// any failure — the shortcut then simply carries the default app icon.
    static func remoteIcon(_ url: URL?) async -> NSImage? {
        guard let url, let (data, _) = try? await URLSession.shared.data(from: url) else { return nil }
        return NSImage(data: data)
    }

    /// The game's own Windows icon, read out of its executable — square by construction, and measured at
    /// 256×256 on TEKKEN 8, where the header art had to be squashed from 460×215 into a square and came out
    /// distorted.
    ///
    /// Steam's own icon hash isn't usable: the official `ICommunityService/GetApps` returns one, but that
    /// file only exists as a 799-byte `.jpg` thumbnail. The real `.ico` hangs off a `clienticon` hash the
    /// public API doesn't expose — it lives in `appinfo.vdf`, an undocumented binary, or on a third-party
    /// service. The executable is already on disk.
    static func executableIcon(at exe: URL) async -> NSImage? {
        let ico: Data? = await Task.detached(priority: .utility) {
            guard let data = try? Data(contentsOf: exe, options: .mappedIfSafe) else { return nil }
            return PEIcon.icoData(fromExecutable: data)
        }.value
        return ico.flatMap { NSImage(data: $0) }
    }

    /// The executable a game actually ran, taken from the header its own launch log carries:
    ///
    ///     args  : /…/RESIDENT EVIL requiem…/re9.exe
    ///
    /// Which one it is can't be guessed from the folder. Resident Evil ships three — `re9.exe` alongside
    /// `CrashReport.exe` and `InstallerMessage.exe` — while TEKKEN 8 ships one, a 196 KB launcher; "the
    /// biggest" would pick right in the first case and wrong in the second. A shortcut is never made before
    /// the first launch, so the log is there.
    static func loggedExecutable(logFile: URL) -> URL? {
        guard let text = try? String(contentsOf: logFile, encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n", maxSplits: 8, omittingEmptySubsequences: false)
        where line.hasPrefix("args  : ") {
            let path = String(line.dropFirst("args  : ".count))
            // Just the executable: anything after it is the game's own arguments.
            guard let end = path.range(of: ".exe", options: [.caseInsensitive, .backwards]) else { continue }
            return URL(fileURLWithPath: String(path[path.startIndex..<end.upperBound]))
        }
        return nil
    }

    /// Fall back on the executables sitting in the game's own folder, taking the first that carries an icon.
    /// Only that folder — the nested ones under `Binaries/` hold engine helpers, not the game's face.
    static func firstIconBearingExecutable(in dir: URL) async -> NSImage? {
        let entries = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil))
            ?? []
        for exe in entries.filter({ $0.pathExtension.lowercased() == "exe" }).sorted(by: {
            $0.lastPathComponent < $1.lastPathComponent
        }) {
            if let icon = await executableIcon(at: exe) { return icon }
        }
        return nil
    }
}
