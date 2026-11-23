import Foundation

/// The depth fix (Correzione profondità, `EnvFlags.depthFix`) is God of War's (2018): the game redraws its G-buffer
/// with an EQUAL depth test against its depth prepass, and on Metal a few pixels round differently between the two
/// passes and fail it — white specks on characters. GPTK: Silo's d3d11 proxy (`Proxy/d3d11-depth-fix`) turns that test
/// into GREATER_EQUAL; DXMT: its own `d3d11.depthEqualAsGreaterEqual` (Silo's DXMT patch 0003). On another game the
/// same change can draw things through walls, so it is offered and applied for God of War only (user, 2026-11-23) —
/// the Steam release and the GOG one alike: both start `GoW.exe`.
public enum DepthFix {
    /// God of War's Steam app — how a Steam game's settings know it before an exe is resolved.
    public static let steamAppID = 1_593_500
    static let executableName = "GoW.exe"

    /// Whether `exe` is God of War's, from Steam or GOG.
    public static func isGodOfWar(_ exe: URL) -> Bool {
        exe.lastPathComponent.caseInsensitiveCompare(executableName) == .orderedSame
    }

    /// Whether the settings offer the switch: a Steam game by its app id, a manual game by its exe or the Steam app
    /// it is linked to (for its artwork).
    public static func offered(steamAppID appID: Int?, exe: URL?) -> Bool {
        appID == steamAppID || exe.map(isGodOfWar) == true
    }

    /// Whether this launch applies it: switched on, and the game being started is God of War.
    public static func applies(_ flags: EnvFlags, gameExe: URL) -> Bool {
        flags.depthFix && isGodOfWar(gameExe)
    }
}
