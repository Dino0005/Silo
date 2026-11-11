import Foundation

/// Every Wine command of one launch from macOS Steam, with Steam's libraries (`NativeSteamBridge.overlayLibraries`)
/// added — so whichever command boots the bottle's wineserver first (the controllers' registry import, the
/// install script, the alt-loader whitelist…) passes them on to every process it starts, `winedevice.exe` included:
/// that process reads the controllers, so it is the one that needs `steamloader.dylib` for Steam Input's virtual
/// gamepad (measured 2026-11-11: with the libraries only on the game's own launch, the host had them and
/// `winedevice.exe`, started earlier by the registry import, didn't).
struct SteamLibrariesRunner: ProcessRunning {
    let base: ProcessRunning
    /// `DYLD_INSERT_LIBRARIES` value, carried as `NativeSteamBridge.overlayEnvKey` (`SystemProcessRunner` turns it
    /// into the real variable).
    let libraries: String

    func run(executable: URL, arguments: [String], environment: [String: String],
             currentDirectory: URL?) async throws -> ProcessResult {
        try await base.run(executable: executable, arguments: arguments,
                           environment: adding(environment), currentDirectory: currentDirectory)
    }

    func spawnDetached(executable: URL, arguments: [String], environment: [String: String],
                       currentDirectory: URL?, logURL: URL) async throws -> Int32 {
        try await base.spawnDetached(executable: executable, arguments: arguments,
                                     environment: adding(environment), currentDirectory: currentDirectory, logURL: logURL)
    }

    func isRunning(pid: Int32) -> Bool { base.isRunning(pid: pid) }
    func terminate(pid: Int32) { base.terminate(pid: pid) }

    private func adding(_ environment: [String: String]) -> [String: String] {
        var env = environment
        env[NativeSteamBridge.overlayEnvKey] = libraries
        return env
    }
}
