import Foundation
import Testing
@testable import SiloKit

/// The "ships looking fine, breaks later" class of setup defects: a component that reads satisfied while
/// half-installed, and a setup that reports success over a bottle that is missing pieces.
/// `setupOutcome` is isolated to `SteamBottleViewModel`'s MainActor, so the whole suite runs there —
/// the same convention `SteamBottleViewModelTests` already uses.
@MainActor
@Suite("Setup quality")
struct SetupQualityTests {

    // MARK: - Core fonts must be ALL-or-unsatisfied

    @Test("a partial core-font set stays UNSATISFIED (Arial alone is not enough)")
    func partialCoreFontsStayUnsatisfied() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let paths = AppPaths(supportDir: tmp.url.appendingPathComponent("Silo"))
        let bottle = SteamBottle(runner: FakeProcessRunner(), paths: paths)
        let fonts = paths.steamBottle.appendingPathComponent("drive_c/windows/Fonts")
        try FileManager.default.createDirectory(at: fonts, withIntermediateDirectories: true)

        // Arial comes from the SECOND of eleven packages — the exact signal the old predicate keyed on.
        // Restoring that single-file check makes this expectation fail, which is the point.
        FileManager.default.createFile(atPath: fonts.appendingPathComponent("Arial.TTF").path, contents: Data())
        #expect(!bottle.hasCoreFonts)
        #expect(bottle.unsatisfiedComponents().contains(BottleComponent.coreFonts))

        // Ten of eleven is still incomplete.
        for witness in Silo.coreFontWitness.values where witness != "Webdings.TTF" {
            FileManager.default.createFile(atPath: fonts.appendingPathComponent(witness).path, contents: Data())
        }
        #expect(!bottle.hasCoreFonts)

        FileManager.default.createFile(atPath: fonts.appendingPathComponent("Webdings.TTF").path, contents: Data())
        #expect(bottle.hasCoreFonts)
        #expect(!bottle.unsatisfiedComponents().contains(BottleComponent.coreFonts))
    }

    @Test("every core-font package has a witness artifact declared")
    func everyPackageHasAWitness() {
        for package in Silo.coreFonts {
            #expect(Silo.coreFontWitness[package] != nil, "no witness for \(package)")
        }
    }

    // MARK: - Setup tells the truth about what landed

    @Test("a Steam client that never finished outranks any component report")
    func unfinishedClientWins() {
        let text = SteamBottleViewModel.setupOutcome(steamInstalled: false, missing: [.coreFonts])
        #expect(text.contains("didn't finish downloading"))
    }

    @Test("a fully provisioned bottle reports plain success")
    func cleanSetupReportsReady() {
        let text = SteamBottleViewModel.setupOutcome(steamInstalled: true, missing: [])
        #expect(text.contains("Steam is ready."))
    }

    @Test("missing components are NAMED, and beyond two the rest are counted")
    func missingComponentsAreNamed() {
        let one = SteamBottleViewModel.setupOutcome(steamInstalled: true, missing: [.vcRedistX64])
        #expect(one.contains("Visual C++ Runtime (x64)"))
        #expect(one.contains("Set up again"))

        let two = SteamBottleViewModel.setupOutcome(
            steamInstalled: true, missing: [.coreFonts, .vcRedistX86])
        #expect(two.contains("Core Fonts"))
        #expect(two.contains("Visual C++ Runtime (x86)"))

        let many = SteamBottleViewModel.setupOutcome(
            steamInstalled: true, missing: [.coreFonts, .vcRedistX86, .vcRedistX64, .msync])
        #expect(many.contains("Core Fonts"))
        #expect(many.contains("3"))                 // "and 3 others"
        // Never a bare success line when something is missing.
        #expect(!many.contains("Launch it and sign in once"))
    }

    // MARK: - Cancel codes are shared

    @Test("the cancel codes cover MSI's pair AND the NSIS wizard's 2")
    func cancelCodesCoverBothInstallerFamilies() {
        #expect(Silo.installerCancelCodes.contains(1602))   // ERROR_INSTALL_USER_EXIT
        #expect(Silo.installerCancelCodes.contains(1223))   // ERROR_CANCELLED
        #expect(Silo.installerCancelCodes.contains(2))      // NSIS, i.e. SteamSetup
        #expect(!Silo.installerCancelCodes.contains(0))     // success is not a cancel
        #expect(!Silo.installerCancelCodes.contains(3010))  // needs-reboot is not a cancel
    }
}
