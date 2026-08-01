import Foundation

/// A Media Foundation package the user has imported: the real Windows MF DLLs (32- and 64-bit) plus the
/// two registry exports that tell MF which CLSID handles which container/codec.
///
/// Silo neither ships nor downloads these — they're Microsoft's, and Microsoft doesn't distribute them
/// as a standalone package. The user supplies them from their own licensed Windows install (the same
/// arrangement every community MF fix for Wine/Proton uses). This type only describes a folder the user
/// pointed at, after checking it has everything the install recipe needs.
public struct MediaFoundationPackage: Sendable, Equatable {
    public let installDir: URL
    /// 64-bit DLLs — copied into the bottle's `drive_c/windows/system32`.
    public var system32: URL { installDir.appendingPathComponent("system32", isDirectory: true) }
    /// 32-bit DLLs — copied into `drive_c/windows/syswow64`. Needed because a Steam bottle can hold
    /// 32-bit games too (they run on DXMT rather than GPTK, but they live in the same bottle).
    public var syswow64: URL { installDir.appendingPathComponent("syswow64", isDirectory: true) }
    public var mfReg: URL { installDir.appendingPathComponent("mf.reg") }
    public var wmfReg: URL { installDir.appendingPathComponent("wmf.reg") }

    /// The nine modules the install recipe overrides to `native`. Sourced from the community
    /// `mf-fix-cx.sh`/`mf-install.sh` reference scripts rather than guessed, and confirmed on-device.
    public static let dllNames = [
        "colorcnv", "mf", "mferror", "mfplat", "mfplay",
        "mfreadwrite", "msmpeg2adec", "msmpeg2vdec", "sqmapi",
    ]

    /// The subset that also exposes COM classes and so must be `regsvr32`'d after copying. Registering
    /// `msmpeg2vdec` is what writes the H.264 decoder's `InputTypes`/`OutputTypes` metadata — without it
    /// Media Foundation finds no decoder for H.264 and the video stays black even though every DLL is in
    /// place. (Verified: this was the step missing from every failed attempt.)
    public static let comModules = ["colorcnv", "msmpeg2adec", "msmpeg2vdec"]
}

/// Imports a Media Foundation package into `Runtimes/media-foundation`.
///
/// Deliberately a single, unversioned install (unlike Wine/GPTK, which support several side by side):
/// there's only ever one set of MF DLLs to have, and no upgrade story that would benefit from keeping
/// an older one around.
public struct MediaFoundationImporter: Sendable {
    private let paths: AppPaths

    // No stored FileManager: it isn't Sendable, so holding one would make this struct non-Sendable.
    // Each method reaches for `.default` locally instead — the same shape GPTKImporter uses.
    public init(paths: AppPaths) {
        self.paths = paths
    }

    public enum ImportError: Error, Sendable, Equatable {
        /// The chosen folder is missing `system32/`, `syswow64/`, `mf.reg` or `wmf.reg`.
        case missingComponents([String])
        /// The folder has the right shape but not all nine DLLs in both architectures. Carries the
        /// missing entries as `"system32/mfplat.dll"`-style paths so the UI can say exactly what's absent.
        case missingDLLs([String])
    }

    /// The imported package, or nil if nothing valid is installed yet.
    public func installed() -> MediaFoundationPackage? {
        let pkg = MediaFoundationPackage(installDir: paths.mediaFoundationDir)
        return Self.validate(pkg, fileManager: .default) == nil ? pkg : nil
    }

    /// Check a candidate folder WITHOUT importing it — lets the UI reject a wrong pick immediately,
    /// naming what's missing, instead of failing halfway through a copy.
    public func inspect(_ folder: URL) throws -> MediaFoundationPackage {
        let candidate = MediaFoundationPackage(installDir: folder)
        if let error = Self.validate(candidate, fileManager: .default) { throw error }
        return candidate
    }

    /// Copy a validated folder into `Runtimes/media-foundation`, replacing any previous import.
    ///
    /// Staged then swapped, like `GPTKImporter`: a failure mid-copy must not leave a partial tree that
    /// `installed()` would then accept as usable.
    @discardableResult
    public func importPackage(from folder: URL) throws -> MediaFoundationPackage {
        let source = try inspect(folder)
        let installDir = paths.mediaFoundationDir
        let fileManager = FileManager.default

        try fileManager.createDirectory(at: paths.runtimesDir, withIntermediateDirectories: true)
        let staging = paths.runtimesDir
            .appendingPathComponent(".mf-import-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: staging) }
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)

        try fileManager.copyItem(at: source.system32,
                                 to: staging.appendingPathComponent("system32", isDirectory: true))
        try fileManager.copyItem(at: source.syswow64,
                                 to: staging.appendingPathComponent("syswow64", isDirectory: true))
        try fileManager.copyItem(at: source.mfReg, to: staging.appendingPathComponent("mf.reg"))
        try fileManager.copyItem(at: source.wmfReg, to: staging.appendingPathComponent("wmf.reg"))

        if fileManager.fileExists(atPath: installDir.path) { try fileManager.removeItem(at: installDir) }
        try fileManager.moveItem(at: staging, to: installDir)

        return MediaFoundationPackage(installDir: installDir)
    }

    public func remove() throws {
        let dir = paths.mediaFoundationDir
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: dir.path) { try fileManager.removeItem(at: dir) }
    }

    /// nil when the package is complete; otherwise the specific error. Shared by `installed()` (silent)
    /// and `inspect()` (throws), so both judge a package by exactly the same rules.
    static func validate(_ pkg: MediaFoundationPackage, fileManager: FileManager) -> ImportError? {
        var missing: [String] = []
        var isDir: ObjCBool = false
        for (url, label) in [(pkg.system32, "system32/"), (pkg.syswow64, "syswow64/")] {
            let exists = fileManager.fileExists(atPath: url.path, isDirectory: &isDir)
            if !exists || !isDir.boolValue { missing.append(label) }
        }
        for (url, label) in [(pkg.mfReg, "mf.reg"), (pkg.wmfReg, "wmf.reg")] {
            if !fileManager.fileExists(atPath: url.path) { missing.append(label) }
        }
        if !missing.isEmpty { return .missingComponents(missing) }

        // Case-insensitive: a package pulled off a real Windows install can carry `MFPlat.DLL` rather
        // than `mfplat.dll`, and macOS's default filesystem is case-insensitive anyway — rejecting those
        // would be a false negative. The copy step preserves whatever casing the source uses; Wine
        // resolves module names case-insensitively.
        var missingDLLs: [String] = []
        for (dir, label) in [(pkg.system32, "system32"), (pkg.syswow64, "syswow64")] {
            let present = Set((try? fileManager.contentsOfDirectory(atPath: dir.path))?
                .map { $0.lowercased() } ?? [])
            for dll in MediaFoundationPackage.dllNames where !present.contains("\(dll).dll") {
                missingDLLs.append("\(label)/\(dll).dll")
            }
        }
        return missingDLLs.isEmpty ? nil : .missingDLLs(missingDLLs)
    }
}
