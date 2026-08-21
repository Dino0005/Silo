import Foundation

/// Drives the Media Foundation tab: import the user's MF package, then build the MF bottle from it.
///
/// Two separate things, deliberately, because they fail for different reasons and at different times.
/// Importing is a file copy of a folder the user chose. Building the bottle clones the Steam bottle and
/// runs a dozen wine invocations against it — slow, and only possible once Steam itself is set up.
@MainActor
@Observable
public final class MediaFoundationViewModel {
    /// The imported package, if any. `nil` means the user hasn't supplied one yet.
    public private(set) var package: MediaFoundationPackage?
    /// Whether the MF bottle exists AND has the recipe applied. A half-built bottle (cloned, recipe
    /// failed) reads as false, so the UI offers to build rather than pretending it's ready.
    public private(set) var bottleReady = false
    public private(set) var isWorking = false
    public private(set) var progress: String?
    public var statusMessage: String?

    private let importer: MediaFoundationImporter
    private let cloner: BottleCloner
    private let installer: MediaFoundationInstaller
    private let paths: AppPaths
    /// Needed to turn off every game's MF flag when the bottle goes away.
    private let configStore: ConfigStore
    /// The wine binary to run the recipe with, and whether the source bottle is set up — both live
    /// elsewhere and change over time, so they're read at the moment they're needed.
    private let wineBinary: @MainActor () -> URL?
    /// Name of the configured Wine runtime, stamped into the bottle when it's built and compared against on
    /// every refresh. Defaults to nil so existing callers (and tests) are unaffected: an unstamped bottle
    /// simply never reads as stale.
    private let wineRuntimeName: @MainActor () -> String?
    /// Non-nil when the bottle was built under a different Wine than the one configured — the pane shows
    /// this instead of pretending the bottle is usable.
    public private(set) var rebuildNotice: String?

    public init(
        importer: MediaFoundationImporter,
        cloner: BottleCloner,
        installer: MediaFoundationInstaller,
        paths: AppPaths,
        configStore: ConfigStore,
        wineBinary: @escaping @MainActor () -> URL?,
        wineRuntimeName: @escaping @MainActor () -> String? = { nil }
    ) {
        self.wineRuntimeName = wineRuntimeName
        self.importer = importer
        self.cloner = cloner
        self.installer = installer
        self.paths = paths
        self.configStore = configStore
        self.wineBinary = wineBinary
    }

    public func refresh() {
        package = importer.installed()
        let current = wineRuntimeName()
        let stale = MediaFoundationInstaller.isStale(
            inPrefix: paths.steamBottleMF, currentRuntime: current)
        // A stale bottle is NOT ready: the pane offers to rebuild rather than claiming everything is fine
        // while the videos it exists for are black again.
        bottleReady = MediaFoundationInstaller.isInstalled(inPrefix: paths.steamBottleMF) && !stale
        if stale,
           let built = MediaFoundationInstaller.builtRuntimeName(inPrefix: paths.steamBottleMF),
           let current {
            rebuildNotice = String(localized:
                "The Media Foundation bottle was built with \(built), but Wine is now \(current). Rebuild it to use it again.")
        } else {
            rebuildNotice = nil
        }
    }

    /// True when there's a Steam bottle to clone from. Building without one would produce a bottle with
    /// no Steam client in it, which no Steam game could launch against.
    public var canBuildBottle: Bool {
        package != nil && !bottleReady && BottleCloner.isPrefix(paths.steamBottle)
    }

    // MARK: - package

    public func importPackage(from folder: URL) async {
        guard !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        statusMessage = nil
        do {
            _ = try importer.importPackage(from: folder)
            refresh()
            statusMessage = String(localized: "Media Foundation package imported.")
        } catch let error as MediaFoundationImporter.ImportError {
            statusMessage = Self.describe(error)
        } catch {
            statusMessage = String(localized: "Couldn't import: \((error as NSError).localizedDescription)")
        }
    }

    public func removePackage() {
        guard !isWorking else { return }
        do {
            try importer.remove()
            refresh()
            statusMessage = String(localized: "Package removed. The Media Foundation bottle, if any, still works.")
        } catch {
            statusMessage = String(localized: "Couldn't remove: \((error as NSError).localizedDescription)")
        }
    }

    // MARK: - bottle

    /// Clone the Steam bottle and apply the recipe to the copy.
    ///
    /// A dozen wine invocations plus a copy, so it reports progress throughout rather than leaving a
    /// button looking stuck. On failure the half-built clone is removed: a bottle that was copied but
    /// never got the recipe would launch games with Wine's builtin MF and quietly behave like the normal
    /// bottle, which is the most confusing outcome available.
    public func buildBottle() async {
        guard !isWorking, let package else { return }
        guard let wine = wineBinary() else {
            statusMessage = String(localized: "Set up Wine first.")
            return
        }
        guard BottleCloner.isPrefix(paths.steamBottle) else {
            statusMessage = String(localized: "Set up the Steam bottle first — the Media Foundation bottle is a copy of it.")
            return
        }
        isWorking = true
        defer { isWorking = false; progress = nil }
        statusMessage = nil

        do {
            if FileManager.default.fileExists(atPath: paths.steamBottleMF.path) {
                // A leftover from a failed attempt (a good one would have set bottleReady).
                try FileManager.default.removeItem(at: paths.steamBottleMF)
            }
            progress = "Copying the Steam bottle…"
            try await cloner.clone(from: paths.steamBottle, to: paths.steamBottleMF)

            let box = ProgressBox { [weak self] text in
                Task { @MainActor in self?.progress = text }
            }
            try await installer.install(
                package: package, intoPrefix: paths.steamBottleMF, wine: wine,
                runtimeName: wineRuntimeName(),
                progress: { box.report(Self.describe($0)) })

            refresh()
            statusMessage = bottleReady
                ? "Media Foundation bottle ready. Turn it on per game in that game's settings."
                : "Finished, but the bottle doesn't look ready — try again."
        } catch {
            try? FileManager.default.removeItem(at: paths.steamBottleMF)
            refresh()
            statusMessage = Self.describe(error)
        }
    }

    /// Delete the MF bottle. Its Steam login and any saves that only exist there go with it — the caller
    /// is expected to have confirmed.
    public func removeBottle() async {
        guard !isWorking else { return }
        do {
            if FileManager.default.fileExists(atPath: paths.steamBottleMF.path) {
                try FileManager.default.removeItem(at: paths.steamBottleMF)
            }
            // Clear every game's flag in the same breath: leaving one set would point a game at a bottle
            // that no longer exists, and the toggle is hidden without that bottle — so the user would
            // have no way to turn it off again.
            _ = try? await configStore.updateAllGames { $0.envFlags.mediaFoundationNative = false }
            refresh()
            statusMessage = String(localized: "Media Foundation bottle removed. Games that used it are back on the normal bottle.")
        } catch {
            statusMessage = String(localized: "Couldn't remove the bottle: \((error as NSError).localizedDescription)")
        }
    }

    // MARK: - messages

    // `nonisolated`: pure switches over an enum, no state touched. They have to be callable from the
    // installer's @Sendable progress callback, which runs off the main actor — without this the class's
    // @MainActor isolation would make them implicitly async there.
    nonisolated static func describe(_ stage: MediaFoundationInstaller.Stage) -> String {
        switch stage {
        case .copyingDLLs: "Copying Media Foundation DLLs…"
        case .writingOverrides: "Writing DLL overrides…"
        case .importingRegistry: "Importing registry entries…"
        case .registeringComponents: "Registering components…"
        case .done: "Finishing up…"
        }
    }

    nonisolated static func describe(_ error: MediaFoundationImporter.ImportError) -> String {
        switch error {
        case .missingComponents(let items):
            "That folder isn't a Media Foundation package — missing: \(items.joined(separator: ", "))."
        case .missingDLLs(let items):
            "That folder is missing \(items.count) DLL(s), including \(items.prefix(3).joined(separator: ", "))."
        }
    }

    nonisolated static func describe(_ error: any Error) -> String {
        switch error {
        case let error as MediaFoundationImporter.ImportError:
            describe(error)
        case let error as MediaFoundationInstaller.InstallError:
            switch error {
            case .prefixMissing:
                "The Steam bottle copy is missing — set up the Steam bottle and try again."
            case .stepFailed(let step, let status, _):
                "Failed while \(step) (exit \(status))."
            }
        case let error as BottleCloner.CloneError:
            switch error {
            case .sourceMissing:
                "Set up the Steam bottle first — the Media Foundation bottle is a copy of it."
            case .destinationExists:
                "A Media Foundation bottle already exists."
            case .copyFailed(_, let stderr):
                "Couldn't copy the Steam bottle\(stderr.isEmpty ? "." : ": \(stderr)")"
            }
        default:
            (error as NSError).localizedDescription
        }
    }

    /// The installer's progress callback is `@Sendable` and fires off the main actor; this hops each
    /// update back.
    private final class ProgressBox: @unchecked Sendable {
        private let sink: @Sendable (String) -> Void
        init(_ sink: @escaping @Sendable (String) -> Void) { self.sink = sink }
        func report(_ text: String) { sink(text) }
    }
}
