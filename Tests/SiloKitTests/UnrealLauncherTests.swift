import Foundation
import Testing
@testable import SiloKit

/// The Unreal launcher layout measured on Tekken 8 and Fatal Fury (2026-09-25).
struct UnrealLauncherTests {
    private func install(_ tmp: TempDir, launcher: String, shipping: [String]) throws -> URL {
        let exe = try tmp.write("TEKKEN 8/\(launcher)", "MZ")
        for path in shipping { try tmp.write("TEKKEN 8/\(path)", "MZ") }
        return exe
    }

    @Test func aLauncherHandsOverToItsShippingExecutable() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let exe = try install(tmp, launcher: "TEKKEN 8.exe",
                              shipping: ["Polaris/Binaries/Win64/Polaris-Win64-Shipping.exe"])
        let owner = try #require(UnrealLauncher.shippingExecutable(forLauncher: exe))
        #expect(owner.lastPathComponent == "Polaris-Win64-Shipping.exe")
        // …which is what the whitelist will name, since Wine matches on the base name.
        #expect(AltLoaderWhitelist.exeName(for: owner.lastPathComponent) == "Polaris-Win64-Shipping")
    }

    /// Most games have one exe: nothing to redirect, the launch is untouched.
    @Test func aPlainGameIsLeftAlone() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let exe = try install(tmp, launcher: "re9.exe", shipping: [])
        #expect(UnrealLauncher.shippingExecutable(forLauncher: exe) == nil)
    }

    /// Two candidates: guessing could hand the host to the wrong process, so don't.
    @Test func moreThanOneCandidateIsNotGuessed() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let exe = try install(tmp, launcher: "Game.exe", shipping: [
            "A/Binaries/Win64/A-Win64-Shipping.exe", "B/Binaries/Win64/B-Win64-Shipping.exe"])
        #expect(UnrealLauncher.shippingExecutable(forLauncher: exe) == nil)
    }

    /// Launching the Shipping exe directly already targets the right process.
    @Test func theShippingExecutableItselfNeedsNoRedirect() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let exe = try tmp.write("G/Polaris/Binaries/Win64/Polaris-Win64-Shipping.exe", "MZ")
        #expect(UnrealLauncher.shippingExecutable(forLauncher: exe) == nil)
    }
}
