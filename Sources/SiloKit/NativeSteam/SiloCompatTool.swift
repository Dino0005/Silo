import Foundation

/// Silo as a **Steam compatibility tool** for macOS Steam: `compatibilitytools.d/silo-proton` in Steam's folder, the same
/// format Proton and NotProton use (`compatibilitytool.vdf` + `toolmanifest.vdf` + a `run` script). macOS Steam only
/// reads it with its compatibility layer on — Silo's library inside Steam (`Scripts/steam-hook`) — and
/// `STEAM_EXTRA_COMPAT_TOOLS_PATHS`, both set by "Steam (Silo)" (`Scripts/steam-launcher`).
///
/// A game mapped to "Silo" is a **Windows** game to Steam: Windows depots and DLC, and Steam Input's virtual gamepad
/// (measured on SOULCALIBUR VI, 2026-11-12/13: through the appinfo "macOS game" route the DLC failed to load and the
/// DualSense got no virtual pad). Steam runs `run waitforexitandrun <game exe> [args]`; the script hands it to
/// `Silo --steam-launch`, exactly like the `silo-launch` entry of the appinfo route. Steam's legacy install script
/// (`iscriptevaluator.exe`) is skipped: Silo runs the game's install script itself at launch (`SteamInstallScriptRunner`).
public struct SiloCompatTool: Sendable {
    /// The tool's id in Steam. It contains "proton" on purpose: only then does Steam resolve a Windows game's Steam
    /// Cloud roots (`WinAppDataLocal`, `WinSavedGames`, …) for a compat-tool launch — into the game's
    /// `steamapps/compatdata/<appid>/pfx/drive_c/users/steamuser` (`SteamCloudSaves.prepareCompatUser` links that to
    /// the classic bottle). Measured 2026-11-15: as "silo", every rule failed ("ResolvePath (WinSavedGames, …) failed");
    /// as the lab copy "silo-proton" (2026-11-13), FATAL FURY's saves synced. The name Steam shows stays "Silo".
    public static let name = "silo-proton"
    public static let displayName = "Silo"
    /// Earlier ids of this tool: removed when the tool is written, so the guard remaps their games to `name`.
    static let legacyNames = ["silo"]

    public let siloExecutable: URL

    public init(siloExecutable: URL) { self.siloExecutable = siloExecutable }

    public static func directory(steamRoot: URL) -> URL {
        steamRoot.appendingPathComponent("compatibilitytools.d/\(name)", isDirectory: true)
    }

    public func compatibilityToolVDF() -> String {
        """
        "compatibilitytools"
        {
          "compat_tools"
          {
            "\(Self.name)"
            {
              "install_path" "."
              "display_name" "\(Self.displayName)"
              "from_oslist" "windows"
              "to_oslist" "macos"
            }
          }
        }

        """
    }

    public func toolManifestVDF() -> String {
        """
        "manifest"
        {
          "version" "2"
          "commandline" "/run %verb%"
        }

        """
    }

    public func runScript() -> String {
        let silo = "'" + siloExecutable.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        return """
        #!/bin/sh
        # Written by Silo: Steam's compatibility tool "Silo". Steam runs: run|waitforexitandrun <game exe> [args...]
        verb="$1"; shift
        case "$verb" in run|waitforexitandrun) ;; *) exit 0 ;; esac
        case "$1" in *iscriptevaluator.exe) exit 0 ;; esac
        exe="$1"; shift
        cd "$STEAM_COMPAT_INSTALL_PATH" || exit 1
        exec \(silo) \(NativeSteamInstaller.launchFlag) --appid "$STEAM_COMPAT_APP_ID" --exe "${exe#"$STEAM_COMPAT_INSTALL_PATH"/}" "$@"

        """
    }

    /// Writes (or refreshes) the tool in Steam's `compatibilitytools.d`.
    @discardableResult
    public func write(steamRoot: URL, fileManager: FileManager = .default) throws -> URL {
        let dir = Self.directory(steamRoot: steamRoot)
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(compatibilityToolVDF().utf8).write(to: dir.appendingPathComponent("compatibilitytool.vdf"), options: .atomic)
        try Data(toolManifestVDF().utf8).write(to: dir.appendingPathComponent("toolmanifest.vdf"), options: .atomic)
        let run = dir.appendingPathComponent("run")
        try Data(runScript().utf8).write(to: run, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: run.path)
        // The tool under an earlier id goes — only if Silo wrote it (its run script says so).
        for legacy in Self.legacyNames {
            let old = steamRoot.appendingPathComponent("compatibilitytools.d/\(legacy)", isDirectory: true)
            if (try? String(contentsOf: old.appendingPathComponent("run"), encoding: .utf8))?
                .contains("# Written by Silo") == true {
                try? fileManager.removeItem(at: old)
            }
        }
        return dir
    }
}
