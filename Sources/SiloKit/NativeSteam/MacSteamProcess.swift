import Darwin
import Foundation

/// Whether **macOS Steam** is running. While it is, Silo never starts the Windows Steam client of its classic bottles
/// (user, 2026-11-12): two Steams signed in to one account fight over the session, and a Windows game handed to the
/// wrong one runs on the wrong path (measured: SOULCALIBUR VI, started from macOS Steam, ended; its relaunch opened
/// Silo, which brought up the Windows client in `SteamBottleMF` and ran the game there).
///
/// macOS Steam is its real client, `Steam.AppBundle/Steam/Contents/MacOS/steam_osx` — the one process that runs
/// however Steam was started (`/Applications/Steam.app` is only the bootstrapper that execs it).
public enum MacSteamProcess {
    static let clientPathSuffix = "/Steam.AppBundle/Steam/Contents/MacOS/steam_osx"

    /// Pure: whether an executable path is macOS Steam's client.
    static func isClient(path: String) -> Bool { path.hasSuffix(clientPathSuffix) }

    /// Whether any running process is macOS Steam's client.
    public static func isRunning() -> Bool {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return false }
        var pids = [pid_t](repeating: 0, count: Int(count) + 32)
        let filled = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard filled > 0 else { return false }
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        for pid in pids.prefix(Int(filled)) where pid > 0 {
            let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
            guard length > 0 else { continue }
            let bytes = buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }
            if isClient(path: String(decoding: bytes, as: UTF8.self)) { return true }
        }
        return false
    }
}
