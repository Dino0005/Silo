import Foundation

/// How a Windows game reaches **macOS** Steam instead of a Windows Steam client in its bottle.
///
/// The game is started by a stand-in `steam.exe` (Valve's Proton "steam helper", BSD) at the path Windows
/// games expect the client at: it fills the registry keys Steamworks looks up, then creates the game. When the
/// game loads `steamclient64.dll`, Silo's Wine patch 0003 (`SILO_LSTEAMCLIENT=1`) redirects its exports to
/// `lsteamclient`, which forwards Steamworks calls to the `steamclient.dylib` of the running macOS client.
/// Measured working with TEKKEN 8 on 2026-10-28 (offline) and 2026-11-03 (online).
public struct NativeSteamBridge: Sendable, Equatable {
    /// Where the stand-in client sits inside the bottle (and where games look for Steam).
    public static let shimWindowsPath = #"C:\Program Files (x86)\Steam\steam.exe"#
    /// The DLL routing the bridge needs: Valve's client DLLs native (they are only trampolines after patch
    /// 0003), `lsteamclient` builtin from the runtime.
    public static let dllOverrides = "steamclient=n;steamclient64=n;lsteamclient=b"

    /// macOS Steam's binaries folder, whose `steamclient.dylib` lsteamclient loads. Steam sets
    /// `STEAM_COMPAT_CLIENT_INSTALL_PATH` only for compatibility tools, NOT for the "macOS build" Silo's games
    /// pose as, so Silo always provides it (missing, lsteamclient asserts at `steamclient_main.c:382`).
    public var clientInstallPath: URL

    public init(clientInstallPath: URL) {
        self.clientInstallPath = clientInstallPath
    }

    /// `~/Library/Application Support/Steam/Steam.AppBundle/Steam/Contents/MacOS`.
    public static func defaultClientInstallPath(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent("Library/Application Support/Steam/Steam.AppBundle/Steam/Contents/MacOS",
                                    isDirectory: true)
    }

    /// The variables the bridge needs on top of a normal launch.
    public var environment: [String: String] {
        ["SILO_LSTEAMCLIENT": "1", "STEAM_COMPAT_CLIENT_INSTALL_PATH": clientInstallPath.path]
    }

    /// The wine arguments: the stand-in client, then the game (as a unix path, which it accepts) and its args.
    public func arguments(gameExe: URL, gameArguments: [String]) -> [String] {
        [Self.shimWindowsPath, gameExe.path] + gameArguments
    }
}
