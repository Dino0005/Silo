import Foundation

// MARK: - User-facing error text
//
// Every one of these is a plain Swift enum, so before this the UI rendered
// `(error as NSError).localizedDescription` — i.e. "The operation couldn't be completed.
// (SiloKit.RuntimeManager.RuntimeError error 4.)" — for precisely the failures a first run hits most:
// a rate-limited GitHub, a missing checksum, a full disk, a bad .dmg. `LocalizedError` gives each one a
// sentence a user can act on, and keeps the diagnostic detail (exit code / HTTP status) the cases carry.
//
// Each sentence goes through `String(localized:)` rather than being a bare literal: the interpolated
// values mean the runtime string can never match a fixed key, so `Text(LocalizedStringKey(message))` —
// how the view models' status text reaches the screen — would never find a translation. `String(localized:)`
// derives the format key itself (`%@`, `%lld`, `%d`) and resolves it against Localizable.strings. Under
// `swift test` Bundle.main is the test runner, not the app bundle, so lookup falls back to the key with
// the arguments already substituted — the suite stays deterministic and English.

extension RuntimeManager.RuntimeError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .badResponse(let code) where code == 403:
            String(localized: "GitHub rate-limited this Mac (HTTP 403). Wait a few minutes and try again.")
        case .badResponse(let code):
            String(localized: "GitHub returned HTTP \(code) while listing releases.")
        case .downloadFailed(let code):
            String(localized: "The download failed (HTTP \(code)) — check your connection and try again.")
        case .extractionFailed(let code):
            String(localized: "Couldn't unpack the download (tar exit \(code)). You may be out of disk space.")
        case .checksumMismatch:
            String(localized: "The download didn't match its published checksum, so it was discarded. Try again.")
        case .checksumUnavailable:
            String(localized: "The download has no published checksum, so it wasn't installed.")
        case .unsafeRuntimeName(let name):
            String(localized: "\"\(name)\" isn't a usable runtime name.")
        }
    }
}

extension GPTKImporter.ImportError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .attachFailed(let detail):
            String(localized: "Couldn't open the disk image: \(detail)")
        case .nestedDMGNotFound:
            String(localized: "That doesn't look like Apple's Game Porting Toolkit disk image — no inner .dmg was found.")
        case .redistNotFound:
            String(localized: "That disk image doesn't contain the Game Porting Toolkit's redistributable libraries.")
        case .unsafeRuntimeName(let name):
            String(localized: "\"\(name)\" isn't a usable runtime name.")
        }
    }
}

extension SteamBottle.BottleError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .wineNotConfigured:
            String(localized: "No Wine runtime is set up yet.")
        case .winebootFailed(let code):
            String(localized: "Couldn't create the Windows bottle (wineboot exit \(code)). Check the Wine runtime in Settings.")
        case .installerDownloadFailed(let code):
            String(localized: "Couldn't download the Steam installer (HTTP \(code)) — check your connection.")
        case .steamInstallFailed(let code):
            String(localized: "The Steam installer didn't finish (exit \(code)).")
        case .componentCancelled(let component):
            String(localized: "You cancelled the \(component.title) installer.")
        }
    }
}
