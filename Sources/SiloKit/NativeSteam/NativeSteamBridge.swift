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
    /// Microsoft's VC++ runtime DLLs in the bottle's `system32` (`nativeVCRuntime(inSystem32:)`), loaded
    /// native-first for a game started this way.
    ///
    /// **Why (measured 2026-11-10 on FATAL FURY):** its Unreal bootstrap, once its Steam check passes through the
    /// bridge, reads the VERSION resource of `msvcp140_2.dll` & co. — and Wine's default builtin-first order
    /// hands it the builtin's resources, so it asks for "Microsoft Visual C++ 2015-2022 Redistributable (x64)"
    /// and never starts the game. With `n,b` it reads Microsoft's files and starts the Shipping exe. This is
    /// NotProton 1.1.9's rule (CLAUDE.md, Phase 2). The classic mode is left as it is (no such prompt there).
    public var nativeVCRuntime: [String]

    /// Steam's libraries for the game process — `steamloader.dylib` (Steam Input's virtual gamepad, among others)
    /// and `gameoverlayrenderer.dylib` (Shift+Tab) — from Steam's `STEAM_DYLD_INSERT_LIBRARIES` (measured
    /// 2026-11-11: Steam passes both to the "macOS build" Silo's games pose as). They are loaded into every Wine
    /// process of the launch — `winedevice.exe` reads the controllers, not the game — and into the game's
    /// alt-loader host, the way NotProton exports them (`compat_run.sh`).
    public var overlayLibraries: [URL]
    /// Steam's own variables for the game (`Steam*` — `SteamOverlayGameId`, `Steam3Master`, `SteamGameId`… — and
    /// `SDL_*`), handed to the alt-loader host at exec: the host is started by LaunchServices, not by Steam, so it
    /// would otherwise lack them, and the overlay reads them as soon as it loads (measured 2026-11-11: loaded into
    /// TLOU's host without them, Shift+Tab did nothing).
    public var steamEnvironment: [String: String]

    public init(clientInstallPath: URL, nativeVCRuntime: [String] = [], overlayLibraries: [URL] = [],
                steamEnvironment: [String: String] = [:]) {
        self.clientInstallPath = clientInstallPath
        self.nativeVCRuntime = nativeVCRuntime
        self.overlayLibraries = overlayLibraries
        self.steamEnvironment = steamEnvironment.filter {
            ($0.key.hasPrefix("Steam") || $0.key.hasPrefix("SDL_")) && $0.key != Self.virtualGamepadInfoKey
        }
    }

    /// Steam's description of the virtual pads it made for the game. Never passed on: with it, SDL presents Steam's
    /// virtual pad as the physical one (a DualSense, 054c/0ce6 version 0) and the game got no input; without it the
    /// pad stays an Xbox 360 one (045e/028e) and works (measured on SOULCALIBUR VI, 2026-11-12).
    public static let virtualGamepadInfoKey = "SteamVirtualGamepadInfo"

    /// Lets SDL (Wine's SDL bus) show Steam's virtual pad to the game.
    public static let allowVirtualGamepadKey = "SDL_GAMECONTROLLER_ALLOW_STEAM_VIRTUAL_GAMEPAD"

    /// Pure: the variables to drop from Steam's environment before Wine inherits it. Always the virtual-pad
    /// description; and, when Steam made no virtual pad for this game (Steam Input off for it, so no description),
    /// the permission to see Steam's virtual pad too — Steam keeps one from an earlier game, an Xbox 360 pad, and the
    /// game took it over the real DualSense (Xbox glyphs on TEKKEN 8, 2026-11-13).
    public static func environmentToDrop(_ environment: [String: String]) -> [String] {
        environment[virtualGamepadInfoKey] == nil
            ? [virtualGamepadInfoKey, allowVirtualGamepadKey] : [virtualGamepadInfoKey]
    }

    /// The environment key that carries `overlayLibraries` to `SystemProcessRunner`, which turns it into
    /// `DYLD_INSERT_LIBRARIES` — the only way that variable reaches a Wine child.
    public static let overlayEnvKey = "SILO_DYLD_INSERT_LIBRARIES"

    /// The entries of Steam's `STEAM_DYLD_INSERT_LIBRARIES` that are `.dylib` files inside Steam's program
    /// folder and exist — nothing else is ever injected.
    public static func overlayLibraries(fromSteam value: String?, clientInstallPath: URL,
                                        fileManager: FileManager = .default) -> [URL] {
        let folder = clientInstallPath.standardizedFileURL.path.hasSuffix("/")
            ? clientInstallPath.standardizedFileURL.path : clientInstallPath.standardizedFileURL.path + "/"
        return (value ?? "").split(separator: ":").compactMap { entry in
            let url = URL(fileURLWithPath: String(entry)).standardizedFileURL
            guard url.path.hasPrefix(folder), !url.path.dropFirst(folder.count).contains("/"),
                  url.pathExtension == "dylib", fileManager.fileExists(atPath: url.path) else { return nil }
            return url
        }
    }

    /// What the game's alt-loader host needs at exec (`open --env`): the same libraries, and Steam's variables
    /// for them.
    public var hostEnvironment: [String: String] {
        guard !overlayLibraries.isEmpty else { return [:] }
        var env = steamEnvironment
        env["DYLD_INSERT_LIBRARIES"] = overlayLibraries.map(\.path).joined(separator: ":")
        return env
    }

    /// `dllOverrides` plus `<vc dlls>=n,b` for `nativeVCRuntime`.
    public var dllRouting: String {
        nativeVCRuntime.isEmpty ? Self.dllOverrides
            : Self.dllOverrides + ";" + nativeVCRuntime.joined(separator: ",") + "=n,b"
    }

    /// The VC++ runtime modules (`msvcp140*`, `vcruntime140*`, `concrt140*`) in `system32` that are real files,
    /// not Wine builtins or placeholders — by module name, sorted.
    public static func nativeVCRuntime(inSystem32 dir: URL, fileManager: FileManager = .default) -> [String] {
        let names = (try? fileManager.contentsOfDirectory(atPath: dir.path)) ?? []
        return names.filter { name in
            let lower = name.lowercased()
            guard lower.hasSuffix(".dll"),
                  ["msvcp140", "vcruntime140", "concrt140"].contains(where: { lower.hasPrefix($0) }) else { return false }
            guard let handle = try? FileHandle(forReadingFrom: dir.appendingPathComponent(name)) else { return false }
            defer { try? handle.close() }
            return !isWineModule((try? handle.read(upToCount: 96)) ?? Data())
        }
        .map { String($0.dropLast(4)).lowercased() }
        .sorted()
    }

    /// Wine marks its builtin and placeholder PE files right after the DOS header (offset 64).
    static func isWineModule(_ head: Data) -> Bool {
        guard head.count >= 64 + 16 else { return false }
        let text = String(decoding: head[head.startIndex + 64 ..< head.startIndex + min(head.count, 96)], as: UTF8.self)
        return text.hasPrefix("Wine builtin DLL") || text.hasPrefix("Wine placeholder DLL")
    }

    /// `~/Library/Application Support/Steam/Steam.AppBundle/Steam/Contents/MacOS`.
    public static func defaultClientInstallPath(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent("Library/Application Support/Steam/Steam.AppBundle/Steam/Contents/MacOS",
                                    isDirectory: true)
    }

    /// The variables the bridge needs on top of a normal launch.
    public var environment: [String: String] {
        var env = ["SILO_LSTEAMCLIENT": "1", "STEAM_COMPAT_CLIENT_INSTALL_PATH": clientInstallPath.path]
        if !overlayLibraries.isEmpty { env[Self.overlayEnvKey] = overlayLibraries.map(\.path).joined(separator: ":") }
        return env
    }

    /// The wine arguments: the stand-in client, then the game (as a unix path, which it accepts) and its args.
    public func arguments(gameExe: URL, gameArguments: [String]) -> [String] {
        [Self.shimWindowsPath, gameExe.path] + gameArguments
    }
}
