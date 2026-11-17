import Foundation

/// A Windows game's Steam **install script** (`install-script.vdf` / `installscript.vdf` in its install dir):
/// the first-launch steps Windows Steam runs before the game — Sony's PlayStation PC SDK runtime for TLOU II,
/// redistributables for others.
///
/// **Why Silo runs it (measured 2026-11-10):** macOS Steam treats a Silo-enabled game as a Mac build and never
/// runs a Windows install script, so TLOU II started with "The PlayStation(R) PC SDK Runtime cannot start
/// because it is missing". Only the `Run Process` section is honored; `Run Process On Uninstall` is ignored.
public struct SteamInstallScript: Sendable, Equatable {
    /// One `Run Process` entry: its processes, run in order.
    public struct Step: Sendable, Equatable {
        public let name: String
        public let commands: [Command]
    }

    /// `Process N` (a path, typically `%INSTALLDIR%\…`) with its optional `Command N` (the arguments).
    public struct Command: Sendable, Equatable {
        public let process: String
        public let arguments: String
    }

    public let steps: [Step]

    /// The file names Steam uses, looked for at the install root.
    public static let fileNames = ["install-script.vdf", "installscript.vdf"]

    /// The script in `installDir`, or nil when the game has none (or it doesn't parse).
    public static func load(installDir: URL, fileManager: FileManager = .default) -> SteamInstallScript? {
        for name in fileNames {
            let url = installDir.appendingPathComponent(name)
            guard fileManager.fileExists(atPath: url.path),
                  let text = (try? String(contentsOf: url, encoding: .utf8))
                    ?? (try? String(contentsOf: url, encoding: .isoLatin1)) else { continue }
            if let script = try? parse(text: text) { return script }
        }
        return nil
    }

    /// Pure: the `Run Process` steps of an install script's text.
    public static func parse(text: String) throws -> SteamInstallScript {
        let root = try KeyValuesParser().parse(text: text)
        let script = root["InstallScript"] ?? root
        var steps: [Step] = []
        for pair in script["Run Process"]?.pairs ?? [] {
            var commands: [Command] = []
            for index in 1...32 {
                guard let process = pair.value["Process \(index)"]?.stringValue, !process.isEmpty else { break }
                commands.append(Command(process: process,
                                        arguments: pair.value["Command \(index)"]?.stringValue ?? ""))
            }
            if !commands.isEmpty { steps.append(Step(name: pair.key, commands: commands)) }
        }
        return SteamInstallScript(steps: steps)
    }

    /// The wine argv (after the wine binary) for `command`: `%INSTALLDIR%` becomes the install dir's DOS path;
    /// a `.bat`/`.cmd` runs through `cmd /c`, an `.msi` through `msiexec /i`, anything else directly.
    static func wineArguments(for command: Command, installDir: URL) -> [String] {
        let dosDir = LaunchOrchestrator.dosPath(for: installDir)
        func expand(_ s: String) -> String {
            s.replacingOccurrences(of: "%INSTALLDIR%", with: dosDir, options: .caseInsensitive)
                .replacingOccurrences(of: "%ROOTDRIVE%", with: "C:", options: .caseInsensitive)
        }
        let process = expand(command.process)
        let arguments = splitArguments(expand(command.arguments))
        switch (process as NSString).pathExtension.lowercased() {
        case "bat", "cmd": return ["cmd", "/c", process] + arguments
        case "msi": return ["msiexec", "/i", process] + arguments
        default: return [process] + arguments
        }
    }

    /// Splits a Windows command line on spaces, keeping `"quoted parts"` together (quotes removed).
    static func splitArguments(_ line: String) -> [String] {
        var out: [String] = [], current = "", quoted = false, started = false
        for ch in line {
            if ch == "\"" { quoted.toggle(); started = true }
            else if ch == " " && !quoted {
                if started { out.append(current); current = ""; started = false }
            } else { current.append(ch); started = true }
        }
        if started { out.append(current) }
        return out
    }
}

/// Runs a game's install script once per bottle: each step that exits 0 is recorded in
/// `<prefix>/.silo-installscript.json` and never runs again; a failing step is retried on the next launch,
/// at most `maxAttempts` times in all, so a step that can't work under Wine doesn't slow every launch.
public struct SteamInstallScriptRunner: Sendable {
    public static let maxAttempts = 2
    private let runner: ProcessRunning

    public init(runner: ProcessRunning) { self.runner = runner }

    /// What happened to each step, for the launch log.
    public enum Outcome: Sendable, Equatable {
        case ran(step: String, exitCode: Int32)
        case skipped(step: String)
    }

    struct Record: Codable, Equatable {
        var done: [String: [String]] = [:]
        var attempts: [String: [String: Int]] = [:]
    }

    static func recordURL(prefix: URL) -> URL { prefix.appendingPathComponent(".silo-installscript.json") }

    @discardableResult
    public func run(appID: Int, installDir: URL, prefix: URL, wine: URL,
                    fileManager: FileManager = .default) async -> [Outcome] {
        guard let script = SteamInstallScript.load(installDir: installDir, fileManager: fileManager),
              !script.steps.isEmpty else { return [] }
        let url = Self.recordURL(prefix: prefix)
        var record = (try? JSONDecoder().decode(Record.self, from: Data(contentsOf: url))) ?? Record()
        let key = String(appID)
        var outcomes: [Outcome] = []
        for step in script.steps {
            let tries = record.attempts[key]?[step.name] ?? 0
            if record.done[key, default: []].contains(step.name) || tries >= Self.maxAttempts {
                outcomes.append(.skipped(step: step.name))
                continue
            }
            var exit: Int32 = 0
            for command in step.commands where exit == 0 {
                let result = try? await runner.run(
                    executable: wine,
                    arguments: SteamInstallScript.wineArguments(for: command, installDir: installDir),
                    environment: Silo.msyncWineEnvironment(prefix: prefix, wine: wine),
                    currentDirectory: installDir)
                exit = result?.exitCode ?? -1
            }
            if exit == 0 { record.done[key, default: []].append(step.name) }
            record.attempts[key, default: [:]][step.name] = tries + 1
            outcomes.append(.ran(step: step.name, exitCode: exit))
        }
        if let data = try? JSONEncoder().encode(record) { try? data.write(to: url, options: .atomic) }
        return outcomes
    }
}
