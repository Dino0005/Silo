import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Present an open panel for choosing a `.dmg` (GPTK). Returns nil if cancelled.
@MainActor
func chooseDiskImage() -> URL? {
    let panel = NSOpenPanel()
    panel.canChooseFiles = true
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = false
    panel.allowedContentTypes = [.diskImage]
    return panel.runModal() == .OK ? panel.url : nil
}

/// Present an open panel for choosing a FOLDER. Used for the Media Foundation package, which is a
/// directory (system32/, syswow64/, mf.reg, wmf.reg) rather than a single file. Returns nil if cancelled.
@MainActor
func chooseFolder(message: String,
                  // String(localized:): `prompt` is a plain String assigned to the panel, and a plain
                  // String never consults the strings table — "Choose" showed next to macOS's own
                  // translated "Cancel".
                  prompt: String = String(localized: "Choose")) -> URL? {
    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    panel.message = message
    panel.prompt = prompt
    return panel.runModal() == .OK ? panel.url : nil
}

/// Present an open panel for choosing a Windows executable. `directory` sets the initial location (e.g. the
/// bottle's `drive_c`). When `installer` is true the panel also accepts a `.msi` package — setup programs
/// ship as either a `.exe` or an `.msi`; otherwise it's `.exe`-only, since a game's launch target must be a
/// PE image, not an installer package. Returns nil if cancelled.
@MainActor
func chooseExecutable(message: String, directory: URL? = nil, installer: Bool = false) -> URL? {
    let panel = NSOpenPanel()
    panel.canChooseFiles = true
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = false
    panel.message = message
    panel.prompt = String(localized: "Choose")
    let extensions = installer ? ["exe", "msi"] : ["exe"]
    let types = extensions.compactMap { UTType(filenameExtension: $0) }
    if !types.isEmpty { panel.allowedContentTypes = types }
    if let directory, FileManager.default.fileExists(atPath: directory.path) {
        panel.directoryURL = directory
    }
    return panel.runModal() == .OK ? panel.url : nil
}

/// Present an open panel for choosing a directory (e.g. where to keep bottles). Returns nil if cancelled.
@MainActor
func chooseDirectory(message: String) -> URL? {
    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.canCreateDirectories = true
    panel.allowsMultipleSelection = false
    panel.message = message
    panel.prompt = String(localized: "Choose")
    return panel.runModal() == .OK ? panel.url : nil
}

/// Gradient fallback shown while a game's cover art loads or is unavailable (tile + detail hero).
struct GameArtworkPlaceholder: View {
    var iconFont: Font = .title2
    /// Whether to draw the controller glyph. Off when something is going to be drawn on top that isn't a
    /// full-bleed cover — an `.exe` icon is small and padded, so the glyph would show through underneath it.
    var showsGlyph: Bool = true
    var body: some View {
        LinearGradient(colors: [.indigo.opacity(0.55), .cyan.opacity(0.45)],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
            .overlay {
                if showsGlyph {
                    Image(systemName: "gamecontroller.fill").font(iconFont).foregroundStyle(.white.opacity(0.7))
                }
            }
    }
}

extension View {
    /// The shared "Uninstall this game?" confirmation used by both the tile and the detail view.
    func uninstallConfirmation(
        game: SteamApp, isPresented: Binding<Bool>, library: GameLibraryViewModel
    ) -> some View {
        confirmationDialog("Uninstall \(game.name)?", isPresented: isPresented, titleVisibility: .visible) {
            Button("Uninstall", role: .destructive) { Task { await library.uninstall(game) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Asks the bottle's Steam to uninstall this game. You can reinstall it anytime.")
        }
    }
}
