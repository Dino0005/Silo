import Foundation
import Darwin

/// `Foundation.Process`-backed `ProcessRunning`.
///
/// `run` redirects child output to temp files (instead of pipes) to avoid pipe-buffer deadlock and
/// keep everything local to one background closure (Swift 6 concurrency-clean). The provided
/// environment is merged onto the current process environment so `PATH` etc. are preserved while
/// callers override `WINEPREFIX`, `WINEESYNC`, …
public struct SystemProcessRunner: ProcessRunning {
    public init() {}

    public func run(
        executable: URL,
        arguments: [String],
        environment: [String: String],
        currentDirectory: URL?
    ) async throws -> ProcessResult {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let result = try Self.runSync(
                        executable: executable, arguments: arguments,
                        environment: environment, currentDirectory: currentDirectory
                    )
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    @discardableResult
    public func spawnDetached(
        executable: URL,
        arguments: [String],
        environment: [String: String],
        currentDirectory: URL?,
        logURL: URL
    ) async throws -> Int32 {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let pid = try Self.spawnSync(
                        executable: executable, arguments: arguments,
                        environment: environment, currentDirectory: currentDirectory, logURL: logURL
                    )
                    continuation.resume(returning: pid)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    public func spawnIndependent(executable: URL, arguments: [String], environment: [String: String],
                                 currentDirectory: URL?, logURL: URL) async throws -> Int32 {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    continuation.resume(returning: try Self.spawnDisclaimed(
                        executable: executable, arguments: arguments, environment: environment,
                        currentDirectory: currentDirectory, logURL: logURL))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    public struct SpawnFailure: Error, Equatable { public let code: Int32 }

    /// posix_spawn in a new session with `responsibility_spawnattrs_setdisclaim` (libsystem, not in the public
    /// headers — looked up at run time; without it the child is spawned as before).
    private static func spawnDisclaimed(executable: URL, arguments: [String], environment: [String: String],
                                        currentDirectory: URL?, logURL: URL) throws -> Int32 {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fileManager.fileExists(atPath: logURL.path) { fileManager.createFile(atPath: logURL.path, contents: nil) }

        var attributes = posix_spawnattr_t(nil as OpaquePointer?)
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID))
        typealias Disclaim = @convention(c) (UnsafeMutablePointer<posix_spawnattr_t?>, Int32) -> Int32
        if let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_spawnattrs_setdisclaim") {
            _ = unsafeBitCast(symbol, to: Disclaim.self)(&attributes, 1)
        }

        var actions = posix_spawn_file_actions_t(nil as OpaquePointer?)
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 1, logURL.path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
        posix_spawn_file_actions_adddup2(&actions, 1, 2)
        if let currentDirectory { posix_spawn_file_actions_addchdir_np(&actions, currentDirectory.path) }

        let argv = ([executable.path] + arguments).map { strdup($0) } + [nil]
        let envp = mergedEnvironment(environment).map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { (argv + envp).forEach { free($0) } }
        var pid: pid_t = 0
        let status = posix_spawn(&pid, executable.path, &actions, &attributes, argv, envp)
        guard status == 0 else { throw SpawnFailure(code: status) }
        return pid
    }

    public func isRunning(pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        // kill(pid, 0): 0 → alive & signalable; EPERM → alive but not ours; ESRCH → gone.
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }

    public func terminate(pid: Int32) {
        guard pid > 0 else { return }
        kill(pid, SIGTERM)
    }

    // MARK: - Synchronous workers (run on a background queue)

    /// Loader-injection vectors stripped from the FINAL environment — both the inherited ambient env AND
    /// Silo's overrides — so neither a hostile ambient env nor a user's `EnvFlags.extra` escape hatch can
    /// force a dylib into the wine child. We do NOT strip `DYLD_FALLBACK_LIBRARY_PATH`/
    /// `DYLD_FALLBACK_FRAMEWORK_PATH` — Silo sets those explicitly (they only add *fallback* search paths,
    /// not forced loads), and Silo never legitimately sets a denylisted key, so stripping it is loss-free.
    ///
    /// `DYLD_LIBRARY_PATH` is here for a subtler reason than the other two. It isn't an injection vector,
    /// but dyld consults it BEFORE the system paths — ahead of the fallback list — so it silently defeats
    /// `Silo.siloDyldFallback`, which deliberately keeps `/usr/local/lib` out to avoid the
    /// "Class … is implemented in both" crash Homebrew's gtk3+gtk4 caused when `winegstreamer` loaded
    /// both. Inheriting it (launching from a Terminal, or from Xcode) would carry that path straight into
    /// the wine child. A Finder launch never would, but the protection shouldn't depend on how Silo was
    /// opened.
    static let injectionDenylist: Set<String> = [
        "DYLD_INSERT_LIBRARIES", "DYLD_FORCE_FLAT_NAMESPACE", "DYLD_LIBRARY_PATH",
    ]

    /// Core Animation debug switches dropped from the INHERITED environment only. Some developer shells
    /// (Xcode's, measured 2026-10-28) export them, and a wine child inheriting them hangs every D3DMetal
    /// game: D3DMetal configures its `CAMetalLayer` off the main thread (`setNonDefaultColorspace:`), the
    /// assertion makes Core Animation `abort()` while it holds its transaction lock, and the game's main
    /// thread then blocks on that lock forever — a transparent window. Unlike the injection set, an
    /// explicit override (a user's `EnvFlags.extra`) still goes through, for deliberate debugging.
    static let inheritedDebugDenylist: Set<String> = [
        "CA_ASSERT_MAIN_THREAD_TRANSACTIONS", "CA_DEBUG_TRANSACTIONS",
    ]

    static func mergedEnvironment(_ overrides: [String: String]) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        for key in inheritedDebugDenylist { env[key] = nil }   // before the overrides → an explicit one wins
        for (key, value) in overrides { env[key] = value }
        for key in injectionDenylist { env[key] = nil }   // applied LAST → also strips a user-set override
        // The ONE deliberate injection: Steam's own overlay / virtual-gamepad libraries for a game started from
        // macOS Steam (`NativeSteamBridge.overlayEnvKey`, already restricted to files in Steam's program folder;
        // `makePlan` strips the key from anything else, a user's `EnvFlags.extra` included).
        // Read from Silo's own overrides only — an inherited value is dropped like any other injection vector.
        env[NativeSteamBridge.overlayEnvKey] = nil
        if let libraries = overrides[NativeSteamBridge.overlayEnvKey], !libraries.isEmpty {
            env["DYLD_INSERT_LIBRARIES"] = libraries
        }
        return env
    }

    private static func runSync(
        executable: URL, arguments: [String],
        environment: [String: String], currentDirectory: URL?
    ) throws -> ProcessResult {
        let fileManager = FileManager.default
        let tmp = fileManager.temporaryDirectory
        let outURL = tmp.appendingPathComponent("silo-out-\(UUID().uuidString)")
        let errURL = tmp.appendingPathComponent("silo-err-\(UUID().uuidString)")
        fileManager.createFile(atPath: outURL.path, contents: nil)
        fileManager.createFile(atPath: errURL.path, contents: nil)
        defer {
            try? fileManager.removeItem(at: outURL)
            try? fileManager.removeItem(at: errURL)
        }

        let outHandle = try FileHandle(forWritingTo: outURL)
        let errHandle = try FileHandle(forWritingTo: errURL)
        defer { try? outHandle.close(); try? errHandle.close() }   // also closes if process.run() throws

        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = mergedEnvironment(environment)
        if let currentDirectory { process.currentDirectoryURL = currentDirectory }
        process.standardOutput = outHandle
        process.standardError = errHandle

        do { try process.run() } catch { throw RosettaCheck.translating(error) }
        process.waitUntilExit()

        let outData = (try? Data(contentsOf: outURL)) ?? Data()
        let errData = (try? Data(contentsOf: errURL)) ?? Data()
        return ProcessResult(exitCode: process.terminationStatus, standardOutput: outData, standardError: errData)
    }

    private static func spawnSync(
        executable: URL, arguments: [String],
        environment: [String: String], currentDirectory: URL?, logURL: URL
    ) throws -> Int32 {
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        if !fileManager.fileExists(atPath: logURL.path) {
            fileManager.createFile(atPath: logURL.path, contents: nil)
        }
        let logHandle = try FileHandle(forWritingTo: logURL)
        defer { try? logHandle.close() }   // also closes if process.run() throws
        logHandle.seekToEndOfFile()

        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = mergedEnvironment(environment)
        if let currentDirectory { process.currentDirectoryURL = currentDirectory }
        process.standardOutput = logHandle
        process.standardError = logHandle

        // Detached: we do not waitUntilExit. On macOS a child outlives its parent unless explicitly
        // signalled, so the game keeps running after Silo quits. The child dup's the log fd at spawn,
        // so closing our handle afterward is safe.
        do { try process.run() } catch { throw RosettaCheck.translating(error) }
        return process.processIdentifier
    }
}
