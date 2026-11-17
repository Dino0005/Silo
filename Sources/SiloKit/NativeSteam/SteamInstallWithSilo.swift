import Foundation

/// "Install" on a Windows game macOS Steam can't install by itself (not yet protected by Silo — Steam answers
/// "Invalid platform"): Steam's own Install button, taken over for exactly those games.
///
/// Measured 2026-11-10: the game page's Install button calls `SteamClient.Installs.OpenInstallWizard([appid],
/// clientID)` in Steam's SharedJSContext. The script (injected by the guard through `SteamCEFClient`) wraps that
/// call: for a game in Silo's list it queues the app id instead of opening Steam's wizard; every other call goes
/// to Steam unchanged. The guard drains the queue (`takeRequests`), asks the user to restart Steam, and readies
/// the game with `NativeSteamInstaller.prepareInstall` while Steam is closed — the next start downloads its
/// Windows build into the external library.
public enum SteamInstallWithSilo {
    /// Bumped whenever the script changes, so a running Steam gets the new one.
    public static let version = 1

    /// JavaScript that answers whether this version is live in the page.
    public static let probe = "String(window.__siloInstall && window.__siloInstall.version === \(version))"

    /// JavaScript that returns (as JSON) and clears the app ids whose Install was pressed.
    public static let takeRequests =
        "JSON.stringify(window.__siloInstall && window.__siloInstall.take ? window.__siloInstall.take() : [])"

    /// The app ids in `takeRequests`' reply; anything unreadable is no request.
    public static func requests(fromReply reply: String) -> [UInt32] {
        guard let data = reply.data(using: .utf8),
              let ids = try? JSONDecoder().decode([Double].self, from: data) else { return [] }
        var seen: Set<UInt32> = []
        return ids.compactMap { $0 >= 0 && $0 <= Double(UInt32.max) ? UInt32($0) : nil }.filter { seen.insert($0).inserted }
    }

    /// The script, with the games whose Install Silo takes over.
    public static func script(appIDs: [UInt32]) -> String {
        template
            .replacingOccurrences(of: "__SILO_VERSION__", with: String(version))
            .replacingOccurrences(of: "__SILO_IDS__", with: appIDs.sorted().map(String.init).joined(separator: ","))
    }

    /// The question asked before Steam is restarted — in Italian when the system's first language is.
    public static func restartPrompt(gameName: String, library: String, italian: Bool) -> (message: String, ok: String, cancel: String) {
        italian
            ? ("Per installare \(gameName) con Silo, Steam deve riavviarsi. Il gioco verrà scaricato in “\(library)”.\n\nRiavviare Steam ora?",
               "Riavvia Steam", "Annulla")
            : ("To install \(gameName) with Silo, Steam has to restart. The game will be downloaded to “\(library)”.\n\nRestart Steam now?",
               "Restart Steam", "Cancel")
    }

    /// `osascript` arguments that show `prompt` and print the button pressed ("" when cancelled).
    public static func dialogArguments(_ prompt: (message: String, ok: String, cancel: String)) -> [String] {
        func quoted(_ s: String) -> String {
            "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        return ["-e", "try",
                "-e", "button returned of (display dialog \(quoted(prompt.message)) with title \"Silo\" buttons {\(quoted(prompt.cancel)), \(quoted(prompt.ok))} default button \(quoted(prompt.ok)) cancel button \(quoted(prompt.cancel)) with icon note)",
                "-e", "on error",
                "-e", "\"\"",
                "-e", "end try"]
    }

    static let template = #"""
    (() => {
      const S = window.__siloInstall || (window.__siloInstall = {});
      S.version = __SILO_VERSION__;
      S.ids = new Set([__SILO_IDS__]);
      S.queue = S.queue || [];
      const I = SteamClient.Installs;
      // Steam's own function is saved once; the wrapper is redefined on every injection, so a newer list wins.
      if (!S.orig) S.orig = I.OpenInstallWizard;
      I.OpenInstallWizard = function (apps, ...rest) {
        const list = (Array.isArray(apps) ? apps : [apps]).map(Number);
        const mine = list.filter((id) => S.ids.has(id));
        for (const id of mine) if (!S.queue.includes(id)) S.queue.push(id);
        const others = list.filter((id) => !S.ids.has(id));
        if (!others.length) return Promise.resolve();
        return S.orig.call(I, others, ...rest);
      };
      S.take = () => { const q = S.queue; S.queue = []; return q; };
      return 'silo install v' + S.version + ': ' + S.ids.size + ' games';
    })()
    """#
}
