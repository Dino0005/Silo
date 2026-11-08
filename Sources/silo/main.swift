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
