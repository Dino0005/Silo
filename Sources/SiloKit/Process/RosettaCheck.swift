import Foundation

/// Whether macOS can run Intel binaries — which is not optional here: the Wine Silo imports from CrossOver
/// is x86_64, so without Rosetta nothing launches at all.
///
/// It goes missing in practice. A major macOS upgrade can leave the machine without it, and the first
/// symptom is a game that won't start with an error about Steam — the launch fails deep enough that the
/// real cause never reaches the message.
///
/// macOS won't offer to install it for us. Its own prompt is triggered by LaunchServices, when an Intel
/// *application* is opened; spawning a process directly goes to the kernel and the system stays out of it,
/// which is exactly what Silo does with `wineserver`. Apple's developer support says plainly there's no API
/// to raise that dialog. So Silo notices, explains, and offers to run Apple's own installer (`install`).
public enum RosettaCheck {

    /// True when translation is available, or when the question doesn't apply (an Intel Mac).
    ///
    /// The test is `oahd`, Rosetta's daemon, being alive. Measured in both states on an Apple-Silicon Mac
    /// across a macOS upgrade: with Rosetta gone the FILES under `/usr/libexec/rosetta/` were all still
    /// there — so their presence proves nothing — while the daemon wasn't running. After installing, it ran,
    /// and kept running with no bottle open.
    public static func isAvailable(runner: ProcessRunning = SystemProcessRunner()) async -> Bool {
        guard isAppleSilicon else { return true }
        let result = try? await runner.run(executable: URL(fileURLWithPath: "/usr/bin/pgrep"),
                                           arguments: ["-x", "oahd"],
                                           environment: [:], currentDirectory: nil)
        // pgrep exits 0 when it matched something, 1 when it didn't.
        return result?.exitCode == 0
    }

    public enum RosettaError: LocalizedError, Equatable {
        /// The kernel refused an x86_64 binary (`EBADARCH`).
        case notInstalled
        case installFailed(String)

        public var errorDescription: String? {
            switch self {
            case .notInstalled:
                return String(localized: "Rosetta isn't installed, and Silo's Wine is Intel software: no game can start until macOS can translate it. Reopen Silo to install it.")
            case .installFailed(let detail):
                return String(localized: "Couldn't install Rosetta: \(detail)")
            }
        }
    }

    /// Turn the kernel's `EBADARCH` from a spawn into `.notInstalled`. The startup check says it once, but
    /// Rosetta can also go missing while Silo is open — and then a launch failed with "Bad CPU type in
    /// executable", which doesn't say what to do. Every other error passes through unchanged.
    /// (Taken from upstream's `Rosetta.translating`, 2026-09-26.)
    static func translating(_ error: Error) -> Error {
        let ns = error as NSError
        if ns.domain == NSPOSIXErrorDomain, ns.code == Int(EBADARCH) { return RosettaError.notInstalled }
        return error
    }

    static let softwareUpdate = URL(fileURLWithPath: "/usr/sbin/softwareupdate")
    static let installArguments = ["--install-rosetta", "--agree-to-license"]

    /// Install Rosetta with Apple's own `softwareupdate`, so the user doesn't have to open Terminal.
    /// Measured 2026-09-26 on macOS 27, as a normal user with Rosetta already present: no password, no
    /// prompt — it reinstalled the package ("Install of Rosetta 2 finished successfully") and exited 0. If it
    /// ever refuses, the error carries `softwareupdate`'s own words.
    public static func install(runner: ProcessRunning = SystemProcessRunner()) async throws {
        let result = try await runner.run(executable: softwareUpdate, arguments: installArguments,
                                          environment: [:], currentDirectory: nil)
        guard result.succeeded else {
            let output = [result.stderrString, result.stdoutString]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { !$0.isEmpty }
            throw RosettaError.installFailed(output ?? "softwareupdate exited \(result.exitCode)")
        }
    }

    /// Whether this machine needs translation at all. On an Intel Mac the whole question is moot.
    static var isAppleSilicon: Bool {
        var info = utsname()
        uname(&info)
        let machine = withUnsafeBytes(of: &info.machine) { raw in
            String(cString: raw.baseAddress!.assumingMemoryBound(to: CChar.self))
        }
        return machine.hasPrefix("arm")
    }
}
