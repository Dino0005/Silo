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
}
