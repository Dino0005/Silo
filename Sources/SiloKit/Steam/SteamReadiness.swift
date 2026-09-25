import Foundation

/// Tells whether the bottle's Steam client is ready for a co-resident game's `SteamAPI_Init` — replacing
/// the old fixed cold-start sleep with the actual signal.
///
/// When the Windows Steam client comes up it advertises itself in the registry under
/// `[Software\Valve\Steam\ActiveProcess]` with a non-zero `pid` (plus the client-DLL paths) — and that is
/// exactly what the Steamworks API in a game reads to connect. In a Wine prefix the HKCU hive is the text
/// file `user.reg`, so "Steam is ready" == that key carries a non-zero pid there. A kqueue watch on
/// `user.reg` lets the launch resolve the instant Steam writes it, with no polling and no fixed wait.
enum SteamReadiness {
    /// HKCU registry hive inside a Wine prefix.
    static func userReg(prefix: URL) -> URL { prefix.appendingPathComponent("user.reg") }

    /// The most recent moment Steam visibly did something in the bottle, or nil if it hasn't.
    ///
    /// Used to tell "still starting up" from "hung": the readiness failsafe restarts its countdown whenever
    /// this moves, so a long update doesn't expire it. Two directories are enough — the client's own folder
    /// (touched constantly through sign-in) and `package/`, where a self-update lands its archives.
    ///
    /// Deliberately NOT `user.reg`: measured on-device, Steam writes it once, when it registers. That makes
    /// it the perfect readiness signal and a useless liveness one.
    ///
    /// Three sources, because no single one covers both ways Steam can be slow.
    ///
    /// A directory's mtime moves when a file inside is CREATED, renamed or removed — not when an existing
    /// one is rewritten in place. That makes `package/` right for a self-update, which lands fresh
    /// archives, and useless for an ordinary sign-in: measured second by second, that one rewrites files
    /// it already has (`logs/cef_log.txt`, `logs/webhelper.txt`, `config/config.vdf`), so the directories
    /// never move.
    ///
    /// Hence the log FILES as well. `logs/` is written continuously from the first moment to the last,
    /// with gaps of a few seconds, and goes quiet the instant sign-in completes — the clearest "still
    /// working" signal Steam gives. It holds about forty files, so this is forty `stat`s per tick: nothing
    /// like walking the client tree, which has thousands.
    static func lastActivity(prefix: URL, fileManager: FileManager = .default) -> Date? {
        let steam = prefix
            .appendingPathComponent("drive_c", isDirectory: true)
            .appendingPathComponent("Program Files (x86)", isDirectory: true)
            .appendingPathComponent("Steam", isDirectory: true)
        let logs = steam.appendingPathComponent("logs", isDirectory: true)
        let logFiles = (try? fileManager.contentsOfDirectory(at: logs, includingPropertiesForKeys: nil))
            ?? []
        let candidates = [steam, steam.appendingPathComponent("package", isDirectory: true)] + logFiles
        return candidates
            .compactMap { try? fileManager.attributesOfItem(atPath: $0.path)[.modificationDate] as? Date }
            .max()
    }

    /// Whether `prefix`'s Steam has registered a live `ActiveProcess` pid.
    static func isReady(prefix: URL) -> Bool {
        guard let text = try? String(contentsOf: userReg(prefix: prefix), encoding: .utf8) else { return false }
        return hasActivePid(text)
    }

    /// Pure parse: does a Wine `user.reg` carry a non-zero `"pid"` under the `ActiveProcess` section?
    /// (Section detection is lenient about backslash escaping — `[Software\\Valve\\Steam\\ActiveProcess]`.)
    static func hasActivePid(_ userReg: String) -> Bool {
        var inActiveProcess = false
        for rawLine in userReg.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {                       // a new section header
                inActiveProcess = line.contains("ActiveProcess")
                continue
            }
            if inActiveProcess, line.hasPrefix("\"pid\"=dword:") {
                let hex = line.dropFirst("\"pid\"=dword:".count)
                return (UInt64(hex, radix: 16) ?? 0) != 0
            }
        }
        return false
    }

    // MARK: - Stale pid after a force-quit

    /// Pure: `userReg` with the `ActiveProcess` pid set to zero, or nil when there is nothing to change
    /// (no such section, no pid line, or already zero). Only the value is rewritten — the line keeps its
    /// place, and every other key, section and the section's `#time=` stamp are left as they were.
    static func clearingActivePid(_ userReg: String) -> String? {
        var inActiveProcess = false
        var changed = false
        var lines = userReg.components(separatedBy: "\n")
        for i in lines.indices {
            let line = lines[i].trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                inActiveProcess = line.contains("ActiveProcess")
                continue
            }
            if inActiveProcess, line.hasPrefix("\"pid\"=dword:") {
                let hex = line.dropFirst("\"pid\"=dword:".count).trimmingCharacters(in: .whitespacesAndNewlines)
                guard (UInt64(hex, radix: 16) ?? 0) != 0 else { return nil }
                let trailingCR = lines[i].hasSuffix("\r") ? "\r" : ""
                lines[i] = "\"pid\"=dword:00000000" + trailingCR
                changed = true
                break
            }
        }
        return changed ? lines.joined(separator: "\n") : nil
    }

    /// Zero a pid left behind by a Steam that died without shutting down (a force-quit, a crash). Returns
    /// whether it changed anything.
    ///
    /// **Why:** readiness is "the `ActiveProcess` pid in `user.reg` is non-zero", and a Steam that is
    /// killed never gets to reset it. The next launch starts a fresh client — which makes the wineserver
    /// live — and `awaitSteamReady` then finds the OLD pid and declares Steam ready at once, so the game
    /// starts before the client exists (observed 2026-09-24 21:03, after a force-quit).
    ///
    /// **Only with the bottle down.** A live wineserver owns the registry and flushes its own copy over the
    /// file, so an edit then would be both pointless and racy. With no server there is also no Steam, so a
    /// non-zero pid can only be stale — no judgement needed. Best-effort: any failure leaves the file as is.
    @discardableResult
    static func clearStalePid(prefix: URL, fileManager: FileManager = .default) -> Bool {
        guard !WineServerProbe.isLive(prefix: prefix, fileManager: fileManager) else { return false }
        let url = userReg(prefix: prefix)
        guard let text = try? String(contentsOf: url, encoding: .utf8),
              let cleared = clearingActivePid(text) else { return false }
        return (try? cleared.write(to: url, atomically: true, encoding: .utf8)) != nil
    }
}
