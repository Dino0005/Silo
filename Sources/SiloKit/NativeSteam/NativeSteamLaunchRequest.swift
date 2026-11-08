import Foundation

/// What macOS Steam asks for when it starts a Windows game's "macOS build": Steam runs the `silo-launch`
/// script from the game's install dir with the arguments of Silo's launch entry (`AppInfoPatcher`), followed by
/// whatever the user typed in the game's Launch Options.
public struct NativeSteamLaunchRequest: Sendable, Equatable {
    public var appID: Int
    /// The game's install folder (Steam's working directory for the launch).
    public var installDir: URL
    /// The Windows executable Steam lists for the game, when the launch entry names one.
    public var executable: URL?
    /// Extra arguments for the game (Steam's Launch Options box).
    public var gameArguments: [String]

    public enum Failure: Error, Equatable {
        case missingAppID
    }

    /// - Parameters:
    ///   - arguments: the process arguments AFTER `NativeSteamInstaller.launchFlag`.
    ///   - workingDirectory: the process's current directory — Steam starts the launcher in the install dir.
    ///   - environment: Steam's `SteamAppId` backs up a missing `--appid`.
    public static func parse(_ arguments: [String], workingDirectory: URL,
                             environment: [String: String]) throws -> NativeSteamLaunchRequest {
        var appID: Int?
        var exe: String?
        var rest: [String] = []
        var i = 0
        while i < arguments.count {
            let arg = arguments[i]
            let value = i + 1 < arguments.count ? arguments[i + 1] : nil
            switch arg {
            // A trailing flag with no value (the Launch Options box ends with "--exe") is just dropped — it
            // must not swallow the loop or eat a real argument.
            case "--appid":
                appID = value.flatMap(Int.init)
                i += value == nil ? 1 : 2
            case "--exe":
                exe = value
                i += value == nil ? 1 : 2
            default:
                rest.append(arg)
                i += 1
            }
        }
        guard let id = appID ?? environment["SteamAppId"].flatMap(Int.init) else { throw Failure.missingAppID }
        let executable = exe.flatMap { $0.isEmpty ? nil : $0 }.map {
            workingDirectory.appendingPathComponent($0.replacingOccurrences(of: "\\", with: "/"))
        }
        return NativeSteamLaunchRequest(appID: id, installDir: workingDirectory, executable: executable,
                                        gameArguments: rest)
    }
}
