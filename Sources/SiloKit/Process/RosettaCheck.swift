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
/// to raise that dialog. So Silo notices and explains instead.
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
