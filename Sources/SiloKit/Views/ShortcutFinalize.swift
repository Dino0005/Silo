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
    /// - Parameter id: the app ID for a Steam title, the game's UUID for a non-Steam one — whatever names
    ///   its cover in `Covers/`, so the icon's name is the cover's with `_icon.png` in place of the
    ///   extension. Nothing to look up anywhere else.
    static func userIcon(id: String, coversDir: URL) -> NSImage? {
        let url = coversDir.appendingPathComponent("\(id)_icon.png", isDirectory: false)
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
    ///
    /// Built the same way as the game's host bundle icon (`GameHostBundle.icnsData`): every `.icns` size
    /// from 16 to 512, each redrawn from the largest image in the `.ico`, and the icon's own shape and
    /// transparency left alone. It used to be a single image run through `macOSShaped`, which boxed an
    /// icon that was already designed as one into a rounded square and upscaled a 256 px source to fill
    /// 512 — the user noticed the host's icon looked better than the shortcut's for the same game.
    /// It goes into the bundle as `.icns` (`apply(icns:to:)`), where macOS gives it the system shape; the
    /// mask is for rectangular header art only.
    static func executableIcns(at exe: URL) async -> Data? {
        await Task.detached(priority: .utility) {
            guard let data = try? Data(contentsOf: exe, options: .mappedIfSafe),
                  let ico = PEIcon.icoData(fromExecutable: data) else { return nil }
            return GameHostBundle.icnsData(fromICO: ico)
        }.value
    }

    /// Install an executable's `.icns` as the bundle's own icon (see `GameShortcut.installIcon` for why not
    /// a Finder custom icon), then select the shortcut in Finder. Returns false if it couldn't be written,
    /// so the caller can fall back on the next icon source.
    @MainActor
    static func apply(icns: Data, to app: URL) -> Bool {
        guard (try? GameShortcut.installIcon(icns, in: app)) != nil else { return false }
        // Re-read the bundle now: the same path may have held an earlier shortcut with no icon, and Finder
        // keeps showing what LaunchServices last recorded until told otherwise.
        LSRegisterURL(app as CFURL, true)
        NSWorkspace.shared.activateFileViewerSelecting([app])
        return true
    }

    /// The executable a game actually ran, taken from the header its own launch log carries:
    ///
    ///     args  : /…/RESIDENT EVIL requiem…/re9.exe
    ///
    /// Which one it is can't be guessed from the folder. Resident Evil ships three — `re9.exe` alongside
    /// `CrashReport.exe` and `InstallerMessage.exe` — while TEKKEN 8 ships one, a 196 KB launcher; "the
    /// biggest" would pick right in the first case and wrong in the second. A shortcut is never made before
    /// the first launch, so the log is there.
    ///
    /// Read from the HEAD of the file, and leniently. The header is the first three lines — Silo truncates
    /// the log and writes it there before the process output — so everything the game itself printed
    /// afterwards is beside the point, and it's the part that can be megabytes and hold bytes that aren't
    /// UTF-8. A strict whole-file read gave up over one of those and left the fallback below to guess, which
    /// for Resident Evil means `CrashReport.exe`: first in the alphabet, wrong game.
    static func loggedExecutable(logFile: URL) -> URL? {
        for line in logFile.headString().split(separator: "\n", maxSplits: 8,
                                               omittingEmptySubsequences: false)
        where line.hasPrefix("args  : ") {
            var path = String(line.dropFirst("args  : ".count))
            // A hand-over launch goes through `start /wait /unix <exe>` (see `LaunchOrchestrator`); the
            // wrapper isn't part of the path, and leaving it in made every such game fall back to its cover.
            let wrapper = "start /wait /unix "
            if path.hasPrefix(wrapper) { path = String(path.dropFirst(wrapper.count)) }
            // Just the executable: anything after it is the game's own arguments.
            guard let end = path.range(of: ".exe", options: [.caseInsensitive, .backwards]) else { continue }
            return URL(fileURLWithPath: String(path[path.startIndex..<end.upperBound]))
        }
        return nil
    }

    /// Fall back on the executables sitting in the game's own folder, taking the first that carries an icon.
    /// Only that folder — the nested ones under `Binaries/` hold engine helpers, not the game's face.
    static func firstIconBearingExecutable(in dir: URL) async -> Data? {
        let entries = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil))
            ?? []
        for exe in entries.filter({ $0.pathExtension.lowercased() == "exe" }).sorted(by: {
            $0.lastPathComponent < $1.lastPathComponent
        }) {
            if let icns = await executableIcns(at: exe) { return icns }
        }
        return nil
    }
}
