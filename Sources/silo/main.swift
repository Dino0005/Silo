import AppKit
import Foundation
import SiloKit

setbuf(stdout, nil)   // unbuffered so progress shows immediately under non-TTY

// Headless smoke mode for CI / sandboxes that can't open a window.
if CommandLine.arguments.contains("--smoke")
    || ProcessInfo.processInfo.environment["SILO_SMOKE"] == "1" {
    print("\(Silo.appName) \(Silo.version) — smoke ok")
} else if CommandLine.arguments.contains(SteamWithSilo.startFlag) {
    // The "Steam (Silo)" launcher app: open macOS Steam with Silo's library inside (focus hand-off to games).
    // Compatibility layer on unless SILO_STEAM_COMPAT=0: Windows-only games like SOULCALIBUR VI need the compat-tool
    // launch for their DLC and Steam Input's virtual pad (user, 2026-11-12).
    let compat = ProcessInfo.processInfo.environment["SILO_STEAM_COMPAT"] != "0"
    let outcome = try? await SteamWithSilo().start(compat: compat)
    print("start steam: \(outcome.map { "\($0)" } ?? "failed")")
    exit(outcome == nil ? 1 : 0)
} else if CommandLine.arguments.contains("--install-steam-launcher") {
    // Writes ~/Applications/Steam (Silo).app, to keep in the Dock instead of Steam's own icon, and signs it so macOS
    // can list it in Privacy & Security.
    let apps = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true)
    guard let launcher = SteamLauncherApp(appBundle: Bundle.main.bundleURL) else {
        print("steam launcher: this Silo has no launcher or library (run from Silo.app)")
        exit(1)
    }
    do {
        let steamRoot = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Steam", isDirectory: true)
        if let silo = Bundle.main.executableURL {
            let tool = try SiloCompatTool(siloExecutable: silo).write(steamRoot: steamRoot)
            print("steam compatibility tool: \(tool.path)")
        }
        if launcher.isCurrent(in: apps) {
            print("steam launcher: up to date, left as it is (its privacy grant stays)")
            exit(0)
        }
        let app = try launcher.write(into: apps)
        let signed = try await SystemProcessRunner().run(
            executable: URL(fileURLWithPath: "/usr/bin/codesign"), arguments: ["--force", "--sign", "-", app.path],
            environment: [:], currentDirectory: nil)
        print("steam launcher: \(app.path)\(signed.succeeded ? "" : " (not signed)") — authorize it again in Privacy & Security")
        exit(0)
    } catch {
        print("steam launcher failed: \(error)")
        exit(1)
    }
} else if let idx = CommandLine.arguments.firstIndex(of: NativeSteamInstaller.launchFlag) {
    // macOS Steam's Play on a Windows game (the `silo-launch` script): launch headless and stay alive until the
    // game ends — Steam treats this process as the game. Nothing reaches the user from stdout here, so every
    // step goes to Logs/native-steam-launch.log.
    // What Steam says about the game's virtual pads, for the log (NativeSteamLauncher decides whether it reaches Wine).
    let virtualPadInfo = ProcessInfo.processInfo.environment[NativeSteamBridge.virtualGamepadInfoKey]
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
    log("steam virtual pads: " + (virtualPadInfo.map { info in
        let text = (try? String(contentsOfFile: info, encoding: .utf8)) ?? "(unreadable)"
        return "\(info): " + text.split(whereSeparator: \.isNewline).joined(separator: " | ").prefix(300)
    } ?? "none"))
    // What Steam tells the game about controllers (Steam Input's ignore lists, virtual gamepad hints).
    let steamEnv = ProcessInfo.processInfo.environment.filter {
        ["SDL_", "STEAM", "Steam", "DYLD"].contains(where: $0.key.hasPrefix)
    }
    log("steam env: " + steamEnv.keys.sorted().map { "\($0)=\(steamEnv[$0]!)" }.joined(separator: " "))
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
} else if let idx = CommandLine.arguments.firstIndex(of: "--native-steam-prepare-install"),
          idx + 1 < CommandLine.arguments.count, let appID = UInt32(CommandLine.arguments[idx + 1]) {
    // Dev/on-device: ready a Windows game that isn't installed for download into a library (default: the first
    // external one) — `--native-steam-prepare-install <appid> [library path]`. Steam must be closed; its next
    // start downloads the Windows build there.
    let paths = AppPaths.standard()
    let installer = NativeSteamInstaller(
        steamRoot: FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Steam"),
        backupDir: paths.supportDir.appendingPathComponent("NativeSteam"),
        isSteamRunning: { !NSRunningApplication.runningApplications(withBundleIdentifier: "com.valvesoftware.steam").isEmpty })
    let library = idx + 2 < CommandLine.arguments.count && !CommandLine.arguments[idx + 2].hasPrefix("--")
        ? URL(fileURLWithPath: CommandLine.arguments[idx + 2], isDirectory: true) : installer.defaultGameLibrary()
    do {
        switch try installer.prepareInstall(appID, in: library) {
        case .prepared(let manifest, let changes):
            print("prepared \(manifest.path)")
            changes.forEach { print("  \($0)") }
        case .alreadyInLibrary(let manifest):
            print("already in a library: \(manifest.path)")
        }
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
    let setup = NativeSteamSetup(paths: paths, isSteamRunning: steamRunning)
    log("guard started" + (setup.isEnabled ? "" : " (Steam per macOS is off: protection only)"))
    var watch = NativeSteamGuard.Watch()
    let cef = SteamCEFClient()
    var filtersLive = false
    var nextMappingCheck = Date()
    var nextFilterCheck = Date.distantPast
    let playing = NativeSteamPlaying(paths: paths)
    var wasPlaying = false
    let runner = SystemProcessRunner()
    let osascript = URL(fileURLWithPath: "/usr/bin/osascript")
    // Steam closed: protect every installed Windows game, then keep the copy-on-write shadows current.
    // Steam Cloud's one save folder per game: the classic SteamBottle's Wine user folder, as Steam's MacHome sees it
    // (nil when the bottles live outside the home folder, e.g. moved to an external disk: no cloud rules then).
    func cloudUserFolder() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path + "/"
        guard let user = SharedSaveLinker().windowsUserDir(inPrefix: paths.steamBottle)?.standardizedFileURL.path,
              user.hasPrefix(home) else { return nil }
        return String(user.dropFirst(home.count))
    }
    func exitPass() throws {
        let cloud = setup.isEnabled ? cloudUserFolder() : nil
        let changed = try installer.protectInstalledWindowsGames(cloudUserFolderFromHome: cloud)
        log(changed.isEmpty ? "all installed Windows games already protected"
            : changed.keys.sorted().map { "protected \($0): \(changed[$0]!.changes.joined(separator: "; "))" }
                .joined(separator: "\n"))
        // The safety net: undo a wipe Steam made mid-session, keep the copy-on-write shadows current.
        let shadows = NativeSteamShadow(isSteamRunning: steamRunning).sync(
            libraries: installer.libraries(), windowsGames: try installer.installedWindowsGameIDs())
        for action in shadows { log("shadow: \(action)") }
        // Steam's shortcuts of the Windows games: the game's icon, and "Steam (Silo)" first when Steam is closed.
        if setup.isEnabled {
            for line in SteamShortcuts.fix(home: FileManager.default.homeDirectoryForCurrentUser,
                                           gameAppsDir: paths.gameAppsDir, steamLauncher: setup.launcherAppURL,
                                           games: Set(try installer.installedWindowsGameIDs().map { Int($0) })) {
                log(line)
            }
        }
        // Cloud files Steam marked Windows-only, made all-platform (macOS Steam skips them otherwise). Steam is closed
        // here; each changed file is backed up first.
        guard cloud != nil else { return }
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        // Each Windows game's compatdata user folder, linked to the classic bottle before Steam's next launch-time sync
        // (an old NotProton prefix there is moved aside within its library).
        if let canonicalUser = SharedSaveLinker().windowsUserDir(inPrefix: paths.steamBottle) {
            let windows = try installer.installedWindowsGameIDs()
            for library in installer.libraries() {
                let steamapps = library.appendingPathComponent("steamapps", isDirectory: true)
                for id in windows.sorted() where FileManager.default.fileExists(
                    atPath: steamapps.appendingPathComponent("appmanifest_\(id).acf").path) {
                    for line in SteamCloudSaves.prepareCompatUser(
                        compatData: steamapps.appendingPathComponent("compatdata/\(id)", isDirectory: true),
                        canonicalUser: canonicalUser,
                        backupDir: steamapps.appendingPathComponent("silo-backups/compatdata-\(id)-\(stamp)")) {
                        log("cloud \(id): \(line)")
                    }
                }
            }
        }
        for id in try installer.installedWindowsGameIDs().sorted() {
            for file in SteamCloudSaves.remoteCaches(steamRoot: installer.steamRoot, appID: id) {
                guard let text = try? String(contentsOf: file, encoding: .utf8),
                      let fixed = SteamCloudSaves.allPlatforms(remoteCache: text) else { continue }
                let backup = paths.supportDir.appendingPathComponent(
                    "NativeSteam/remotecache-\(stamp)/\(file.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent)-\(id).vdf")
                try? FileManager.default.createDirectory(at: backup.deletingLastPathComponent(), withIntermediateDirectories: true)
                guard (try? FileManager.default.copyItem(at: file, to: backup)) != nil,
                      (try? Data(fixed.utf8).write(to: file, options: .atomic)) != nil else { continue }
                log("cloud \(id): Windows-only files made all-platform (backup \(backup.lastPathComponent))")
            }
        }
    }
    func installWithSilo(_ appID: UInt32) async {
        let library = installer.defaultGameLibrary()
        let name = (try? AppInfoCache(contentsOf: installer.appInfoURL).app(appID))??.info.map("common")?.string("name")
            ?? "App \(appID)"
        let italian = Locale.preferredLanguages.first?.hasPrefix("it") ?? false
        let prompt = SteamInstallWithSilo.restartPrompt(
            gameName: name, library: library.lastPathComponent == "SteamLibrary"
                ? library.deletingLastPathComponent().lastPathComponent : library.lastPathComponent, italian: italian)
        let answer = try? await runner.run(executable: osascript, arguments: SteamInstallWithSilo.dialogArguments(prompt),
                                           environment: [:], currentDirectory: nil)
        let pressed = answer.map { String(decoding: $0.standardOutput, as: UTF8.self) }?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard pressed == prompt.ok else { log("install \(appID): cancelled"); return }
        log("install \(appID) (\(name)) into \(library.path): restarting Steam")
        _ = try? await runner.run(executable: osascript, arguments: ["-e", "tell application \"Steam\" to quit"],
                                  environment: [:], currentDirectory: nil)
        for _ in 0..<60 where steamRunning() { try? await Task.sleep(for: .seconds(1)) }
        guard !steamRunning() else { log("install \(appID): Steam did not quit"); return }
        // Let Steam finish writing appinfo.vdf on its way out.
        try? await Task.sleep(for: .seconds(3))
        do {
            switch try installer.prepareInstall(appID, in: library) {
            case .prepared(let manifest, let changes):
                log("install \(appID): prepared \(manifest.path); \(changes.joined(separator: "; "))")
            case .alreadyInLibrary(let manifest):
                log("install \(appID): already in \(manifest.path)")
            }
            try exitPass()
        } catch {
            log("install \(appID) failed: \(error)")
        }
        SteamLibraryFilters.enableDebugPort(steamRoot: installer.steamRoot)
        _ = try? await runner.run(executable: URL(fileURLWithPath: "/usr/bin/open"), arguments: ["-a", "Steam"],
                                  environment: [:], currentDirectory: nil)
    }
    var restartedSession: String?
    var nextShortcutCheck = Date.distantPast, nextShortcutGames = Date.distantPast
    var shortcutGames: Set<Int> = []
    while true {
        let running = steamRunning()
        // Off in Settings: only the protection below runs — nothing inside Steam's UI, no tool mapping.
        let enabled = setup.isEnabled
        // Steam's shortcuts of the Windows games, as soon as Steam makes one (Steam open or not): the game's icon, and
        // "Steam (Silo)" first. Every 5 s; the list of Windows games is read again once a minute.
        if enabled, Date() >= nextShortcutCheck {
            nextShortcutCheck = Date().addingTimeInterval(5)
            if Date() >= nextShortcutGames, let ids = try? installer.installedWindowsGameIDs() {
                shortcutGames = Set(ids.map { Int($0) })
                nextShortcutGames = Date().addingTimeInterval(60)
            }
            for line in SteamShortcuts.fix(home: FileManager.default.homeDirectoryForCurrentUser,
                                           gameAppsDir: paths.gameAppsDir, steamLauncher: setup.launcherAppURL,
                                           games: shortcutGames) {
                log(line)
            }
        }
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
        if enabled, running, !isPlaying, Date() >= nextFilterCheck {
            let live = (try? await cef.evaluate(SteamLibraryFilters.probe)) == "true"
            if !live, let ids = try? installer.windowsGameIDsInCache(),
               let reply = try? await cef.evaluate(SteamLibraryFilters.script(windowsOnly: ids.windowsOnly,
                                                                             windowsBuild: ids.windowsBuild)) {
                log("library filters: \(reply)")
                filtersLive = reply.hasPrefix("silo filters")
            } else if live != filtersLive {
                filtersLive = live
            }
            // "Install" on a Windows game Steam can't install by itself goes to Silo (same cadence as the filters).
            if (try? await cef.evaluate(SteamInstallWithSilo.probe)) != "true",
               let ids = try? installer.windowsGamesNeedingSilo(),
               let reply = try? await cef.evaluate(SteamInstallWithSilo.script(appIDs: ids)) {
                log("install takeover: \(reply)")
            }
            nextFilterCheck = Date().addingTimeInterval(filtersLive ? 10 : 2)
            // Silo's compatibility tool as every installed Windows game's default (SteamCompatMapping), once a minute.
            if Date() >= nextMappingCheck {
                nextMappingCheck = Date().addingTimeInterval(60)
                let tools = SteamCompatMapping.installedTools(
                    in: installer.steamRoot.appendingPathComponent("compatibilitytools.d"))
                let config = (try? String(contentsOf: installer.steamRoot.appendingPathComponent("config/config.vdf"),
                                          encoding: .utf8)) ?? ""
                if tools.contains(SiloCompatTool.name), let games = try? installer.installedWindowsGameIDs() {
                    let ids = SteamCompatMapping.gamesToMap(windowsGames: games,
                                                            current: SteamCompatMapping.mappings(configVDF: config),
                                                            installedTools: tools)
                    if !ids.isEmpty, let reply = try? await cef.evaluate(SteamCompatMapping.script(appIDs: ids)) {
                        log("compat tool: \(reply) (\(ids.map(String.init).joined(separator: ", ")))")
                    }
                }
            }
        }
        // An Install pressed on such a game: ask, then restart Steam with the game readied in the external library.
        if enabled, running, !isPlaying, let reply = try? await cef.evaluate(SteamInstallWithSilo.takeRequests),
           let appID = SteamInstallWithSilo.requests(fromReply: reply).first {
            await installWithSilo(appID)
            watch = NativeSteamGuard.Watch()
            _ = watch.shouldProtect(steamRunning: steamRunning())
        }
        if !running { filtersLive = false }
        // Steam closed itself to install a client update and waits for a bootstrapper that `Steam (Silo)` doesn't
        // leave behind: start it again through LaunchServices (Silo's library and the launcher's privacy grant come
        // with it), once per session, once Steam has been gone for a few seconds and only for a fresh log entry.
        if enabled, !running, FileManager.default.fileExists(atPath: setup.launcherAppURL.path) {
            let logURL = NativeSteamGuard.bootstrapLogURL(steamRoot: installer.steamRoot)
            let age = ((try? logURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate)
                .map { Date().timeIntervalSince($0) } ?? .infinity
            if age >= 5, age < 120, let text = try? String(contentsOf: logURL, encoding: .utf8),
               let session = NativeSteamGuard.sessionEndedForUpdate(bootstrapLog: String(text.suffix(65_536))),
               session != restartedSession {
                restartedSession = session
                log("Steam quit to install an update: starting Steam (Silo) again")
                _ = try? await runner.run(executable: URL(fileURLWithPath: "/usr/bin/open"),
                                          arguments: [setup.launcherAppURL.path], environment: [:], currentDirectory: nil)
            }
        }
        if watch.shouldProtect(steamRunning: running) {
            if enabled { SteamLibraryFilters.enableDebugPort(steamRoot: installer.steamRoot) }
            // Let Steam finish writing appinfo.vdf on its way out.
            try? await Task.sleep(for: .seconds(3))
            do {
                try exitPass()
                // Off, and the Windows-games library is no longer in Steam (none installed, every library reachable):
                // nothing left to protect — the launch scripts and the guard itself go.
                if !setup.isEnabled, !setup.protectionNeeded() {
                    log("Steam per macOS is off and no Windows game is left in Steam's libraries: guard retiring")
                    await setup.retire()
                    exit(0)
                }
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
    do {
        let setup = NativeSteamSetup()
        try await setup.installGuard()
        print("guard installed: \(NativeSteamGuard.launchAgentURL(home: setup.home).path) -> \(setup.siloApp.path)")
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
