import Foundation

/// The libav + matroska add-on for a runtime in CrossOver's `lib64` layout: gst-libav's FFmpeg decoders (VC-1,
/// WMV, WMA — Devil May Cry 5's movies) and the matroska demuxer, built for CrossOver's own GStreamer by
/// `Scripts/build-gst-libav.sh` and published as a `gst-libav-<gstreamer version>` release. CrossOver ships
/// GStreamer without them, so a Wine imported from CrossOver (`CrossOverWineImporter`) gets them added from
/// that release — the same files and checks as `Scripts/add-gst-libav.sh`, which did this by hand.
///
/// Pure parts only (version read, release pick, merge); the download is `RuntimeManager.addGStreamerAddOn`.
public enum GStreamerAddOn {
    public static let tagPrefix = "gst-libav-"
    /// What the add-on package carries at its root, next to `lib64/`: the GStreamer version it was built for.
    static let versionFile = "GSTREAMER_VERSION"
    static let corePath = "lib64/libgstreamer-1.0.0.dylib"
    static let pluginPath = "lib64/gstreamer-1.0/libgstlibav.dylib"

    public enum AddOnError: Error, Equatable, LocalizedError {
        /// No `lib64/libgstreamer-1.0.0.dylib` to read a version from.
        case noGStreamer
        /// A plugin built for another GStreamer minor is refused by (or untested against) this core.
        case versionMismatch(runtime: Int, addOn: String)
        case noRelease(minor: Int)
        case badPackage
        /// The runtime already has a DIFFERENT file at that path — never overwritten.
        case wouldOverwrite(String)

        public var errorDescription: String? {
            switch self {
            case .noGStreamer:
                String(localized: "This runtime has no GStreamer in lib64.")
            case .versionMismatch(let runtime, let addOn):
                String(localized: "Its GStreamer is 1.\(runtime), the libav add-on is built for \(addOn).")
            case .noRelease(let minor):
                String(localized: "No libav add-on is published for GStreamer 1.\(minor).")
            case .badPackage:
                String(localized: "The libav add-on package isn't laid out as expected.")
            case .wouldOverwrite(let path):
                String(localized: "\(path) already exists in the runtime and differs — not overwriting it.")
            }
        }
    }

    /// Whether the runtime already carries the add-on.
    public static func isInstalled(inRuntime root: URL) -> Bool {
        FileManager.default.fileExists(atPath: root.appendingPathComponent(pluginPath).path)
    }

    /// The GStreamer MINOR of a runtime (24 for 1.24.x), from its core library's install-name compatibility
    /// version: GStreamer sets it to minor*100+micro+1 (1.24.4 → 2405). Read straight from the Mach-O so it
    /// needs no `otool` — Command Line Tools may not be installed.
    public static func gstreamerMinor(ofRuntime root: URL) -> Int? {
        guard let data = try? Data(contentsOf: root.appendingPathComponent(corePath), options: .alwaysMapped),
              let compat = compatibilityVersion(ofDylib: data) else { return nil }
        return Int(compat >> 16) / 100
    }

    /// `compatibility_version` of a dylib's `LC_ID_DYLIB` (packed X.Y.Z as X<<16|Y<<8|Z), for a thin 64-bit
    /// image or the x86_64 slice of a universal one.
    static func compatibilityVersion(ofDylib data: Data) -> UInt32? {
        func u32(_ at: Int, bigEndian: Bool = false) -> UInt32? {
            guard at >= 0, at + 4 <= data.count else { return nil }
            let v = data[data.startIndex + at ..< data.startIndex + at + 4].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
            return bigEndian ? UInt32(bigEndian: v) : UInt32(littleEndian: v)
        }
        var base = 0
        if u32(0, bigEndian: true) == 0xCAFE_BABE, let count = u32(4, bigEndian: true) {   // universal
            let x86_64: UInt32 = 0x0100_0007
            guard let slice = (0..<Int(count)).first(where: { u32(8 + $0 * 20, bigEndian: true) == x86_64 }),
                  let offset = u32(8 + slice * 20 + 8, bigEndian: true) else { return nil }
            base = Int(offset)
        }
        guard u32(base) == 0xFEED_FACF, let ncmds = u32(base + 16) else { return nil }   // MH_MAGIC_64
        var at = base + 32
        for _ in 0..<ncmds {
            guard let cmd = u32(at), let size = u32(at + 4), size >= 8 else { return nil }
            if cmd == 0xD { return u32(at + 20) }   // LC_ID_DYLIB: name, timestamp, current, COMPATIBILITY
            at += Int(size)
        }
        return nil
    }

    /// The add-on release for a GStreamer minor (`gst-libav-1.<minor>.*`), newest first as GitHub lists them.
    public static func release(in releases: [GitHubRelease], forMinor minor: Int) -> GitHubRelease? {
        releases.first { $0.tagName.lowercased().hasPrefix("\(tagPrefix)1.\(minor).") }
    }

    /// The package root inside an extracted add-on: the dir holding `GSTREAMER_VERSION` and `lib64/` — the
    /// archive's top level, or the one folder it may be wrapped in.
    static func packageRoot(in extracted: URL) -> URL? {
        let fm = FileManager.default
        if fm.fileExists(atPath: extracted.appendingPathComponent(versionFile).path) { return extracted }
        let children = (try? fm.contentsOfDirectory(at: extracted, includingPropertiesForKeys: nil)) ?? []
        return children.first { fm.fileExists(atPath: $0.appendingPathComponent(versionFile).path) }
    }

    /// Copy the add-on's `lib64` files into the runtime's — after checking it was built for this GStreamer
    /// minor, and that no file it carries already exists there with DIFFERENT content (checked for every file
    /// before anything is copied, so a refusal leaves the runtime untouched). Returns how many files it added.
    @discardableResult
    static func merge(package root: URL, intoRuntime runtime: URL, runtimeMinor: Int) throws -> Int {
        let fm = FileManager.default
        guard let built = try? String(contentsOf: root.appendingPathComponent(versionFile), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
              let builtMinor = built.split(separator: ".").dropFirst().first.flatMap({ Int($0) })
        else { throw AddOnError.badPackage }
        guard builtMinor == runtimeMinor else { throw AddOnError.versionMismatch(runtime: runtimeMinor, addOn: built) }

        let lib64 = root.appendingPathComponent("lib64")
        let files = ["gstreamer-1.0", ""].flatMap { sub -> [String] in
            let dir = sub.isEmpty ? lib64 : lib64.appendingPathComponent(sub)
            return ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? [])
                .filter { $0.hasSuffix(".dylib") }.map { sub.isEmpty ? $0 : "\(sub)/\($0)" }
        }
        guard files.contains(where: { $0.hasPrefix("gstreamer-1.0/") }) else { throw AddOnError.badPackage }
        let target = runtime.appendingPathComponent("lib64")
        for file in files {
            let dst = target.appendingPathComponent(file)
            if fm.fileExists(atPath: dst.path),
               !fm.contentsEqual(atPath: lib64.appendingPathComponent(file).path, andPath: dst.path) {
                throw AddOnError.wouldOverwrite("lib64/\(file)")
            }
        }
        var added = 0
        for file in files {
            let dst = target.appendingPathComponent(file)
            guard !fm.fileExists(atPath: dst.path) else { continue }   // identical already
            try fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.copyItem(at: lib64.appendingPathComponent(file), to: dst)
            added += 1
        }
        return added
    }
}
