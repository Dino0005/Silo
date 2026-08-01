import Foundation

/// Duplicates a Wine prefix, for configurations that can't coexist in one bottle.
///
/// The Media Foundation install is the case that motivated this: the native MF stack that makes some
/// titles' video play stops others from starting at all (measured on-device — Soulcalibur VI needs it,
/// Devil May Cry 5 and Mortal Kombat break under it), and no subset of the modules splits the
/// difference. So the two configurations get a bottle each.
///
/// Copies with `cp -Rc`, which on APFS uses `clonefile(2)`: the copy is near-instant and initially
/// occupies no extra space, since both prefixes share the underlying blocks until they diverge. Only
/// what actually changes — the registry, the MF DLLs, whatever Steam writes later — costs anything. A
/// 3.7 GB Steam bottle clones in well under a second.
///
/// `-c` fails on filesystems without cloning (a bottles root moved to an exFAT external drive, say), so
/// a plain `cp -R` is the fallback. Same result, just slower and at full size.
///
/// Nothing here rewrites the copy's contents, and nothing needs to: a prefix's `dosdevices/c:` is a
/// RELATIVE link (`../drive_c`), and `system.reg` holds no absolute path to the prefix itself.
/// Verified on a real 15k-file Steam bottle before this was written. The Steam library links (`x:`,
/// `u:`) are absolute and are meant to stay that way — both bottles should see the same installed
/// games, which is what keeps the library one entry per game and the disk cost flat.
public struct BottleCloner: Sendable {
    private let runner: ProcessRunning

    public init(runner: ProcessRunning) {
        self.runner = runner
    }

    public enum CloneError: Error, Sendable, Equatable {
        case sourceMissing(URL)
        case destinationExists(URL)
        case copyFailed(status: Int32, stderr: String)
    }

    /// True when `destination` looks like a Wine prefix (has a `drive_c`).
    public static func isPrefix(_ url: URL, fileManager: FileManager = .default) -> Bool {
        var isDir: ObjCBool = false
        let exists = fileManager.fileExists(
            atPath: url.appendingPathComponent("drive_c").path, isDirectory: &isDir)
        return exists && isDir.boolValue
    }

    /// Clone `source` to `destination`.
    ///
    /// Refuses to overwrite: an existing destination has to be removed by the caller, deliberately. A
    /// bottle can hold a Steam login and save games, so silently replacing one is not a decision this
    /// type should take on its own.
    public func clone(from source: URL, to destination: URL) async throws {
        let fileManager = FileManager.default
        guard Self.isPrefix(source, fileManager: fileManager) else {
            throw CloneError.sourceMissing(source)
        }
        guard !fileManager.fileExists(atPath: destination.path) else {
            throw CloneError.destinationExists(destination)
        }
        try fileManager.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)

        // Clone-on-write first; plain recursive copy if the filesystem can't do it.
        let cloned = try await copy(source, destination, cloneOnWrite: true)
        if cloned.succeeded { return }

        // `cp -Rc` may have left a partial tree behind before failing — clear it, or the retry trips
        // over its own leftovers.
        try? fileManager.removeItem(at: destination)

        let plain = try await copy(source, destination, cloneOnWrite: false)
        guard plain.succeeded else {
            try? fileManager.removeItem(at: destination)
            throw CloneError.copyFailed(status: plain.exitCode, stderr: plain.stderrString)
        }
    }

    private func copy(_ source: URL, _ destination: URL, cloneOnWrite: Bool) async throws -> ProcessResult {
        try await runner.run(
            executable: URL(fileURLWithPath: "/bin/cp"),
            arguments: [cloneOnWrite ? "-Rc" : "-R", source.path, destination.path],
            environment: [:],
            currentDirectory: nil)
    }
}
