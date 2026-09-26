import Foundation
import Testing
@testable import SiloKit

/// The startup check for Intel translation.
@Suite("Rosetta availability")
struct RosettaCheckTests {

    @Test("follows pgrep's exit code: 0 means the daemon is there, 1 means it isn't")
    func readsPgrepExitCode() async {
        // On an Intel Mac the question doesn't apply and the answer is always true, so assert the branch
        // that belongs to the machine running the tests rather than pretending to control the hardware.
        let onSilicon = RosettaCheck.isAppleSilicon

        let found = FakeProcessRunner()
        found.defaultResult = ProcessResult(exitCode: 0)
        #expect(await RosettaCheck.isAvailable(runner: found))

        // pgrep exits 1 when nothing matched — that's "Rosetta absent", not a failure to interpret.
        let missing = FakeProcessRunner()
        missing.defaultResult = ProcessResult(exitCode: 1)
        #expect(await RosettaCheck.isAvailable(runner: missing) == !onSilicon)
    }

    @Test("the daemon is asked for by exact name, so a longer process name can't stand in for it")
    func queriesExactName() async {
        guard RosettaCheck.isAppleSilicon else { return }      // nothing is run at all on Intel
        let fake = FakeProcessRunner()
        fake.defaultResult = ProcessResult(exitCode: 0)
        _ = await RosettaCheck.isAvailable(runner: fake)
        let call = fake.invocations.first
        #expect(call?.executable.lastPathComponent == "pgrep")
        #expect(call?.arguments == ["-x", "oahd"])
    }

    @Test("an Intel Mac is never told to install anything, and nothing is run to find out")
    func skippedOnIntel() async {
        guard !RosettaCheck.isAppleSilicon else { return }
        let fake = FakeProcessRunner()
        fake.defaultResult = ProcessResult(exitCode: 1)
        #expect(await RosettaCheck.isAvailable(runner: fake))
        #expect(fake.invocations.isEmpty)
    }

    @Test("a spawn the kernel refuses for its CPU type reads as Rosetta missing, not as \"Bad CPU type\"")
    func badArchitectureMeansRosettaMissing() {
        let refused = NSError(domain: NSPOSIXErrorDomain, code: Int(EBADARCH))
        #expect(RosettaCheck.translating(refused) as? RosettaCheck.RosettaError == .notInstalled)
    }

    @Test("any other spawn failure passes through untouched")
    func otherErrorsPassThrough() {
        let missing = NSError(domain: NSPOSIXErrorDomain, code: Int(ENOENT))
        let out = RosettaCheck.translating(missing) as NSError
        #expect(out.domain == NSPOSIXErrorDomain && out.code == Int(ENOENT))
    }

    @Test("installing runs Apple's softwareupdate, license accepted, and nothing else")
    func installRunsSoftwareUpdate() async throws {
        let fake = FakeProcessRunner()
        fake.defaultResult = ProcessResult(exitCode: 0)
        try await RosettaCheck.install(runner: fake)
        #expect(fake.invocations.count == 1)
        #expect(fake.lastInvocation?.executable.path == "/usr/sbin/softwareupdate")
        #expect(fake.lastInvocation?.arguments == ["--install-rosetta", "--agree-to-license"])
    }

    @Test("a failed install carries softwareupdate's own words, so the prompt can show them")
    func failedInstallKeepsTheReason() async {
        let fake = FakeProcessRunner()
        fake.defaultResult = ProcessResult(exitCode: 1, standardOutput: Data(),
                                           standardError: Data("Install failed: no network\n".utf8))
        await #expect(throws: RosettaCheck.RosettaError.installFailed("Install failed: no network")) {
            try await RosettaCheck.install(runner: fake)
        }
    }
}
