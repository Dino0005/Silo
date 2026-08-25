import SwiftUI
import AppKit   // NSAlert + NSApplicationDelegate: the quit prompt has no SwiftUI equivalent

/// The SwiftUI application. Call `SiloApp.main()` to launch (see the `silo` executable target).
public struct SiloApp: App {
    @State private var environment = AppEnvironment()
    @Environment(\.scenePhase) private var scenePhase
    @NSApplicationDelegateAdaptor(QuitGuard.self) private var quitGuard

    public init() {
        // A roomier shared URL cache so library cover-art (Steam header.jpg) is a memory/disk hit on
        // scroll-back instead of a re-fetch — AsyncImage loads via URLSession.shared, which reads this.
        URLCache.shared = URLCache(memoryCapacity: 32 << 20, diskCapacity: 128 << 20)
    }

    /// Ask before quitting when something is still running in a bottle.
    ///
    /// SwiftUI has no hook for this, so it goes through the AppKit delegate — the only place macOS lets an
    /// app answer "not yet" to a quit request.
    ///
    /// The default is to LEAVE things running: Silo deliberately lets a game outlive it (there's a test
    /// pinning that), and the case it protects is real — quitting Silo to free memory while playing. The
    /// prompt only appears when something actually is running, so an ordinary quit is unchanged.
    final class QuitGuard: NSObject, NSApplicationDelegate {
        weak var environment: AppEnvironment?

        func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
            guard let environment, environment.anythingRunningInBottles() else { return .terminateNow }

            let alert = NSAlert()
            alert.messageText = String(localized: "Something is still running in a bottle.")
            alert.informativeText = String(
                localized: "Quitting Silo won't stop it. You can close everything first if you're done.")
            alert.addButton(withTitle: String(localized: "Quit and Leave Running"))   // default
            alert.addButton(withTitle: String(localized: "Close Everything and Quit"))
            alert.addButton(withTitle: String(localized: "Cancel"))

            switch alert.runModal() {
            case .alertFirstButtonReturn:
                return .terminateNow
            case .alertSecondButtonReturn:
                // Stop the bottles, then finish quitting — the work is async, so macOS is told to wait.
                Task {
                    await environment.stopBottleProcesses()
                    NSApp.reply(toApplicationShouldTerminate: true)
                }
                return .terminateLater
            default:
                return .terminateCancel
            }
        }
    }

    public var body: some Scene {
        // The main window is a `Window`, NOT a `WindowGroup`. A WindowGroup can hold many windows, so macOS
        // opens a fresh one whenever the app is activated by an external event — which made a silo:// Desktop
        // shortcut spawn a SECOND Silo window (regardless of how the URL itself is handled). A `Window` is a
        // single, unique window that can't be duplicated, so the shortcut's URL just activates this one.
        Window("Silo", id: "main") {
            RootView()
                .environment(environment)
                .frame(minWidth: 920, minHeight: 600)
                .task {
                    quitGuard.environment = environment   // the delegate outlives the view; hand it the env
                    await environment.bootstrap()
                }
                .onChange(of: scenePhase) { _, phase in
                    // Returning to Silo (e.g. after downloading games in Steam) re-scans the library.
                    if phase == .active { Task { await environment.refreshLibraryIfReady() } }
                }
                .onOpenURL { url in
                    // A Desktop game shortcut opened a silo://play/… deep link. Ignore anything that isn't a
                    // well-formed Silo link; route the rest through the environment (which queues it until the
                    // library has loaded). No new window opens now that this is a single `Window` scene.
                    guard let link = SiloDeepLink(url: url) else { return }
                    Task { await environment.handleDeepLink(link) }
                }
        }
        .windowToolbarStyle(.unified)
        .commands {
            // Under the app menu, next to About/Settings: the manual counterpart to the startup sweep,
            // for when a crash or a force-quit left something behind. No confirmation — it says what it
            // does, and it's chosen deliberately.
            CommandGroup(after: .appSettings) {
                Divider()
                Button("Stop All Bottle Processes") {
                    Task { await environment.stopBottleProcesses() }
                }
            }
        }

        // Logs open as independent windows so they stay up (live-tailing) while you drive the main
        // window — e.g. watching a game's download/run log while driving the library.
        WindowGroup(id: LogTarget.windowID, for: LogTarget.self) { $target in
            if let target {
                LogViewerView(title: target.title, url: target.url)
            }
        }

        // The standard macOS Settings window (app menu "Settings…" / ⌘, and the Library toolbar gear,
        // which calls `openSettings`). `.contentSize` makes the WINDOW hug `SettingsView`'s frame —
        // without it the window floats at a default/restored size and the content sits centered inside it
        // (the grey side-columns), and a content-level frame can't shrink it.
        Settings {
            SettingsView().environment(environment)
        }
        .windowResizability(.contentSize)
    }
}
