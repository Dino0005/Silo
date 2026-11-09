import Foundation

/// Silo's two library filter buttons inside macOS Steam — an Apple one (games with a native Mac build) and a
/// Windows one (games with a Windows build, including those that have a Mac one too) — in place of Steam's own
/// Apple button, which counts every game Silo protects as a Mac game (they carry `oslist macos`, see
/// `AppInfoPatcher.protectWindowsInstall`). Neither on: every game.
///
/// Injected through Steam's CEF debugging port (`SteamCEFClient`) into its SharedJSContext, where the library
/// lives. It reuses Steam's own "works on this platform" filter (measured 2026-11-09: that filter is
/// `is_available_on_current_platform && !is_invalid_os_type` on the app overview): while a Silo filter is on,
/// Steam's filter is switched on and the overview getter `is_available_on_current_platform` — a protobuf field
/// name, stable across UI builds — answers for the chosen side; with both off it is Steam's again. Steam's own
/// button stays in the page, hidden, and is driven by clicks; Silo's buttons are clones of it, so they match
/// Steam's look. A timer puts them back if React re-renders the row.
public enum SteamLibraryFilters {
    /// Bumped whenever the script changes, so a running Steam gets the new one.
    public static let version = 4

    /// The file that makes Steam open its CEF debugging port (127.0.0.1:8080) at every start, in the folder
    /// of the `steam_osx` binary (measured 2026-11-09; the same file in Steam's data folder does nothing).
    public static func debugPortMarker(steamRoot: URL) -> URL {
        steamRoot.appendingPathComponent("Steam.AppBundle/Steam/Contents/MacOS/.cef-enable-remote-debugging")
    }

    /// Creates the marker if Steam's program folder exists (a Steam update may replace the folder: the guard
    /// re-creates it after every Steam exit). Returns whether it is in place.
    @discardableResult
    public static func enableDebugPort(steamRoot: URL, fileManager: FileManager = .default) -> Bool {
        let marker = debugPortMarker(steamRoot: steamRoot)
        guard fileManager.fileExists(atPath: marker.deletingLastPathComponent().path) else { return false }
        if fileManager.fileExists(atPath: marker.path) { return true }
        return fileManager.createFile(atPath: marker.path, contents: Data())
    }

    /// JavaScript that answers whether this version of the filters is live in the page.
    public static let probe = "String(window.__siloFilters && window.__siloFilters.version === \(version) && window.__siloFilters.installed === true)"

    /// The script, with Silo's two lists: `windowsOnly` — Windows games without a Mac build of their own
    /// (`AppInfoPatcher.isWindowsGame`), kept off the Apple side even though Silo marks them `macos` — and
    /// `windowsBuild` — every game with a Windows build (the Windows side).
    public static func script(windowsOnly: [UInt32], windowsBuild: [UInt32]) -> String {
        func list(_ ids: [UInt32]) -> String { ids.sorted().map(String.init).joined(separator: ",") }
        return template
            .replacingOccurrences(of: "__SILO_VERSION__", with: String(version))
            .replacingOccurrences(of: "__SILO_WINDOWS_ONLY__", with: list(windowsOnly))
            .replacingOccurrences(of: "__SILO_WINDOWS_BUILD__", with: list(windowsBuild))
    }

    static let template = #"""
    (() => {
      const S = window.__siloFilters || (window.__siloFilters = {});
      S.version = __SILO_VERSION__;
      S.winOnly = new Set([__SILO_WINDOWS_ONLY__]);
      S.win = new Set([__SILO_WINDOWS_BUILD__]);
      if (S.mode === undefined) S.mode = null;
      const it = /LANGUAGE=italian/.test(location.href);
      const TITLE = { mac: it ? 'Mostra solo i giochi macOS' : 'Show only macOS games',
                      win: it ? 'Mostra solo i giochi Windows' : 'Show only Windows games' };

      // The overview getter Steam's platform filter reads; Silo answers for the chosen side while a filter is on.
      const sample = appStore.GetAppOverviewByAppID(570) || [...(appStore.allApps || [])][0];
      if (!sample) return 'no app overviews yet';
      const proto = Object.getPrototypeOf(sample);
      // Steam's own getter is saved once; the wrapper is redefined on every injection, so a newer script's
      // rule replaces an older one's.
      if (!S.origGetter) {
        const d = Object.getOwnPropertyDescriptor(proto, 'is_available_on_current_platform');
        if (!d || !d.get) return 'no platform getter';
        S.origGetter = d.get;
      }
      {
        Object.defineProperty(proto, 'is_available_on_current_platform', {
          configurable: true,
          get() {
            const steam = S.origGetter.call(this);
            if (S.mode === 'mac') return !!steam && !S.winOnly.has(this.appid);
            if (S.mode === 'win') return S.win.has(this.appid);
            return steam;
          },
        });
      }

      const doc = () => {
        const p = window.g_PopupManager && g_PopupManager.GetExistingPopup('SP Desktop_uid0');
        return p && p.m_popup && p.m_popup.document;
      };
      const steamButton = (d) => {
        const svg = d.querySelector('svg.SVGIcon_AppleLogo:not(.SiloIcon)');
        return svg && svg.parentElement;
      };
      // Steam marks an active toggle with one extra class; the classes all toggles share are the inactive set.
      const baseClasses = (b) => {
        const shared = [...b.parentElement.children]
          .filter((e) => e !== b && !e.classList.contains('SiloFilter') && e.querySelector('svg'))
          .map((e) => new Set(e.classList));
        return shared.length ? shared.reduce((a, s) => new Set([...a].filter((c) => s.has(c)))) : null;
      };
      const steamActive = (b) => {
        const base = baseClasses(b);
        return base ? [...b.classList].some((c) => !base.has(c)) : b.classList.length > 2;
      };
      const tick = () => new Promise((r) => setTimeout(r, 250));
      async function setSteam(d, on) {
        for (let i = 0; i < 8; i++) {
          const b = steamButton(d);
          if (!b || steamActive(b) === on) return;
          b.click();
          for (let j = 0; j < 8 && steamButton(d) && steamActive(steamButton(d)) !== on; j++) await tick();
        }
      }
      // Steam's stylesheet sets the icons' path fill itself (the Apple logo ignores `color`), so the active blue
      // goes on the paths too.
      function render(d) {
        for (const el of d.querySelectorAll('.SiloFilter')) {
          const on = el.dataset.mode === S.mode;
          el.style.opacity = on ? '1' : '';
          el.style.color = on ? '#1a9fff' : '';
          for (const p of el.querySelectorAll('svg path')) p.style.fill = on ? '#1a9fff' : '';
        }
      }
      // Off first, so Steam drops its cached result; then on, now answered by the getter for the new side.
      async function apply(d, mode) {
        if (S.busy) return;
        S.busy = true;
        try {
          await setSteam(d, false);
          S.mode = mode;
          if (mode !== null) await setSteam(d, true);
          render(d);
        } finally { S.busy = false; }
      }
      const WINDOWS_SVG = '<svg class="SVGIcon_Button SiloIcon SiloIcon_Windows" xmlns="http://www.w3.org/2000/svg" viewBox="0 0 36 36" fill="none"><path fill="currentColor" d="M4 7.5l12-1.7V17H4zM18 5.5L32 3.5V17H18zM4 19h12v11.2L4 28.5zM18 19h14v13.5L18 30.5z"/></svg>';
      function install() {
        const d = doc();
        if (!d) return;
        const b = steamButton(d);
        if (!b || b.parentElement.querySelector('.SiloFilter')) return;
        const make = (mode) => {
          const el = b.cloneNode(true);
          el.classList.add('SiloFilter');
          el.dataset.mode = mode;
          el.style.display = '';
          el.title = TITLE[mode];
          if (mode === 'win') el.innerHTML = WINDOWS_SVG;
          else el.querySelector('svg').classList.add('SiloIcon');
          // Clones carry Steam's look but none of its React handlers; drop the original's "active" class, if any.
          const base = baseClasses(b);
          if (base) for (const c of [...el.classList]) if (!base.has(c) && c !== 'SiloFilter') el.classList.remove(c);
          el.addEventListener('click', (e) => { e.preventDefault(); e.stopPropagation(); apply(d, S.mode === mode ? null : mode); }, true);
          return el;
        };
        b.style.display = 'none';
        b.after(make('win'));
        b.after(make('mac'));
        // A fresh row (a new window, or Steam's filter left on by the user) starts from "every game".
        if (S.mode === null && steamActive(b)) setSteam(d, false);
        render(d);
      }
      // A newer script replaces an older one's buttons and timer (their handlers belong to the old code).
      if (S.timer) clearInterval(S.timer);
      const d0 = doc();
      if (d0) for (const el of d0.querySelectorAll('.SiloFilter')) el.remove();
      install();
      S.timer = setInterval(install, 1000);
      S.installed = true;
      return 'silo filters v' + S.version + ': ' + S.win.size + ' with a Windows build, ' + S.winOnly.size + ' Windows-only';
    })()
    """#
}
