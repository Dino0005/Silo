import Foundation
import Observation

/// The "Steam for macOS" settings tab: the on/off switch over `NativeSteamSetup`, its status, and the separate
/// "delete the bottles" action.
@MainActor @Observable
public final class NativeSteamSettingsModel {
    public private(set) var status = NativeSteamSetup.Status()
    public private(set) var isWorking = false
    /// The last outcome, as a localizable sentence.
    public private(set) var message: String?
    private let setup: NativeSteamSetup

    public init(setup: NativeSteamSetup = NativeSteamSetup()) {
        self.setup = setup
        refresh()
    }

    public func refresh() { status = setup.status() }

    public func setEnabled(_ on: Bool) async {
        guard !isWorking, on != status.enabled else { return }
        isWorking = true
        defer { isWorking = false; refresh() }
        do {
            if on {
                try await setup.enable()
                message = "Steam for macOS is on. Open Steam from “Steam (Silo)” in your Applications folder."
            } else {
                try await setup.disable()
                message = "Steam for macOS is off. Windows games stay protected until their library is removed from Steam."
            }
        } catch NativeSteamSetup.Failure.steamRunning {
            message = "Quit Steam first."
        } catch NativeSteamSetup.Failure.notAnApp {
            message = "Only available when Silo runs as an app."
        } catch {
            message = "Couldn't change it: \(error.localizedDescription)"
        }
    }

    public func deleteBottles() {
        guard !isWorking else { return }
        do {
            try setup.deleteBottles()
            message = "The Steam for macOS bottles were deleted."
        } catch NativeSteamSetup.Failure.bottlesInUse {
            message = "Turn Steam for macOS off and quit Steam and its games first."
        } catch {
            message = "Couldn't delete the bottles: \(error.localizedDescription)"
        }
        refresh()
    }
}
