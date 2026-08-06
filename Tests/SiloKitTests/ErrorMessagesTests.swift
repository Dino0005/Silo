import Foundation
import Testing
@testable import SiloKit

/// Every error a first run can surface must read as a sentence, never as Cocoa's fallback
/// ("The operation couldn't be completed. (SiloKit.… error 4.)"). Under `swift test` Bundle.main is the
/// test runner, so `String(localized:)` falls back to the English key with its arguments substituted —
/// which is exactly what these expectations assert.
@Suite("Error messages")
struct ErrorMessagesTests {

    /// Cocoa's fallback text, which is what leaks when a type is NOT LocalizedError.
    private func isGibberish(_ text: String) -> Bool {
        text.contains("operation couldn't be completed") || text.contains("SiloKit.")
    }

    @Test("no error type leaks Cocoa's fallback description")
    func noGibberishLeaks() {
        let errors: [Error] = [
            RuntimeManager.RuntimeError.badResponse(403),
            RuntimeManager.RuntimeError.badResponse(500),
            RuntimeManager.RuntimeError.downloadFailed(404),
            RuntimeManager.RuntimeError.extractionFailed(2),
            RuntimeManager.RuntimeError.checksumMismatch(expected: "a", actual: "b"),
            RuntimeManager.RuntimeError.checksumUnavailable,
            RuntimeManager.RuntimeError.unsafeRuntimeName("../evil"),
            GPTKImporter.ImportError.attachFailed("no such file"),
            GPTKImporter.ImportError.nestedDMGNotFound,
            GPTKImporter.ImportError.redistNotFound,
            GPTKImporter.ImportError.unsafeRuntimeName(".."),
            SteamBottle.BottleError.wineNotConfigured,
            SteamBottle.BottleError.winebootFailed(1),
            SteamBottle.BottleError.installerDownloadFailed(503),
            SteamBottle.BottleError.steamInstallFailed(2),
            SteamBottle.BottleError.componentCancelled(.coreFonts),
        ]
        for error in errors {
            let text = (error as NSError).localizedDescription
            #expect(!isGibberish(text), "gibberish for \(error): \(text)")
            #expect(!text.isEmpty)
        }
    }

    @Test("the diagnostic detail each case carries survives into the sentence")
    func detailSurvives() {
        #expect(RuntimeManager.RuntimeError.badResponse(403).localizedDescription.contains("403"))
        #expect(RuntimeManager.RuntimeError.badResponse(500).localizedDescription.contains("500"))
        #expect(RuntimeManager.RuntimeError.downloadFailed(404).localizedDescription.contains("404"))
        #expect(RuntimeManager.RuntimeError.extractionFailed(2).localizedDescription.contains("2"))
        #expect(RuntimeManager.RuntimeError.unsafeRuntimeName("../evil")
            .localizedDescription.contains("../evil"))
        #expect(GPTKImporter.ImportError.attachFailed("no such file")
            .localizedDescription.contains("no such file"))
        #expect(SteamBottle.BottleError.winebootFailed(1).localizedDescription.contains("1"))
        #expect(SteamBottle.BottleError.installerDownloadFailed(503).localizedDescription.contains("503"))
        #expect(SteamBottle.BottleError.componentCancelled(.coreFonts)
            .localizedDescription.contains("Core Fonts"))
    }

    @Test("a rate-limited GitHub reads differently from any other HTTP failure")
    func rateLimitIsItsOwnSentence() {
        let limited = RuntimeManager.RuntimeError.badResponse(403).localizedDescription
        let other = RuntimeManager.RuntimeError.badResponse(500).localizedDescription
        #expect(limited != other)
        #expect(limited.contains("rate-limited"))
    }
}
