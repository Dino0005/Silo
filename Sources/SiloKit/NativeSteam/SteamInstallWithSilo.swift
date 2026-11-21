import Foundation

/// "Install" on a Windows game in Steam for macOS.
///
/// Steam for Mac greys out Install for a Windows-only game until the game has a compatibility tool — and installs it by
/// itself, with its own dialog and library choice, once it has one (measured 2026-11-21: Aimlabs, added with Steam open,
/// was greyed out; given Silo's tool through `SteamClient.Apps.SpecifyCompatTool`, Install lit up and opened Steam's
/// own dialog; Spider-Man 2 downloaded that way). So the script (injected by the guard through `SteamCEFClient`) gives
/// Silo's tool to every Windows-only game in the library that has none — installed or not, bought before or after Steam
/// started — checking each game once, from Steam's own app details (`vecPlatforms`, `strCompatToolName`). A tool the
/// user chose is left alone. Paused while a game runs, like the library filters.
///
/// It replaces version 1 (2026-11-10), which took the Install button over for a list of such games read at startup,
/// restarted Steam and readied the game itself (`NativeSteamInstaller.prepareInstall`): that list missed a game bought
/// with Steam open, and the restart was never needed once the game has a tool. The queue (`takeRequests`) stays, empty,
/// so a guard from before this version keeps working; v1's wrapper is taken off Steam's install function.
public enum SteamInstallWithSilo {
    /// Bumped whenever the script changes, so a running Steam gets the new one.
    public static let version = 2

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

    /// The script.
    public static func script() -> String {
        template
            .replacingOccurrences(of: "__SILO_VERSION__", with: String(version))
            .replacingOccurrences(of: "__SILO_TOOL__", with: SiloCompatTool.name)
    }

    /// Stops (true) or restarts (false) the script's timer — paused while a game runs.
    public static func pause(_ on: Bool) -> String {
        "String(!!(window.__siloInstall && window.__siloInstall.pause && window.__siloInstall.pause(\(on))))"
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
      S.tool = '__SILO_TOOL__';
      S.queue = [];
      // Version 1 wrapped Steam's install function: Steam's own goes back.
      if (S.orig) { SteamClient.Installs.OpenInstallWizard = S.orig; S.orig = null; }
      S.checked = S.checked || new Set();
      S.given = S.given || [];
      const details = appid => new Promise(resolve => {
        let done = false, handle = null;
        const finish = d => { if (done) return; done = true; try { handle && handle.unregister(); } catch (e) {} resolve(d); };
        try { handle = SteamClient.Apps.RegisterForAppDetails(appid, finish); } catch (e) { finish(null); }
        setTimeout(() => finish(null), 3000);
      });
      // Every game in the library once (a new one as it appears): Windows-only and no tool → Silo's tool.
      async function pass() {
        if (S.paused || S.running) return;
        S.running = true;
        try {
          for (const o of [...(appStore.allApps || [])]) {
            if (S.paused) break;
            if (!o || o.app_type !== 1 || S.checked.has(o.appid)) continue;
            const d = await details(o.appid);
            if (!d) continue;   // no answer: asked again next time
            S.checked.add(o.appid);
            const p = d.vecPlatforms || [];
            if (!p.includes('windows') || p.includes('osx') || p.includes('macos') || d.strCompatToolName) continue;
            try { SteamClient.Apps.SpecifyCompatTool(o.appid, S.tool); S.given.push(o.appid); } catch (e) {}
          }
        } finally { S.running = false; }
      }
      S.take = () => { const q = S.queue; S.queue = []; return q; };
      S.pause = on => { S.paused = !!on; return true; };
      if (S.timer) clearInterval(S.timer);
      S.timer = setInterval(pass, 5000);
      pass();
      return 'silo install v' + S.version + ': Silo for Windows-only games without a tool';
    })()
    """#
}
