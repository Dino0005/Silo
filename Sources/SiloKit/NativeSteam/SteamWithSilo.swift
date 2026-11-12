import AppKit
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
        let pid = try await runner.spawnDetached(
            executable: client, arguments: [],
            environment: Self.environment(hook: hook, compat: compat,
                                          toolsDir: steamRoot.appendingPathComponent("compatibilitytools.d")),
            currentDirectory: client.deletingLastPathComponent(),
            logURL: paths.logsDir.appendingPathComponent("steam-with-silo.log"))
        return .startedWithSilo(pid: pid)
    }
}

/// The launcher app the user keeps in the Dock instead of Steam's own: `~/Applications/Steam (Silo).app`, Steam's
/// icon, and a script that runs `Silo --start-steam`. A background agent (`LSUIElement`): it hands off and exits.
public struct SteamLauncherApp: Sendable {
    public static let fileName = "Steam (Silo).app"
    static let bundleIdentifier = "com.mikael.silo.steam-launcher"

    public let siloExecutable: URL

    public init(siloExecutable: URL) { self.siloExecutable = siloExecutable }

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

    public func launchScript() -> String {
        let quoted = "'" + siloExecutable.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        return "#!/bin/sh\n# Written by Silo: opens macOS Steam with Silo's library inside.\nexec \(quoted) \(SteamWithSilo.startFlag)\n"
    }

    /// Writes (or refreshes) the app in `directory`, with Steam's own icon when `/Applications/Steam.app` has one.
    @discardableResult
    public func write(into directory: URL, fileManager: FileManager = .default) throws -> URL {
        let app = directory.appendingPathComponent(Self.fileName, isDirectory: true)
        let macOS = app.appendingPathComponent("Contents/MacOS", isDirectory: true)
        let resources = app.appendingPathComponent("Contents/Resources", isDirectory: true)
        try fileManager.createDirectory(at: macOS, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: resources, withIntermediateDirectories: true)
        try Data(infoPlist().utf8).write(to: app.appendingPathComponent("Contents/Info.plist"), options: .atomic)
        let script = macOS.appendingPathComponent("launcher")
        try Data(launchScript().utf8).write(to: script, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
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
