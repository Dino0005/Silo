import Foundation

/// The DualSense options of Silo's Wine (Silo patches 0019–0035, MacGameFix's modules): `winebus.so` and
/// `winecoreaudio.so` read them from `~/Library/Application Support/Silo/DualSense` — `pad.d/<Steam app id>.conf` for
/// the game (they know it by `SteamAppId`), then `pad.conf` for every game; the first line with a key wins. Silo writes
/// the game's file from its settings before each launch, so what the game runs with is what its settings say.
///
/// They matter only for a pad Wine reads itself, that is with Steam Input off for the game; with it on, the game gets
/// Steam's virtual pad. A manual game has no Steam app id, so only `pad.conf` applies to it.
public enum DualSenseOptions {
    /// The folder the modules read (Silo patch 0035): `DualSense` in Silo's support folder, which is
    /// `~/Library/Application Support/Silo` — the path the patch has fixed.
    public static func folder(supportDir: URL) -> URL {
        supportDir.appendingPathComponent("DualSense", isDirectory: true)
    }

    /// Pure: the game's file, one `key=value` a line. Every key is written, the defaults too, so the file alone says
    /// what the game gets and `pad.conf` can't override it.
    static func lines(for flags: EnvFlags) -> [String] {
        ["bluetooth=" + (flags.dualSenseBluetoothAsWired ? "wired" : "off"),
         "rumble=" + (flags.dualSenseRumbleOnActuators ? "haptics" : "motors"),
         "xinput=" + (flags.dualSenseAsXInput ? "pad" : "off")]
    }

    /// The defaults for a game with no file of its own (a manual game): a Bluetooth pad shown as wired.
    static let everyGameLines = ["bluetooth=wired"]

    /// Writes `pad.d/<appID>.conf` for the game, and `pad.conf` when there is none. Returns the log line.
    @discardableResult
    public static func write(_ flags: EnvFlags, appID: Int, folder: URL,
                             fileManager: FileManager = .default) -> String {
        let header = "# Written by Silo before each launch, from the game's settings (Controllers). Edits are replaced.\n"
        let gameDir = folder.appendingPathComponent("pad.d", isDirectory: true)
        do {
            try fileManager.createDirectory(at: gameDir, withIntermediateDirectories: true)
            let every = folder.appendingPathComponent("pad.conf")
            if !fileManager.fileExists(atPath: every.path) {
                try Data((header + everyGameLines.joined(separator: "\n") + "\n").utf8).write(to: every, options: .atomic)
            }
            let text = header + lines(for: flags).joined(separator: "\n") + "\n"
            try Data(text.utf8).write(to: gameDir.appendingPathComponent("\(appID).conf"), options: .atomic)
            return "dualsense: " + lines(for: flags).joined(separator: ", ")
        } catch {
            return "dualsense: options not written (\(error.localizedDescription))"
        }
    }
}
