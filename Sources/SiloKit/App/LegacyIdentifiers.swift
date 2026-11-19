import Foundation

/// What an earlier Silo left under upstream's identifiers (`com.mikael.silo…`, until 2026-11-19), moved to the fork's
/// own (`Silo.bundleID`). Bundles Silo writes — game hosts and apps, shortcuts, "Steam (Silo)" — are rewritten under the
/// new identifiers by their own code (which still recognizes the old ones as Silo's); what is left here is what nothing
/// else would carry over: the preferences, and the guard's LaunchAgent with its label.
public enum LegacyIdentifiers {
    public static let appID = "com.mikael.silo"
    /// Set in the new preferences once the old ones were copied, so a later run never copies them again.
    static let migratedKey = "migratedFromLegacyIdentifier"

    /// Copies the preferences of `legacy` (the old domain) into `defaults` once — the onboarding flag, the library's
    /// filter and tile style, window frames. A key the new domain already has is kept. Returns the keys copied.
    @discardableResult
    public static func migratePreferences(into defaults: UserDefaults = .standard,
                                          legacy: [String: Any]? = UserDefaults.standard.persistentDomain(forName: appID))
        -> [String] {
        guard !defaults.bool(forKey: migratedKey) else { return [] }
        defer { defaults.set(true, forKey: migratedKey) }
        var copied: [String] = []
        for (key, value) in legacy ?? [:] where defaults.object(forKey: key) == nil {
            defaults.set(value, forKey: key)
            copied.append(key)
        }
        return copied.sorted()
    }

    static let guardLabel = appID + ".native-steam-guard"
    static let launcherIdentifier = appID + ".steam-launcher"

    /// Stops and removes the guard's LaunchAgent written under the old label (the new one is installed by
    /// `NativeSteamSetup.repointIfMoved`, which finds it missing), and clears the privacy grant macOS still lists for
    /// the old "Steam (Silo)" — else Privacy & Security shows two of them. Nothing when there is no old guard.
    @discardableResult
    public static func retireGuard(home: URL, runner: ProcessRunning, fileManager: FileManager = .default) async -> Bool {
        let agent = home.appendingPathComponent("Library/LaunchAgents/\(guardLabel).plist")
        guard fileManager.fileExists(atPath: agent.path) else { return false }
        _ = try? await runner.run(executable: URL(fileURLWithPath: "/bin/launchctl"),
                                  arguments: ["bootout", "gui/\(getuid())/\(guardLabel)"], environment: [:], currentDirectory: nil)
        try? fileManager.removeItem(at: agent)
        _ = try? await runner.run(executable: URL(fileURLWithPath: "/usr/bin/tccutil"),
                                  arguments: ["reset", SteamLauncherApp.privacyService, launcherIdentifier],
                                  environment: [:], currentDirectory: nil)
        return true
    }
}
