import Foundation

/// Installs a `MediaFoundationPackage` into a Wine prefix: the real Windows MF DLLs in place of Wine's
/// builtin stack, so games whose video comes up black under the builtin one can play it.
///
/// The recipe is not invented here — it's the community `mf-install.sh`/`mf-fix-cx.sh` procedure, run
/// step by step on-device until Soulcalibur VI's title video appeared, then pinned:
///
///  1. copy the nine DLLs into `system32` (64-bit) and `syswow64` (32-bit)
///  2. override those nine to `native` in `HKCU\Software\Wine\DllOverrides`
///  3. import `mf.reg` + `wmf.reg` — the CLSID→handler map (which component opens an `.mp4`, and so on)
///  4. `regsvr32` the three modules that expose COM classes
///
/// All four are required, and the order matters. The overrides come BEFORE `regsvr32` so registration
/// runs against the Microsoft DLLs rather than Wine's builtins. Step 4 is the one every earlier attempt
/// skipped: registering `msmpeg2vdec` is what writes the H.264 decoder's `InputTypes`/`OutputTypes`, and
/// without those Media Foundation enumerates no decoder for H.264 — audio plays, video stays black,
/// even with every DLL correctly in place.
///
/// Everything is bottle-wide, deliberately. A per-process override on top of a bottle-wide registry is
/// an incoherent state: it left `steamwebhelper.exe` calling a Wine `mfplat` stub
/// (`MFCreateVideoSampleAllocatorEx`) and aborting, which is how Steam ended up crash-looping mid-way
/// through this investigation.
///
/// Applies to ANY prefix — the duplicated Steam bottle, or a manual game's own isolated bottle, which
/// needs no duplicate since nothing else lives in it.
public struct MediaFoundationInstaller: Sendable {
    private let runner: ProcessRunning

    public init(runner: ProcessRunning) {
        self.runner = runner
    }

    public enum Stage: Sendable, Equatable {
        case copyingDLLs
        case writingOverrides
        case importingRegistry
        case registeringComponents
        case done
    }

    public enum InstallError: Error, Sendable, Equatable {
        case prefixMissing(URL)
        /// A wine step returned non-zero. `step` names it in terms a user can act on.
        case stepFailed(step: String, status: Int32, stderr: String)
    }

    /// Whether the recipe has already been applied to this prefix — the marker `apply` drops on success.
    /// A cheap check, so callers can show state without shelling out to wine.
    public static func isInstalled(inPrefix prefix: URL, fileManager: FileManager = .default) -> Bool {
        fileManager.fileExists(atPath: marker(inPrefix: prefix).path)
    }

    static func marker(inPrefix prefix: URL) -> URL {
        prefix.appendingPathComponent(".silo-media-foundation", isDirectory: false)
    }

    /// The Wine runtime the recipe was applied WITH, read back from the marker. nil when the marker is
    /// empty — every bottle built before the stamp existed — which callers must treat as "unknown", not as
    /// "mismatched".
    public static func builtRuntimeName(inPrefix prefix: URL,
                                        fileManager: FileManager = .default) -> String? {
        guard let text = try? String(contentsOf: marker(inPrefix: prefix), encoding: .utf8) else {
            return nil
        }
        let name = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    /// The bottle was built under a DIFFERENT Wine than the one configured now.
    ///
    /// The recipe writes into the prefix — DLLs in system32/syswow64, imported .reg, overrides, registered
    /// COM modules — and a different runtime regenerates the prefix's fakedlls over the top of it, which is
    /// why CrossOver's own docs say to re-apply the MF fix after an update. The bottle then still LOOKS
    /// installed while the videos it exists for come up black again, with nothing pointing at the runtime
    /// as the cause.
    ///
    /// Fails SAFE in both unknown cases: a legacy (empty) marker, or no configured runtime name, reads as
    /// not stale. Telling someone with a working bottle to rebuild it, on no evidence, is worse than the
    /// defect this catches.
    public static func isStale(inPrefix prefix: URL, currentRuntime: String?,
                               fileManager: FileManager = .default) -> Bool {
        guard isInstalled(inPrefix: prefix, fileManager: fileManager),
              let built = builtRuntimeName(inPrefix: prefix, fileManager: fileManager),
              let current = currentRuntime else { return false }
        return built != current
    }

    /// Apply the whole recipe. Roughly a dozen wine invocations, each with its own start-up cost, so
    /// `progress` exists to drive a real indicator rather than a button that looks stuck.
    /// - Parameter runtimeName: the Wine runtime this is being applied with, stamped into the marker so a
    ///   later runtime change can be detected (see `isStale`). Defaults to nil — an unstamped marker, i.e.
    ///   the pre-stamp behaviour.
    public func install(
        package: MediaFoundationPackage,
        intoPrefix prefix: URL,
        wine: URL,
        runtimeName: String? = nil,
        progress: (@Sendable (Stage) -> Void)? = nil
    ) async throws {
        let fileManager = FileManager.default
        let driveC = prefix.appendingPathComponent("drive_c", isDirectory: true)
        guard fileManager.fileExists(atPath: driveC.path) else { throw InstallError.prefixMissing(prefix) }

        let env = Silo.msyncWineEnvironment(prefix: prefix, wine: wine)

        // 1 — DLLs. Wine ships some of these as symlinks to its own builtins, so the old entry is
        // removed rather than copied over.
        progress?(.copyingDLLs)
        for (sourceDir, windowsDir) in [(package.system32, "system32"), (package.syswow64, "syswow64")] {
            let destDir = driveC.appendingPathComponent("windows/\(windowsDir)", isDirectory: true)
            try fileManager.createDirectory(at: destDir, withIntermediateDirectories: true)
            let available = (try? fileManager.contentsOfDirectory(atPath: sourceDir.path)) ?? []
            for name in available where name.lowercased().hasSuffix(".dll") {
                guard MediaFoundationPackage.dllNames.contains(
                    name.lowercased().replacingOccurrences(of: ".dll", with: "")) else { continue }
                let dest = destDir.appendingPathComponent(name)
                try? fileManager.removeItem(at: dest)
                try fileManager.copyItem(at: sourceDir.appendingPathComponent(name), to: dest)
            }
        }

        // 2 — overrides, as ONE .reg rather than nine `reg add` calls: nine wine start-ups for nine
        // values is most of a minute for no reason.
        progress?(.writingOverrides)
        var overrides = "REGEDIT4\r\n\r\n[HKEY_CURRENT_USER\\Software\\Wine\\DllOverrides]\r\n"
        for dll in MediaFoundationPackage.dllNames { overrides += "\"\(dll)\"=\"native\"\r\n" }
        try await importReg(contents: overrides, named: "silo-mf-overrides.reg",
                            driveC: driveC, wine: wine, env: env, wow64: false, step: "DLL overrides")

        // 3 — the CLSID→handler map, in BOTH architectures. A 32-bit process reads the redirected
        // `Wow6432Node` view, so an import done only 64-bit leaves 32-bit games seeing nothing.
        progress?(.importingRegistry)
        for reg in [(package.mfReg, "mf.reg"), (package.wmfReg, "wmf.reg")] {
            let contents = try Data(contentsOf: reg.0)
            for wow64 in [false, true] {
                try await importReg(data: contents, named: "silo-\(reg.1)", driveC: driveC,
                                    wine: wine, env: env, wow64: wow64, step: "registry import (\(reg.1))")
            }
        }

        // 4 — COM registration, likewise in both architectures.
        progress?(.registeringComponents)
        for module in MediaFoundationPackage.comModules {
            for wow64 in [false, true] {
                let args = (wow64 ? ["C:\\windows\\syswow64\\regsvr32.exe"] : ["regsvr32"])
                    + ["/s", "\(module).dll"]
                let result = try await runner.run(
                    executable: wine, arguments: args, environment: env, currentDirectory: prefix)
                guard result.succeeded else {
                    throw InstallError.stepFailed(
                        step: "regsvr32 \(module).dll\(wow64 ? " (32-bit)" : "")",
                        status: result.exitCode, stderr: result.stderrString)
                }
            }
        }

        fileManager.createFile(atPath: Self.marker(inPrefix: prefix).path,
                               contents: Data((runtimeName ?? "").utf8))
        progress?(.done)
    }

    // MARK: - registry helpers

    private func importReg(
        contents: String, named: String, driveC: URL, wine: URL,
        env: [String: String], wow64: Bool, step: String
    ) async throws {
        try await importReg(data: Data(contents.utf8), named: named, driveC: driveC,
                            wine: wine, env: env, wow64: wow64, step: step)
    }

    /// Stage the .reg inside `drive_c` and hand wine a `C:\…` path — the same trick
    /// `SteamBottle.applyWineDefaults` uses, which sidesteps unix→windows path translation entirely.
    private func importReg(
        data: Data, named: String, driveC: URL, wine: URL,
        env: [String: String], wow64: Bool, step: String
    ) async throws {
        let staged = driveC.appendingPathComponent(named)
        try data.write(to: staged)
        defer { try? FileManager.default.removeItem(at: staged) }

        let args = (wow64 ? ["C:\\windows\\syswow64\\regedit.exe"] : ["regedit"]) + ["/S", "C:\\\(named)"]
        let result = try await runner.run(
            executable: wine, arguments: args, environment: env,
            currentDirectory: driveC.deletingLastPathComponent())
        guard result.succeeded else {
            throw InstallError.stepFailed(
                step: step + (wow64 ? " (32-bit)" : ""),
                status: result.exitCode, stderr: result.stderrString)
        }
    }
}
