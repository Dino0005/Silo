import Foundation

/// Installs CrossOver's own Wine into Silo's runtimes, from an installed CrossOver.app.
///
/// The Swift port of `Scripts/install-local-crossover-wine.sh`, so it works from the shipped app: someone
/// who downloaded a release and has CrossOver shouldn't have to clone the repository to run a shell script
/// before the first launch.
///
/// Worth having over a downloaded Wine for two reasons: CrossOver's tree carries GStreamer with its plugin
/// directory (the built Wine can't — `bundle-wine-dylibs.sh` deliberately excludes the media stack, because
/// a bundled copy and a system copy loading into one process clash over ObjC classes and glib types), and
/// it carries `lib64/apple_gptk`, which Silo detects and wires up.
///
/// The copy is self-contained. `otool` over the installed tree — `wineloader`, `libd3dshared`, a sample of
/// modules — shows no reference to /Applications/CrossOver.app, /opt/homebrew or /usr/local: only @rpath
/// and system frameworks. CrossOver can be uninstalled afterwards, and there are no Homebrew dylibs worth
/// bundling (which is why this skips the script's bundling step entirely).
public struct CrossOverWineImporter: Sendable {
    public static let defaultAppPath = "/Applications/CrossOver.app"

    public enum ImportError: Error, Equatable {
        case notFound(String)
        case notACrossOverBundle
        case noVersion
        case noWineTree
        case noLoader
        case copyFailed(Int32)
    }

    /// Which of CrossOver's two runtimes to take. They're installed separately because Silo treats them
    /// separately: one is the Wine to run under, the other an optional graphics backend.
    public enum Component: Sendable, Equatable {
        case wine
        case dxmt

        /// Where it lives inside `Contents/SharedSupport/CrossOver`.
        var sourceSubpath: String { self == .wine ? "" : "lib/dxmt" }
        var namePrefix: String { self == .wine ? "wine-crossover-" : "dxmt-crossover-" }
    }

    /// What an installed CrossOver offers.
    public struct Found: Sendable, Equatable {
        public let version: String
        public let appURL: URL
        /// Whether this CrossOver bundles a DXMT worth extracting. Older builds may not, and the DXMT tab
        /// must not offer an import that would find nothing.
        public let hasDXMT: Bool

        /// `wine-crossover-<version>` — the same naming the script uses, so a CrossOver update installs
        /// ALONGSIDE the previous runtime instead of overwriting it.
        public var runtimeName: String { name(for: .wine) }
        public func name(for component: Component) -> String { component.namePrefix + version }
    }

    private let runner: any ProcessRunning
    // Computed (not stored): FileManager isn't Sendable, but the shared instance is fine to use.
    private var fileManager: FileManager { .default }

    public init(runner: any ProcessRunning) {
        self.runner = runner
    }

    /// Inspect an installed CrossOver, or nil if it isn't there / isn't usable.
    ///
    /// Static and runner-free so a caller can ask without holding the actor that does the installing —
    /// it's two `fileExists` and a plist read. Still file I/O, so callers cache it (see
    /// `RuntimeViewModel.crossOverWine`) rather than calling it from a view body on every redraw.
    public static func detect(at path: String = defaultAppPath) -> Found? {
        let fm = FileManager.default
        let app = URL(fileURLWithPath: path)
        guard fm.fileExists(atPath: app.appendingPathComponent("Contents/Info.plist").path),
              fm.fileExists(atPath: app.appendingPathComponent(
                  "Contents/SharedSupport/CrossOver").path),
              let version = version(ofBundle: app) else { return nil }
        let dxmt = app.appendingPathComponent("Contents/SharedSupport/CrossOver/lib/dxmt/x86_64-windows")
        return Found(version: version, appURL: app,
                     hasDXMT: fm.fileExists(atPath: dxmt.path))
    }

    /// `CFBundleShortVersionString` (the human "26.3.0"), falling back to `CFBundleVersion` for a build that
    /// only sets one of the two — same order as the script.
    static func version(ofBundle app: URL) -> String? {
        guard let plist = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist"))
        else { return nil }
        for key in ["CFBundleShortVersionString", "CFBundleVersion"] {
            if let value = plist[key] as? String,
               !value.trimmingCharacters(in: .whitespaces).isEmpty { return value }
        }
        return nil
    }

    /// Copy one of CrossOver's runtimes into `runtimesDir` and return the installed runtime's name.
    ///
    /// DXMT is copied as a runtime of its OWN, with `x86_64-windows` at the root — not left where it sits
    /// inside the Wine tree (`lib/dxmt/`), where `standardDXMTLibDir` deliberately won't look: a DXMT
    /// nested under an unrelated subfolder isn't an install, it's a runtime's private copy.
    @discardableResult
    public func install(_ component: Component = .wine,
                        from path: String = defaultAppPath, into runtimesDir: URL) async throws -> String {
        let app = URL(fileURLWithPath: path)
        guard fileManager.fileExists(atPath: app.path) else { throw ImportError.notFound(path) }
        guard fileManager.fileExists(atPath: app.appendingPathComponent("Contents/Info.plist").path)
        else { throw ImportError.notACrossOverBundle }
        guard let version = Self.version(ofBundle: app) else { throw ImportError.noVersion }

        var source = app.appendingPathComponent("Contents/SharedSupport/CrossOver", isDirectory: true)
        if !component.sourceSubpath.isEmpty {
            source = source.appendingPathComponent(component.sourceSubpath, isDirectory: true)
        }
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: source.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { throw ImportError.noWineTree }

        let name = component.namePrefix + version
        let destination = runtimesDir.appendingPathComponent(name, isDirectory: true)
        try fileManager.createDirectory(at: runtimesDir, withIntermediateDirectories: true)
        try? fileManager.removeItem(at: destination)          // re-import replaces the same version

        // `cp -Rc` clones on APFS, so a multi-hundred-MB tree costs almost nothing and no extra disk;
        // `-R` is the fallback for a filesystem that can't (same pair BottleCloner uses).
        var result = try await runner.run(
            executable: URL(fileURLWithPath: "/bin/cp"),
            arguments: ["-Rc", source.path, destination.path],
            environment: [:], currentDirectory: nil)
        if !result.succeeded {
            try? fileManager.removeItem(at: destination)
            result = try await runner.run(
                executable: URL(fileURLWithPath: "/bin/cp"),
                arguments: ["-R", source.path, destination.path],
                environment: [:], currentDirectory: nil)
        }
        guard result.succeeded else {
            try? fileManager.removeItem(at: destination)
            throw ImportError.copyFailed(result.exitCode)
        }

        if component == .wine {
            // CrossOver's own `wine` / `wine64` are Perl dispatcher scripts, not Mach-O binaries;
            // `wineloader` is the real one. Silo's runtime discovery needs an executable at bin/wine64, so
            // point it there — the exact fix the shell script documents.
            let loader = destination.appendingPathComponent("bin/wineloader")
            guard fileManager.fileExists(atPath: loader.path) else {
                try? fileManager.removeItem(at: destination)  // half an install is worse than none
                throw ImportError.noLoader
            }
            let wine64 = destination.appendingPathComponent("bin/wine64")
            try? fileManager.removeItem(at: wine64)
            try fileManager.createSymbolicLink(atPath: wine64.path, withDestinationPath: "wineloader")
        }

        return name
    }
}

extension CrossOverWineImporter.ImportError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .notFound(let path):
            String(localized: "CrossOver isn't installed at \(path).")
        case .notACrossOverBundle:
            String(localized: "That doesn't look like a CrossOver app bundle.")
        case .noVersion:
            String(localized: "Couldn't read CrossOver's version.")
        case .noWineTree:
            String(localized: "This CrossOver doesn't contain a Wine tree where Silo expects one.")
        case .noLoader:
            String(localized: "CrossOver's Wine loader wasn't where Silo expects it — its layout may have changed.")
        case .copyFailed(let code):
            String(localized: "Copying CrossOver's Wine failed (cp exit \(code)).")
        }
    }
}
