import Foundation

/// Apple's own XPC services left behind in a **non-Steam** game's host coalition after the game has ended —
/// the other thing (besides Wine leftovers, see `LaunchLeftovers`) that keeps a game's Dock tile up.
///
/// **Measured 2026-10-12 on God of War (manual bottle), on DXMT and on GPTK alike:** the game quit normally,
/// Silo's post-exit cleanup left no Wine process at all, yet the tile stayed for minutes. `lsappinfo` showed
/// the host as `(exited-with-subordinates)` with a coalition made only of `/System/Library/…/XPCServices/…`
/// processes started with the game — `MTLCompilerService`, `ColorSyncXPCAgent`,
/// `SafariPlatformSupport.Helper` ("AutoFill (God of War)") and `SetStoreUpdateService`, all children of
/// launchd. Killing them released the registration at once. `SIGTERM` ended only the Safari helper; the
/// others needed `SIGKILL`. Steam games don't show this: with the client running, those services land in
/// the Steam host's coalition instead (measured: two `SetStoreUpdateService` there), which stays up anyway.
///
/// What this touches, by construction (user's decision, 2026-10-12: non-Steam games only, "e nient'altro"):
/// only members of the coalition of an **exited** host registration with the given bundle id, only
/// children of launchd, and only executables inside an `.xpc` bundle under `/System/`. These are per-app
/// instances; launchd starts a fresh one for whoever asks next. Never a Wine process, never a game.
public struct HostSystemServices: Sendable {
    let runner: any ProcessRunning

    public init(runner: any ProcessRunning) {
        self.runner = runner
    }

    /// One app registration from `lsappinfo list`.
    struct Registration: Equatable, Sendable {
        var bundleID: String?
        /// `(exited-with-subordinates)`: the app's own process is gone, other coalition members live on.
        var hasExited = false
        var coalition: [Int32] = []
    }

    /// A process as `ps -o pid=,ppid=,comm=` reports it.
    struct ProcessInfo: Equatable, Sendable {
        let pid: Int32
        let ppid: Int32
        let path: String
    }

    // MARK: - Pure

    /// Split `lsappinfo list` into registrations. Each starts at a line like `98) "God of War" ASN:…`.
    static func parseRegistrations(_ text: String) -> [Registration] {
        var result: [Registration] = []
        var current: Registration?
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if isRegistrationHeader(line) {
                if let current { result.append(current) }
                current = Registration()
                continue
            }
            guard current != nil else { continue }
            if line.hasPrefix("bundleID=\"") {
                current?.bundleID = String(line.dropFirst("bundleID=\"".count).prefix { $0 != "\"" })
            } else if line.hasPrefix("pid = ") {
                current?.hasExited = line.contains("(exited-with-subordinates)")
            } else if line.hasPrefix("coalition:"),
                      let open = line.firstIndex(of: "{"), let close = line.lastIndex(of: "}"), open < close {
                current?.coalition = line[line.index(after: open)..<close]
                    .split(separator: " ").compactMap { Int32($0) }
            }
        }
        if let current { result.append(current) }
        return result
    }

    /// `NN) "Name" ASN:…` — a number, `)`, then a quoted name.
    private static func isRegistrationHeader(_ line: String) -> Bool {
        guard let paren = line.firstIndex(of: ")"), paren > line.startIndex,
              line[..<paren].allSatisfy(\.isNumber) else { return false }
        return line[line.index(after: paren)...].trimmingCharacters(in: .whitespaces).hasPrefix("\"")
    }

    /// Parse `ps -o pid=,ppid=,comm=` (the path may contain spaces).
    static func parsePS(_ text: String) -> [ProcessInfo] {
        text.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard fields.count == 3, let pid = Int32(fields[0]), let ppid = Int32(fields[1]) else { return nil }
            return ProcessInfo(pid: pid, ppid: ppid, path: String(fields[2]).trimmingCharacters(in: .whitespaces))
        }
    }

    /// An Apple XPC service: an executable inside an `.xpc` bundle under `/System/`.
    static func isAppleXPCService(_ path: String) -> Bool {
        path.hasPrefix("/System/") && path.contains(".xpc/Contents/MacOS/")
    }

    /// The coalition members of every EXITED registration of `bundleID` (a still-running host yields
    /// nothing — its game is playing).
    static func candidatePIDs(in registrations: [Registration], bundleID: String) -> [Int32] {
        registrations
            .filter { $0.bundleID == bundleID && $0.hasExited }
            .flatMap(\.coalition)
    }

    /// Of `candidates`, the ones that are launchd-spawned Apple XPC services — the only ones ever stopped.
    static func targets(candidates: [Int32], processes: [ProcessInfo]) -> [Int32] {
        let wanted = Set(candidates)
        return processes
            .filter { wanted.contains($0.pid) && $0.ppid == 1 && isAppleXPCService($0.path) }
            .map(\.pid)
    }

    // MARK: - Asking the machine

    /// Stop the Apple XPC services still holding the exited host `bundleID`'s registration. Best-effort:
    /// any probe that fails stops nothing. Returns how many were stopped.
    @discardableResult
    public func stopLeftoverServices(ofHost bundleID: String) async -> Int {
        guard let list = try? await runner.run(
            executable: URL(fileURLWithPath: "/usr/bin/lsappinfo"), arguments: ["list"],
            environment: [:], currentDirectory: nil)
        else { return 0 }
        let candidates = Self.candidatePIDs(in: Self.parseRegistrations(list.stdoutString), bundleID: bundleID)
        let targets = await currentTargets(candidates)
        guard !targets.isEmpty else { return 0 }

        // SIGTERM first; most of these ignore it (measured), so SIGKILL what is still there a second later —
        // re-checked first, so a pid recycled in the meantime by an unrelated process is never hit.
        for pid in targets { kill(pid, SIGTERM) }
        try? await Task.sleep(for: .seconds(1))
        for pid in await currentTargets(targets) { kill(pid, SIGKILL) }
        return targets.count
    }

    /// Of `candidates`, those that are right now launchd-spawned Apple XPC services.
    private func currentTargets(_ candidates: [Int32]) async -> [Int32] {
        guard !candidates.isEmpty,
              let ps = try? await runner.run(
                executable: URL(fileURLWithPath: "/bin/ps"),
                arguments: ["-o", "pid=,ppid=,comm=", "-p", candidates.map(String.init).joined(separator: ",")],
                environment: [:], currentDirectory: nil)
        else { return [] }
        return Self.targets(candidates: candidates, processes: Self.parsePS(ps.stdoutString))
    }
}
