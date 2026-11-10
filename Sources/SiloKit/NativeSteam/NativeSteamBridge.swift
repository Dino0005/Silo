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

    public init(clientInstallPath: URL, nativeVCRuntime: [String] = []) {
        self.clientInstallPath = clientInstallPath
        self.nativeVCRuntime = nativeVCRuntime
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
        ["SILO_LSTEAMCLIENT": "1", "STEAM_COMPAT_CLIENT_INSTALL_PATH": clientInstallPath.path]
    }

    /// The wine arguments: the stand-in client, then the game (as a unix path, which it accepts) and its args.
    public func arguments(gameExe: URL, gameArguments: [String]) -> [String] {
        [Self.shimWindowsPath, gameExe.path] + gameArguments
    }
}
