import Foundation

@MainActor
@Observable
public final class GPTKManagerViewModel {
    /// Interpolated into the shared "Default %@: %@." key, so one entry covers Wine, DXMT and GPTK.
    private static let noun = "GPTK"

    public private(set) var installs: [GPTKInstall] = []
    public var defaultName: String?
    public var statusMessage: String?
    public private(set) var isImporting = false

    private let importer: GPTKImporter

    /// Called when the default GPTK changes so the backend config can adopt its lib dir.
    public var onDefaultChanged: ((GPTKInstall) -> Void)?
    /// Called when the CURRENT default GPTK is removed, so the backend config can clear the dangling lib
    /// dir (otherwise `gptkReady` stays true against a deleted runtime and launches fall back / fail).
    public var onDefaultRemoved: (() -> Void)?

    public init(importer: GPTKImporter, defaultName: String? = nil) {
        self.importer = importer
        self.defaultName = defaultName
    }

    public func refresh() {
        installs = importer.installed()
        // Drop a stale default if its install was removed out from under us — and TELL the owner, so the
        // persisted GPTK lib dir is cleared with it. Same defect `RuntimeViewModel.refresh` had: clearing
        // `defaultName` alone left `AppEnvironment`'s wiring (`onDefaultRemoved -> clearGPTKDefault`) never
        // fired, so the backend config kept pointing at a lib dir that is no longer there while this tab
        // showed nothing installed. Upstream fixed only the RuntimeViewModel side; GPTK is the default
        // backend in this fork, so it matters more here.
        if let name = defaultName, !installs.contains(where: { $0.name == name }) {
            defaultName = nil
            onDefaultRemoved?()
        }
    }

    public func importGPTK(from dmgURL: URL) async {
        guard !isImporting else { return }
        isImporting = true
        defer { isImporting = false }
        statusMessage = String(localized: "Importing \(dmgURL.lastPathComponent)…")
        do {
            // The warning callback fires off the main actor mid-import; collect it in a box and fold it
            // into the final status (a Task hop could land before OR after the "Imported" assignment).
            let warning = LockedBox<String?>(nil)
            let result = try await importer.importGPTK(fromDMG: dmgURL, onWarning: { warning.set($0) })
            refresh()
            // Adopt the newly-imported version as default if none is set yet.
            if defaultName == nil, let new = installs.first(where: { $0.name == result.name }) {
                setDefault(new)
            }
            statusMessage = warning.value.map { "Imported \(result.name) — ⚠️ \($0)" }
                ?? "Imported \(result.name)."
        } catch {
            statusMessage = String(localized: "Couldn't import: \((error as NSError).localizedDescription)")
        }
    }

    public func remove(_ install: GPTKInstall) async {
        do {
            try importer.remove(name: install.name)
            let wasDefault = defaultName == install.name
            if wasDefault { defaultName = nil }
            refresh()
            if wasDefault { onDefaultRemoved?() }   // clear the dangling lib dir in the persisted config
            statusMessage = String(localized: "Removed \(install.displayName).")
        } catch {
            statusMessage = String(localized: "Couldn't remove: \((error as NSError).localizedDescription)")
        }
    }

    public func setDefault(_ install: GPTKInstall) {
        defaultName = install.name
        onDefaultChanged?(install)
        statusMessage = String(localized: "Default \(Self.noun): \(install.displayName).")
    }

    public func isDefault(_ install: GPTKInstall) -> Bool { defaultName == install.name }
}
