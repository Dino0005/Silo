import Foundation

/// Canonical filesystem locations. App state (config, logs, runtimes) lives under
/// `~/Library/Application Support/Silo`; the **bottles** (Steam + manual) live under `bottlesRoot`, which
/// defaults to `supportDir` but can be relocated to another disk / external drive.
public struct AppPaths: Sendable, Hashable {
    public let supportDir: URL
    /// The folder that holds the bottle prefixes (`SteamBottle` + `ManualBottles`). Defaults to
    /// `supportDir`; the user can move it elsewhere (persisted via `BottlesLocation`, read at startup so
    /// every derived path points at the right place from the first frame).
    public let bottlesRoot: URL

    public init(supportDir: URL, bottlesRoot: URL? = nil) {
        self.supportDir = supportDir
        self.bottlesRoot = bottlesRoot ?? supportDir
    }

    /// The standard location under the user's Application Support directory, honouring a persisted
    /// bottles-location override.
    public static func standard(fileManager: FileManager = .default) -> AppPaths {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Silo", isDirectory: true)
        return AppPaths(supportDir: base, bottlesRoot: BottlesLocation.read(supportDir: base))
    }

    public var runtimesDir: URL { supportDir.appendingPathComponent("Runtimes", isDirectory: true) }
    /// The single imported Media Foundation package (see `MediaFoundationImporter`). Unversioned, unlike
    /// the Wine/GPTK/DXMT runtimes alongside it — there's only ever one set of MF DLLs to hold.
    public var mediaFoundationDir: URL {
        runtimesDir.appendingPathComponent("media-foundation", isDirectory: true)
    }
    public var logsDir: URL { supportDir.appendingPathComponent("Logs", isDirectory: true) }
    public var configFile: URL { supportDir.appendingPathComponent("config.json") }
    /// Scratch dir for downloaded app-update archives (the inline updater stages the `.zip` here).
    public var updatesDir: URL { supportDir.appendingPathComponent("Updates", isDirectory: true) }
    /// Temp dir for a setup run's artifact downloads (`SetupDownloads`) — under `supportDir` so downloads can
    /// start the moment "Set up" is pressed, BEFORE the bottle prefix / its `drive_c` exists. NOT a cache: it's
    /// wiped at the start of every run and removed when setup finishes, so a stale installer is never reused.
    public var setupDownloadsTmp: URL { supportDir.appendingPathComponent("SetupDownloads", isDirectory: true) }

    // MARK: - Bottles location

    /// Bottles live somewhere other than the default (Application Support).
    public var bottlesRelocated: Bool {
        bottlesRoot.standardizedFileURL != supportDir.standardizedFileURL
    }

    /// Whether the configured bottles root is currently usable — its volume is mounted. (A custom root on
    /// an external drive becomes unreachable when the drive is ejected.) The root itself need not exist yet
    /// (a fresh custom location), only its parent.
    public var bottlesRootReachable: Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: bottlesRoot.path)
            || fm.fileExists(atPath: bottlesRoot.deletingLastPathComponent().path)
    }

    /// The bottle directory names that relocate together (everything under `bottlesRoot`): the single shared
    /// Steam bottle plus the manual-games parent.
    public static let bottleDirNames = ["SteamBottle", "ManualBottles"]

    // MARK: - Steam bottle (one shared prefix hosting the Steam client + its games)

    /// The shared Wine prefix — the Steam client + its games co-resident under GPTK/D3DMetal. Historically
    /// named `SteamBottle`.
    public var steamBottle: URL { bottlesRoot.appendingPathComponent("SteamBottle", isDirectory: true) }
    /// The Media Foundation twin of `steamBottle` — a clone with the real Windows MF DLLs installed.
    ///
    /// A whole second bottle rather than a switch inside one, because the two configurations can't
    /// coexist: the native MF stack that lets some titles play their video stops others from starting
    /// (measured on-device). Cloned copy-on-write, so it costs little disk, and both bottles point at the
    /// same Steam library — games stay installed once, and the library still shows one entry each.
    public var steamBottleMF: URL {
        bottlesRoot.appendingPathComponent("SteamBottleMF", isDirectory: true)
    }

    /// Which of the two Steam bottles a path refers to. They're identical in layout — the MF one is a
    /// clone — so everything below is the same shape with a different root, and a separate log so two
    /// clients can never overwrite each other's output.
    public enum SteamBottleKind: String, Sendable, CaseIterable {
        case standard
        case mediaFoundation
    }

    /// The prefix for either bottle. Named distinctly from the `steamBottle` property it returns, so
    /// there's no chance of a call resolving to the wrong one.
    public func steamBottleRoot(_ kind: SteamBottleKind = .standard) -> URL {
        kind == .standard ? steamBottle : steamBottleMF
    }

    /// The Windows Steam install inside the bottle (`drive_c/Program Files (x86)/Steam`).
    public func steamBottleClientDir(_ kind: SteamBottleKind = .standard) -> URL {
        steamBottleRoot(kind)
            .appendingPathComponent("drive_c", isDirectory: true)
            .appendingPathComponent("Program Files (x86)", isDirectory: true)
            .appendingPathComponent("Steam", isDirectory: true)
    }

    /// `steam.exe` inside the bottle.
    public func steamBottleExe(_ kind: SteamBottleKind = .standard) -> URL {
        steamBottleClientDir(kind).appendingPathComponent("steam.exe")
    }

    /// The directory holding Steam's CEF binaries inside the bottle. The leaf name varies by Steam version
    /// (currently `cef.win7x64`), so callers that need the exact `steamwebhelper.exe` glob this dir's
    /// children rather than assume the leaf — see `SteamBottle.webHelpers()`.
    public func steamBottleCEFDir(_ kind: SteamBottleKind = .standard) -> URL {
        steamBottleClientDir(kind).appendingPathComponent("bin/cef")
    }

    /// The bottle's client log. Distinct per bottle: one file for two clients would interleave their
    /// output and make either one unreadable.
    public func steamBottleLog(_ kind: SteamBottleKind = .standard) -> URL {
        logsDir.appendingPathComponent(
            kind == .standard ? "steam-bottle.log" : "steam-bottle-mf.log")
    }

    // Unchanged spellings for the standard bottle, so existing call sites keep working.
    public var steamBottleClientDir: URL { steamBottleClientDir(.standard) }
    public var steamBottleExe: URL { steamBottleExe(.standard) }
    public var steamBottleCEFDir: URL { steamBottleCEFDir(.standard) }
    public var steamBottleLog: URL { steamBottleLog(.standard) }

    /// Parent of the per-game isolated bottles used by manual (non-Steam) games.
    public var manualBottlesDir: URL { bottlesRoot.appendingPathComponent("ManualBottles", isDirectory: true) }

    /// A manual game's own isolated Wine prefix (its private registry + `drive_c`), keyed by its id.
    public func manualBottle(_ id: UUID) -> URL {
        manualBottlesDir.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    /// Per-game launch log file (`<appID>.log`).
    public func log(forAppID appID: Int) -> URL {
        logsDir.appendingPathComponent("\(appID).log")
    }

    /// Launch log for a manual (non-Steam) game, keyed by its stable id.
    public func manualLog(_ id: UUID) -> URL {
        logsDir.appendingPathComponent("manual-\(id.uuidString).log")
    }
}
