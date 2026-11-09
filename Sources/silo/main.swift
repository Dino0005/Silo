import AppKit
import Foundation
import SiloKit

setbuf(stdout, nil)   // unbuffered so progress shows immediately under non-TTY

// Headless smoke mode for CI / sandboxes that can't open a window.
if CommandLine.arguments.contains("--smoke")
    || ProcessInfo.processInfo.environment["SILO_SMOKE"] == "1" {
    print("\(Silo.appName) \(Silo.version) — smoke ok")
} else if let idx = CommandLine.arguments.firstIndex(of: NativeSteamInstaller.launchFlag) {
    // macOS Steam's Play on a Windows game (the `silo-launch` script): launch headless and stay alive until the
    // game ends — Steam treats this process as the game. Nothing reaches the user from stdout here, so every
    // step goes to Logs/native-steam-launch.log.
    let paths = AppPaths.standard()
    let logURL = paths.logsDir.appendingPathComponent("native-steam-launch.log")
    try? FileManager.default.createDirectory(at: paths.logsDir, withIntermediateDirectories: true)
    let log: (String) -> Void = { line in
        let stamped = "\(Date().formatted(.iso8601)) \(line)\n"
        if let handle = try? FileHandle(forWritingTo: logURL) {
            handle.seekToEndOfFile(); handle.write(Data(stamped.utf8)); try? handle.close()
        } else {
            try? Data(stamped.utf8).write(to: logURL)
        }
    }
    let args = Array(CommandLine.arguments[(idx + 1)...])
    log("request: \(args) cwd: \(FileManager.default.currentDirectoryPath)")
    do {
        let request = try NativeSteamLaunchRequest.parse(
            args, workingDirectory: URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true),
            environment: ProcessInfo.processInfo.environment)
        exit(try await NativeSteamLauncher(paths: paths).run(request, log: log))
    } catch {
        log("failed: \(error)")
        exit(1)
    }
} else if let idx = CommandLine.arguments.firstIndex(of: "--native-steam-enable") {
    // Dev/on-device: wire macOS Steam to Silo for the given app ids — the SteamNative bottle (cloned on first
    // use), the launcher script in every Steam library, and the appinfo.vdf edits (Steam must be closed).
    let paths = AppPaths.standard()
    let ids = CommandLine.arguments[(idx + 1)...].compactMap { UInt32($0) }
    let steamRunning: @Sendable () -> Bool = {
        !NSRunningApplication.runningApplications(withBundleIdentifier: "com.valvesoftware.steam").isEmpty
    }
    do {
        guard !steamRunning() else { print("Quit Steam first."); exit(1) }
        let bottle = NativeSteamBottle(paths: paths, runner: SystemProcessRunner())
        let backend = await ConfigStore(paths: paths).load().backend
        let wine = try? BottleResolver(paths: paths).steam(backend: .gptk, config: backend).wineBinary
        try await bottle.ensureBottle(source: bottle.bridgeSource(wine: wine))
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path + "/"
        let users = paths.nativeSteamBottle.appendingPathComponent("drive_c/users")
        let user = (try? FileManager.default.contentsOfDirectory(atPath: users.path))?
            .first { $0 != "Public" && !$0.hasPrefix(".") }
        let userFolder = user.map { users.appendingPathComponent($0).standardizedFileURL.path }
        // --no-cloud: leave the games' Steam Cloud rules alone (protect a Windows install without moving its saves).
        let cloud = CommandLine.arguments.contains("--no-cloud") ? nil
            : userFolder.flatMap { $0.hasPrefix(home) ? String($0.dropFirst(home.count)) : nil }
        let installer = NativeSteamInstaller(
            steamRoot: FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/Steam"),
            backupDir: paths.supportDir.appendingPathComponent("NativeSteam"), isSteamRunning: steamRunning)
        let siloExe = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
        let launcher = try installer.installLauncher(siloExecutable: siloExe)
        print("launcher -> \(siloExe.path)")
        launcher.installed.forEach { print("  installed \($0.path)") }
        launcher.unreachable.forEach { print("  unreachable library \($0.path)") }
        let results = try installer.patch(ids.map { .init(appID: $0, cloudUserFolderFromHome: cloud) })
        for id in ids {
            print("\(id): \(results[id].map { $0.changes.joined(separator: "; ") } ?? "not in Steam's cache")")
        }
    } catch {
        print("failed: \(error)")
        exit(1)
    }
} else if let idx = CommandLine.arguments.firstIndex(of: "--native-steam-restore"), idx + 2 < CommandLine.arguments.count {
    // Dev: put Steam's own appinfo entry back for the given app ids, from an untouched appinfo.vdf copy
    // (`--native-steam-restore <pristine appinfo.vdf> <appid>…`). Steam must be closed.
    let paths = AppPaths.standard()
    let pristine = URL(fileURLWithPath: CommandLine.arguments[idx + 1])
    let ids = CommandLine.arguments[(idx + 2)...].compactMap { UInt32($0) }
    let installer = NativeSteamInstaller(
        steamRoot: FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Steam"),
        backupDir: paths.supportDir.appendingPathComponent("NativeSteam"),
        isSteamRunning: { !NSRunningApplication.runningApplications(withBundleIdentifier: "com.valvesoftware.steam").isEmpty })
    do {
        let restored = try installer.restoreOriginal(ids, from: pristine)
        print("restored: \(restored.map(String.init).joined(separator: " "))")
    } catch {
        print("failed: \(error)")
        exit(1)
    }
} else if CommandLine.arguments.contains(NativeSteamGuard.flag) {
    // The LaunchAgent's loop: protect every installed Windows game at start and after each Steam exit, so stock
    // macOS Steam can never "update" one to its empty Mac depot set and delete it (2026-11-09).
    let paths = AppPaths.standard()
    let steamRunning: @Sendable () -> Bool = {
        !NSRunningApplication.runningApplications(withBundleIdentifier: "com.valvesoftware.steam").isEmpty
    }
    let installer = NativeSteamInstaller(
        steamRoot: FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Steam"),
        backupDir: paths.supportDir.appendingPathComponent("NativeSteam"), isSteamRunning: steamRunning)
    func log(_ line: String) { print("\(ISO8601DateFormatter().string(from: Date())) \(line)"); fflush(stdout) }
    log("guard started")
    var watch = NativeSteamGuard.Watch()
    let cef = SteamCEFClient()
    var filtersLive = false
    var nextFilterCheck = Date.distantPast
    let playing = NativeSteamPlaying(paths: paths)
    var wasPlaying = false
    while true {
        let running = steamRunning()
        // While a game started through Silo runs, nothing touches Steam's UI: the filters' timer is paused once
        // and no probe is sent until the game ends.
        let isPlaying = running && playing.isPlaying()
        if isPlaying != wasPlaying {
            _ = try? await cef.evaluate(SteamLibraryFilters.pause(isPlaying))
            log(isPlaying ? "game running: Steam UI checks paused" : "game ended: Steam UI checks resumed")
            wasPlaying = isPlaying
            nextFilterCheck = Date()
        }
        // Silo's Apple / Windows library filters: (re)injected whenever this version isn't live in Steam's UI —
        // a new Steam session, or its SharedJSContext reloaded. Checked often until it's in, then every 10 s.
        if running, !isPlaying, Date() >= nextFilterCheck {
            let live = (try? await cef.evaluate(SteamLibraryFilters.probe)) == "true"
            if !live, let ids = try? installer.windowsGameIDsInCache(),
               let reply = try? await cef.evaluate(SteamLibraryFilters.script(windowsOnly: ids.windowsOnly,
                                                                             windowsBuild: ids.windowsBuild)) {
                log("library filters: \(reply)")
                filtersLive = reply.hasPrefix("silo filters")
            } else if live != filtersLive {
                filtersLive = live
            }
            nextFilterCheck = Date().addingTimeInterval(filtersLive ? 10 : 2)
        }
        if !running { filtersLive = false }
        if watch.shouldProtect(steamRunning: running) {
            SteamLibraryFilters.enableDebugPort(steamRoot: installer.steamRoot)
            // Let Steam finish writing appinfo.vdf on its way out.
            try? await Task.sleep(for: .seconds(3))
            do {
                let changed = try installer.protectInstalledWindowsGames()
                log(changed.isEmpty ? "all installed Windows games already protected"
                    : changed.keys.sorted().map { "protected \($0): \(changed[$0]!.changes.joined(separator: "; "))" }
                        .joined(separator: "\n"))
                // The safety net: undo a wipe Steam made mid-session, keep the copy-on-write shadows current.
                let shadows = NativeSteamShadow(isSteamRunning: steamRunning).sync(
                    libraries: installer.libraries(), windowsGames: try installer.installedWindowsGameIDs())
                for action in shadows { log("shadow: \(action)") }
            } catch NativeSteamInstaller.Failure.steamRunning {
                log("Steam started again before the check; retrying after it quits")
                watch = NativeSteamGuard.Watch()
                _ = watch.shouldProtect(steamRunning: true)
            } catch {
                log("protect failed: \(error)")
            }
        }
        try? await Task.sleep(for: .seconds(2))
    }
} else if CommandLine.arguments.contains("--native-steam-guard-install") {
    // Installs (or refreshes) the guard's LaunchAgent for this Silo binary and starts it now.
    let paths = AppPaths.standard()
    let home = FileManager.default.homeDirectoryForCurrentUser
    let agent = NativeSteamGuard.launchAgentURL(home: home)
    let siloExe = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
    do {
        try FileManager.default.createDirectory(at: agent.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: paths.logsDir, withIntermediateDirectories: true)
        try NativeSteamGuard.launchAgentPlist(
            siloExecutable: siloExe, logURL: paths.logsDir.appendingPathComponent("native-steam-guard.log"))
            .write(to: agent, options: .atomic)
        let runner = SystemProcessRunner()
        let launchctl = URL(fileURLWithPath: "/bin/launchctl")
        let domain = "gui/\(getuid())"
        _ = try? await runner.run(executable: launchctl, arguments: ["bootout", "\(domain)/\(NativeSteamGuard.label)"],
                                  environment: [:], currentDirectory: nil)
        // bootout returns before launchd has finished removing the old job; bootstrap fails (EIO) until it has.
        var result = try await runner.run(executable: launchctl, arguments: ["bootstrap", domain, agent.path],
                                          environment: [:], currentDirectory: nil)
        for _ in 0..<10 where result.exitCode != 0 {
            try? await Task.sleep(for: .milliseconds(500))
            result = try await runner.run(executable: launchctl, arguments: ["bootstrap", domain, agent.path],
                                          environment: [:], currentDirectory: nil)
        }
        print(result.exitCode == 0 ? "guard installed: \(agent.path) -> \(siloExe.path)"
              : "launchctl bootstrap failed (\(result.exitCode)): \(String(decoding: result.standardError, as: UTF8.self))")
        if result.exitCode != 0 { exit(1) }
    } catch {
        print("failed: \(error)")
        exit(1)
    }
} else if CommandLine.arguments.contains("--setup-steam") {
    // CLI harness (dev/on-device validation): run the whole guided setup — Wine + DXMT download, then the
    // bottle's ordered component installs + first-run warm-up — against the real bottle, streaming progress.
    print("Running Silo setup (Wine → DXMT → Steam bottle)…")
    let env = AppEnvironment()
    await env.bootstrap()
    let run = Task { @MainActor in await env.runFullSetup() }
    try? await Task.sleep(for: .milliseconds(150))   // let it flip setupBusy=true
    var last = ""
    while env.setupBusy {
        let line = env.steamBottleVM.status
        if line != last, !line.isEmpty { print("• \(line)"); last = line }
        try? await Task.sleep(for: .milliseconds(500))
    }
    await run.value
    print("Final: \(env.steamBottleVM.status)")
} else if let idx = CommandLine.arguments.firstIndex(of: "--import-gptk"),
          idx + 1 < CommandLine.arguments.count {
    // CLI: import GPTK from an Apple .dmg (same code path the GUI uses). Top-level await — no
    // Task+semaphore (that pattern deadlocks the main thread in a CLI).
    let dmg = URL(fileURLWithPath: CommandLine.arguments[idx + 1])
    print("Importing GPTK from \(dmg.path)")
    do {
        let result = try await GPTKImporter(runner: SystemProcessRunner(), paths: .standard())
            .importGPTK(fromDMG: dmg) { stage in print("• \(stage)") }
        print("Imported GPTK:")
        print("  install dir:  \(result.installDir.path)")
        print("  gptk lib dir: \(result.gptkLibDir.path)")
        print("  D3DMetal:     \(result.d3dMetalFramework.path)")
    } catch {
        print("GPTK import failed: \(error)")
        exit(1)
    }
} else {
    SiloApp.main()
}
