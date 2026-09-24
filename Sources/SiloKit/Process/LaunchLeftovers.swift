import Foundation

/// The processes a bottle still has alive, split into "a game is running" and "only leftovers".
///
/// **Why this exists.** A launch leaves processes behind that outlive the game: Wine's default-desktop
/// owner (`explorer.exe /desktop`, created by the FIRST game of a bottle session and kept until the
/// wineserver stops) and a game's own helpers (e.g. Sony's `crs-handler.exe`). Measured 2026-09-24: while
/// any of them lives, macOS keeps the launch's app registration alive — so the game's Dock tile stays,
/// labelled "running in background", long after the game is gone. The tile is honest; it just answers a
/// question the user didn't ask.
///
/// **What it is NOT.** This does not watch a game's lifecycle — Silo launches detached and never owns it
/// (Phase 4). It is a *pull*: ask the bottle what is alive right now, when someone wants to know.
///
/// **Attribution is per BOTTLE, not per game, and that is a measured limit rather than a shortcut.** The
/// leftover that keeps a tile alive is Wine's desktop owner, whose command line names no game; nothing in
/// it ties it to the launch that happened to create it. So the honest unit is "this prefix has leftovers
/// and no game running in it".
public struct LaunchLeftovers: Sendable {
    private let runner: ProcessRunning

    public init(runner: ProcessRunning) {
        self.runner = runner
    }

    public struct Process: Sendable, Equatable, Identifiable {
        public let id: Int32
        public let command: String
        public init(id: Int32, command: String) {
            self.id = id
            self.command = command
        }
    }

    /// What a bottle currently has alive.
    public struct Census: Sendable, Equatable {
        /// Processes running one of the caller's known game executables — a game is playing.
        public let games: [Process]
        /// Everything else that isn't the bottle's own plumbing or the Steam client: the tile-holders.
        public let leftovers: [Process]

        /// The only state in which offering to clean up is safe *and* useful.
        public var isOnlyLeftovers: Bool { games.isEmpty && !leftovers.isEmpty }
    }

    /// Wine's own per-prefix plumbing. Killing these is what *Stop all bottle processes* is for; they are
    /// not leftovers of a launch, and taking them out from under a live prefix is how a bottle gets hurt.
    static let plumbing = [
        "services.exe", "winedevice.exe", "plugplay.exe", "svchost.exe", "rpcss.exe",
        "wineserver", "conhost.exe", "start.exe",
    ]

    /// The co-resident Steam client and its tree. Left strictly alone: the whole point of this action is
    /// "clear the game's remains, keep Steam" — and in the shared bottle the client's virtual-desktop
    /// `explorer.exe /desktop=Silo,…` is part of that tree, which is why the match below is on `/desktop=`
    /// and not on the image name (both explorers share it).
    static let steamClient = [
        "steam.exe", "steamwebhelper.exe", "steamservice.exe", "gameoverlayui", "steamerrorreporter",
    ]

    // MARK: - Pure classification

    /// `pid command…` lines from `ps -eo pid,command`, ignoring its header and anything unparsable.
    static func parsePS(_ output: String) -> [Process] {
        output.split(separator: "\n").compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let parts = trimmed.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            guard parts.count == 2, let pid = Int32(parts[0]) else { return nil }
            return Process(id: pid, command: String(parts[1]))
        }
    }

    /// `lsof -t` output: one pid per line.
    static func parsePIDs(_ output: String) -> Set<Int32> {
        Set(output.split(whereSeparator: \.isNewline).compactMap { Int32($0.trimmingCharacters(in: .whitespaces)) })
    }

    /// Split the prefix's processes. `gameExecutables` are the absolute unix paths (or file names) of the
    /// games Silo knows about: a process running one of them is a game, not a leftover.
    static func classify(
        all: [Process], inPrefix pids: Set<Int32>, gameExecutables: [String]
    ) -> Census {
        var games: [Process] = []
        var leftovers: [Process] = []
        for process in all where pids.contains(process.id) {
            let command = process.command
            // An ADOPTED game reports the host binary as its command line, not the game's exe (measured
            // 2026-09-24: the window-owning Spider-Man process showed
            // `…/HostApps/1817070/….app/Contents/MacOS/SiloGameHost`). So this test comes first and is
            // unconditional: without it a game that is actually playing reads as a leftover, and the
            // offered "cleanup" would kill it. A test pins exactly that.
            if command.contains(GameHostBundle.executableName)
                || gameExecutables.contains(where: { !$0.isEmpty && command.contains($0) }) {
                games.append(process)
            } else if plumbing.contains(where: { command.contains($0) })
                        || steamClient.contains(where: { command.contains($0) })
                        || command.contains("/desktop=") {
                continue                      // the bottle's own plumbing, or the client's tree
            } else {
                leftovers.append(process)
            }
        }
        return Census(games: games, leftovers: leftovers)
    }

    // MARK: - Asking the machine

    /// Census `prefix` right now. Empty on any failure: this only ever *offers* a cleanup, so a probe that
    /// can't answer must offer nothing rather than guess.
    public func census(prefix: URL, gameExecutables: [String]) async -> Census {
        guard let dir = WineServerProbe.serverDirectory(for: prefix) else {
            return Census(games: [], leftovers: [])
        }
        // Every process attached to a prefix holds files in its wineserver directory — the same identity
        // `WineServerProbe` keys liveness on. That is what attributes a process to THIS bottle; a command
        // line can't (a Windows path names no prefix).
        guard let pidList = try? await runner.run(
            executable: URL(fileURLWithPath: "/usr/sbin/lsof"),
            arguments: ["-t", "+D", dir.path], environment: [:], currentDirectory: nil),
              let processes = try? await runner.run(
                executable: URL(fileURLWithPath: "/bin/ps"),
                arguments: ["-eo", "pid,command"], environment: [:], currentDirectory: nil)
        else { return Census(games: [], leftovers: []) }

        return Self.classify(all: Self.parsePS(processes.stdoutString),
                             inPrefix: Self.parsePIDs(pidList.stdoutString),
                             gameExecutables: gameExecutables)
    }

    /// Terminate the given processes. `SIGTERM` first — these are Wine processes and Wine's loader handles
    /// it — and that is deliberately all: escalating to `SIGKILL` on a whim risks cutting a write, and the
    /// worst case here is a tile that lingers a little longer.
    @discardableResult
    public func stop(_ processes: [Process]) async -> Int {
        var stopped = 0
        for process in processes {
            if kill(process.id, SIGTERM) == 0 { stopped += 1 }
        }
        return stopped
    }
}
