import AppKit
import CryptoKit
import Foundation

/// Starting **macOS Steam with Silo's library inside** (`silo-steam-hook.dylib`, built from `Scripts/steam-hook`):
/// Steam then hands the front to a game app Silo starts (`GameAppLoader`) — without it a game started from macOS Steam
/// opens behind Steam's window.
///
/// The library can only ride along when Silo starts Steam's real client itself (`Steam.AppBundle/…/steam_osx`, no
/// hardened runtime): `/Applications/Steam.app` is the hardened bootstrapper, which drops `DYLD_INSERT_LIBRARIES`.
/// So the user opens Steam through a small launcher app Silo writes (`SteamLauncherApp`, chosen by the user over a
/// guard that restarts Steam, 2026-11-12), which runs `Silo --start-steam`. No Steam file is modified.
public struct SteamWithSilo: Sendable {
    public static let startFlag = "--start-steam"
    static let hookRelativePath = "Contents/Helpers/silo-steam-hook.dylib"
    /// Opt-in for the experimental compatibility layer in the library (`Scripts/steam-hook/compat.c`).
    static let compatEnvKey = "SILO_STEAM_COMPAT"

    public let paths: AppPaths
    private let runner: ProcessRunning
    private let steamRoot: URL
    private let hook: URL?

    public init(paths: AppPaths = .standard(), runner: ProcessRunning = SystemProcessRunner(),
                steamRoot: URL = FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent("Library/Application Support/Steam", isDirectory: true),
                appBundle: URL = Bundle.main.bundleURL) {
        self.paths = paths
        self.runner = runner
        self.steamRoot = steamRoot
        let hook = appBundle.appendingPathComponent(Self.hookRelativePath)
        self.hook = FileManager.default.fileExists(atPath: hook.path) ? hook : nil
    }

    /// Steam's real client.
    var client: URL { steamRoot.appendingPathComponent("Steam.AppBundle/Steam/Contents/MacOS/steam_osx") }
    static let bootstrapper = URL(fileURLWithPath: "/Applications/Steam.app")

    public enum Outcome: Equatable, Sendable {
        /// Steam was already running; it was brought to the front (the library can't be added to it now).
        case alreadyRunning
        /// Steam's client started with Silo's library.
        case startedWithSilo(pid: Int32)
        /// No client yet, or no library (a `swift run` build): Steam opened the usual way.
        case openedNormally
    }

    /// Pure: the environment Steam's client starts with.
    static func environment(hook: URL, compat: Bool, toolsDir: URL) -> [String: String] {
        var env = [NativeSteamBridge.overlayEnvKey: hook.path]
        if compat {
            env[compatEnvKey] = "1"
            env["STEAM_EXTRA_COMPAT_TOOLS_PATHS"] = toolsDir.path
        }
        return env
    }

    @MainActor
    public func start(compat: Bool = false) async throws -> Outcome {
        if let running = NSWorkspace.shared.runningApplications.first(where: {
            MacSteamProcess.isClient(path: $0.executableURL?.path ?? "")
        }) {
            running.activate()
            return .alreadyRunning
        }
        guard let hook, FileManager.default.isExecutableFile(atPath: client.path) else {
            _ = try await runner.run(executable: URL(fileURLWithPath: "/usr/bin/open"),
                                     arguments: [Self.bootstrapper.path], environment: [:], currentDirectory: nil)
            return .openedNormally
        }
        try? FileManager.default.createDirectory(at: paths.logsDir, withIntermediateDirectories: true)
        // Responsible for itself, like Steam opened from the Dock: as Silo's child it couldn't create Steam Input's
        // virtual gamepad.
        let pid = try await runner.spawnIndependent(
            executable: client, arguments: [],
            environment: Self.environment(hook: hook, compat: compat,
                                          toolsDir: steamRoot.appendingPathComponent("compatibilitytools.d")),
            currentDirectory: client.deletingLastPathComponent(),
            logURL: paths.logsDir.appendingPathComponent("steam-with-silo.log"))
        return .startedWithSilo(pid: pid)
    }
}

/// The launcher app the user keeps in the Dock instead of Steam's own: `~/Applications/Steam (Silo).app`, Steam's icon,
/// and a compiled launcher (`Scripts/steam-launcher`, `Contents/Helpers/SiloSteamLauncher` in Silo.app) that starts
/// Steam's client with Silo's library itself — Silo never opens. A real signed executable, not a script, so macOS can
/// list it in Privacy & Security: Steam inherits its grants, and without "Controllo del dispositivo e accesso ai dati"
/// Steam Input's virtual gamepad isn't created (measured 2026-11-13). A background agent (`LSUIElement`).
public struct SteamLauncherApp: Sendable {
    public static let fileName = "Steam (Silo).app"
    static let bundleIdentifier = "com.mikael.silo.steam-launcher"
    static let launcherRelativePath = "Contents/Helpers/SiloSteamLauncher"
    /// The privacy grant Steam inherits from the launcher ("Controllo del dispositivo e accesso ai dati (Eventi)").
    static let privacyService = "PostEvent"
    /// Ask macOS for that grant and exit, without starting Steam (`Scripts/steam-launcher`).
    static let requestAccessFlag = "--request-access"
    static let hookFileName = "silo-steam-hook"

    /// The compiled launcher and the library, both from Silo.app.
    public let launcher: URL
    public let hook: URL

    public init(launcher: URL, hook: URL) {
        self.launcher = launcher
        self.hook = hook
    }

    /// Both from the Silo.app at `appBundle`, or nil when it lacks either (a `swift run` build).
    public init?(appBundle: URL, fileManager: FileManager = .default) {
        let launcher = appBundle.appendingPathComponent(Self.launcherRelativePath)
        let hook = appBundle.appendingPathComponent(SteamWithSilo.hookRelativePath)
        guard fileManager.isExecutableFile(atPath: launcher.path), fileManager.fileExists(atPath: hook.path)
        else { return nil }
        self.init(launcher: launcher, hook: hook)
    }

    public func infoPlist() -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>CFBundleName</key><string>Steam (Silo)</string>
            <key>CFBundleDisplayName</key><string>Steam (Silo)</string>
            <key>CFBundleIdentifier</key><string>\(Self.bundleIdentifier)</string>
            <key>CFBundleExecutable</key><string>launcher</string>
            <key>CFBundleIconFile</key><string>AppIcon</string>
            <key>CFBundlePackageType</key><string>APPL</string>
            <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
            <key>CFBundleShortVersionString</key><string>1.0</string>
            <key>LSUIElement</key><true/>
            <key>LSMinimumSystemVersion</key><string>15.0</string>
        </dict>
        </plist>
        """
    }

    /// Whether the app in `directory` already has this launcher and library: then it is left alone, so its signature
    /// — and the privacy grant the user gave it — survive (macOS treats a re-signed ad-hoc app as a new one).
    public func isCurrent(in directory: URL, fileManager: FileManager = .default) -> Bool {
        let app = directory.appendingPathComponent(Self.fileName, isDirectory: true)
        let resources = app.appendingPathComponent("Contents/Resources")
        // The installed launcher carries its signature, so it never equals Silo's copy: compare what it was built from.
        guard let source = Self.digest(of: launcher) else { return false }
        return (try? String(contentsOf: resources.appendingPathComponent(Self.sourceFileName), encoding: .utf8)) == source
            && (try? String(contentsOf: resources.appendingPathComponent(Self.hookFileName), encoding: .utf8))
                == hook.path + "\n"
            && fileManager.fileExists(atPath: app.appendingPathComponent("Contents/_CodeSignature").path)
    }

    static let sourceFileName = "silo-launcher-source"

    /// SHA-256 of a file, hex.
    static func digest(of url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Writes (or refreshes) the app in `directory`; the caller signs it (`codesign --force --sign -`).
    @discardableResult
    public func write(into directory: URL, fileManager: FileManager = .default) throws -> URL {
        let app = directory.appendingPathComponent(Self.fileName, isDirectory: true)
        let macOS = app.appendingPathComponent("Contents/MacOS", isDirectory: true)
        let resources = app.appendingPathComponent("Contents/Resources", isDirectory: true)
        try fileManager.createDirectory(at: macOS, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: resources, withIntermediateDirectories: true)
        try Data(infoPlist().utf8).write(to: app.appendingPathComponent("Contents/Info.plist"), options: .atomic)
        let executable = macOS.appendingPathComponent("launcher")
        try? fileManager.removeItem(at: executable)
        try fileManager.copyItem(at: launcher, to: executable)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        try Data((hook.path + "\n").utf8).write(to: resources.appendingPathComponent(Self.hookFileName), options: .atomic)
        if let source = Self.digest(of: launcher) {
            try Data(source.utf8).write(to: resources.appendingPathComponent(Self.sourceFileName), options: .atomic)
        }
        if let icon = Self.steamIcon(fileManager: fileManager) {
            let target = resources.appendingPathComponent("AppIcon.icns")
            try? fileManager.removeItem(at: target)
            try fileManager.copyItem(at: icon, to: target)
        }
        return app
    }

    /// The `.icns` `/Applications/Steam.app` declares.
    static func steamIcon(fileManager: FileManager) -> URL? {
        let contents = SteamWithSilo.bootstrapper.appendingPathComponent("Contents")
        guard let data = fileManager.contents(atPath: contents.appendingPathComponent("Info.plist").path),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              var name = plist["CFBundleIconFile"] as? String else { return nil }
        if !name.hasSuffix(".icns") { name += ".icns" }
        let url = contents.appendingPathComponent("Resources/\(name)")
        return fileManager.fileExists(atPath: url.path) ? url : nil
    }
}
