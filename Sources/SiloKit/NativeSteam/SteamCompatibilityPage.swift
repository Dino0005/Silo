import Foundation

/// A "Compatibility" page in the Properties of every game in macOS Steam, where the Linux client has one and the Mac
/// client doesn't: Steam builds that page only when `PLATFORM == "linux"` (measured 2026-11-20 in `steamui/sp.js`), and
/// its own component couldn't fill it anyway — it asks `CompatManager.GetCompatTools`, which macOS Steam has no handler
/// for. What does work on the Mac is the mapping itself: `SteamClient.Apps.SpecifyCompatTool`, as Silo already uses it
/// (`SteamCompatMapping`), and each game's app details carry the current tool (`strCompatToolName`).
///
/// That mapping is how a game with BOTH a Mac and a Windows build gets its Windows one: with a tool forced, Steam
/// installs the Windows depots (measured on Rise of the Tomb Raider, not installed: Install proposed 24.23 GB with no
/// tool, 26.42 GB with Silo) — the way CrossOver documents it for its own tool. "Default" goes back to the Mac build.
///
/// Injected by the guard through `SteamCEFClient` into the SharedJSContext, which renders every Steam window: a timer
/// finds the Properties windows (`g_PopupManager`), adds the tab after "General" (a clone of Steam's own, so it has
/// its look) and, while it is chosen, shows Silo's page in place of Steam's. Labels are Steam's own localized strings
/// (`LocalizationManager`); the notes under the menu are Silo's, in Italian or English like Steam's language.
/// The choices: Default (games with a Mac build) and the tools installed in `compatibilitytools.d`; a Mac-only game
/// gets the page with the menu disabled. A Windows-only game set to Default is mapped back to Silo by the guard.
public enum SteamCompatibilityPage {
    /// Bumped whenever the script changes, so a running Steam gets the new one.
    public static let version = 2

    /// JavaScript that answers whether this version of the page is live in Steam.
    public static let probe = "String(window.__siloCompat && window.__siloCompat.version === \(version) && window.__siloCompat.installed === true)"

    /// Stops (true) or restarts (false) the script's timer — paused while a game runs, like the library filters.
    public static func pause(_ on: Bool) -> String {
        "String(!!(window.__siloCompat && window.__siloCompat.pause && window.__siloCompat.pause(\(on))))"
    }

    /// The script, with the installed tools and Silo's two game lists (`NativeSteamInstaller.windowsGameIDsInCache`).
    public static func script(tools: [(name: String, display: String)], windowsOnly: [UInt32], windowsBuild: [UInt32]) -> String {
        func list(_ ids: [UInt32]) -> String { ids.sorted().map(String.init).joined(separator: ",") }
        let pairs = tools.map { [$0.name, $0.display] }
        let json = (try? JSONSerialization.data(withJSONObject: pairs)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        return template
            .replacingOccurrences(of: "__SILO_VERSION__", with: String(version))
            .replacingOccurrences(of: "__SILO_TOOLS__", with: json)
            .replacingOccurrences(of: "__SILO_WINDOWS_ONLY__", with: list(windowsOnly))
            .replacingOccurrences(of: "__SILO_WINDOWS_BUILD__", with: list(windowsBuild))
            .replacingOccurrences(of: "__SILO_TOOL__", with: SiloCompatTool.name)
    }

    static let template = #"""
    (() => {
      const S = window.__siloCompat || (window.__siloCompat = {});
      S.version = __SILO_VERSION__;
      S.tools = __SILO_TOOLS__;            // [[name, display name], ...] installed in compatibilitytools.d
      S.winOnly = new Set([__SILO_WINDOWS_ONLY__]);
      S.win = new Set([__SILO_WINDOWS_BUILD__]);
      S.siloTool = '__SILO_TOOL__';
      // Each game's Silo settings (SteamGameSettings), handed over by the guard; the changes made here wait in
      // S.changes until the guard writes them to Silo's config.json.
      S.settings = S.settings || {};
      S.changes = S.changes || [];
      const it = /LANGUAGE=italian/.test(location.href);
      const T = it ? {
        macOnly: 'Questo gioco non ha una versione per Windows.',
        winOnly: 'Gioco solo per Windows: Steam lo installa e lo avvia con lo strumento scelto.',
        dual: 'Predefinito: Steam installa la versione per Mac. Con uno strumento, Steam installa e avvia la versione per Windows (quella installata viene sostituita).',
        silo: 'Silo', graphics: 'Backend grafico', auto: 'Automatico',
        graphicsNote: 'La modalità automatica sceglie il miglior livello di traduzione per ogni gioco — i giochi a 32 bit usano DXMT, gli altri partono con GPTK / D3DMetal e passano a DXMT se GPTK non riesce ad avviarli. Per usare DXMT è necessario installarlo in Impostazioni → DXMT. Ha effetto al prossimo avvio.',
        learned: b => 'La modalità automatica sta usando ' + b + ' — GPTK non è riuscito ad avviare questo gioco.',
        shared: 'Sono le stesse impostazioni del gioco in Silo: cambiarle qui o in Silo è la stessa cosa.'
      } : {
        macOnly: 'This game has no Windows version.',
        winOnly: 'Windows-only game: Steam installs and starts it with the chosen tool.',
        dual: 'Default: Steam installs the Mac version. With a tool, Steam installs and starts the Windows version (the installed one is replaced).',
        silo: 'Silo', graphics: 'Graphics backend', auto: 'Automatic',
        graphicsNote: "Automatic picks the best translation layer per game — 32-bit games use DXMT, others start on GPTK / D3DMetal and switch to DXMT if GPTK can't run them. Using DXMT requires installing it in Settings → DXMT. Takes effect next launch.",
        learned: b => 'Automatic is using ' + b + " — GPTK couldn't run this game.",
        shared: "These are the game's settings in Silo: changing them here or in Silo is the same."
      };
      const DEFAULTS = { graphics: 'auto', learned: '' };
      const valueOf = (appid, key) => {
        const g = S.settings[String(appid)];
        return g && g[key] != null ? g[key] : DEFAULTS[key];
      };
      const L = (token, fallback) => {
        try { const s = window.LocalizationManager.LocalizeString(token); if (s && s !== token) return s; } catch (e) {}
        return fallback;
      };
      const details = appid => new Promise(resolve => {
        let done = false, handle = null;
        const finish = d => { if (done) return; done = true; try { handle && handle.unregister(); } catch (e) {} resolve(d); };
        handle = SteamClient.Apps.RegisterForAppDetails(appid, d => finish(d));
        setTimeout(() => finish(null), 3000);
      });

      // One Properties window: Silo's tab after "General", and its page in place of Steam's while it is chosen.
      function attach(doc) {
        const nav = doc.querySelector('[role=tablist][aria-orientation=vertical]');
        if (!nav) return;
        const tabs = [...nav.children].filter(t => !t.dataset.siloCompat);
        const general = tabs.find(t => /\/properties\/general$/.test(t.id || ''));
        if (!general) return;
        const appid = Number((general.id.match(/\/app\/(\d+)\/properties\//) || [])[1]);
        if (!appid) return;
        const W = doc.defaultView;
        const st = W.__siloCompatState || (W.__siloCompatState = { active: false });
        let mine = nav.querySelector('[data-silo-compat]');
        if (!mine) {
          // Cloned from a tab that isn't selected, so it starts with the plain look.
          mine = (tabs.find(t => t.getAttribute('aria-selected') !== 'true') || general).cloneNode(true);
          mine.dataset.siloCompat = '1';
          for (const n of [mine, ...mine.querySelectorAll('*')]) {
            n.removeAttribute('id'); n.removeAttribute('aria-controls'); n.setAttribute('aria-selected', 'false');
          }
          (mine.firstElementChild || mine).textContent = L('#AppProperties_CompatibilityPage', it ? 'Compatibilità' : 'Compatibility');
          general.after(mine);
          mine.addEventListener('click', e => { e.stopPropagation(); open(doc, appid); }, true);
          nav.addEventListener('click', e => {
            const tab = e.target.closest('[role=tab]');
            if (tab && !tab.closest('[data-silo-compat]')) close(doc);
          }, true);
        }
        if (st.active) keepShown(doc);
      }

      function styles(doc) {
        const nav = doc.querySelector('[role=tablist][aria-orientation=vertical]');
        const tabs = [...nav.children].filter(t => !t.dataset.siloCompat);
        const sel = tabs.find(t => t.getAttribute('aria-selected') === 'true');
        const other = tabs.find(t => t.getAttribute('aria-selected') !== 'true');
        const selClass = sel && other ? [...sel.classList].filter(c => !other.classList.contains(c)) : [];
        return { nav, sel, other, selClass };
      }

      function contentHost(doc) {
        const panel = doc.querySelector('[role=tabpanel]:not([data-silo-compat-page])');
        return panel ? panel.parentElement : null;
      }

      function keepShown(doc) {
        const st = doc.defaultView.__siloCompatState;
        const host = contentHost(doc), page = st && st.page;
        if (!host || !page) return;
        if (page.parentElement !== host) host.appendChild(page);
        for (const c of host.children) if (c !== page) c.style.display = 'none';
      }

      async function open(doc, appid) {
        const W = doc.defaultView, st = W.__siloCompatState;
        const { nav, sel, other, selClass } = styles(doc);
        const mine = nav.querySelector('[data-silo-compat]');
        if (!st.active) {
          st.active = true;
          st.reactSelected = sel;
          if (sel && other) {
            const co = W.getComputedStyle(other), ci = W.getComputedStyle(other.firstElementChild || other);
            sel.style.background = co.backgroundColor; sel.style.color = co.color;
            if (sel.firstElementChild) sel.firstElementChild.style.color = ci.color;
          }
          st.added = selClass.filter(c => !mine.classList.contains(c));
          mine.classList.add(...st.added);
          mine.setAttribute('aria-selected', 'true');
        }
        if (!st.page) st.page = await buildPage(doc, appid);
        if (st.active) keepShown(doc);
      }

      function close(doc) {
        const W = doc.defaultView, st = W.__siloCompatState;
        if (!st || !st.active) return;
        st.active = false;
        const nav = doc.querySelector('[role=tablist][aria-orientation=vertical]');
        const mine = nav && nav.querySelector('[data-silo-compat]');
        if (mine) {
          mine.setAttribute('aria-selected', 'false');
          mine.classList.remove(...(st.added || []));
        }
        if (st.reactSelected) {
          st.reactSelected.style.background = ''; st.reactSelected.style.color = '';
          if (st.reactSelected.firstElementChild) st.reactSelected.firstElementChild.style.color = '';
        }
        if (st.page) { st.page.remove(); st.page = null; }
        const host = contentHost(doc);
        if (host) for (const c of host.children) c.style.display = '';
      }

      async function buildPage(doc, appid) {
        const d = await details(appid);
        const current = (d && d.strCompatToolName) || '';
        const kind = S.winOnly.has(appid) ? 'winOnly' : S.win.has(appid) ? 'dual' : 'macOnly';
        const el = (tag, cls, text) => { const n = doc.createElement(tag); if (cls) n.className = cls; if (text != null) n.textContent = text; return n; };
        const page = el('div', 'DialogContent _DialogLayout');
        page.dataset.siloCompatPage = '1';
        page.setAttribute('role', 'tabpanel');
        const inner = el('div', 'DialogContent_InnerWidth');
        inner.append(el('div', 'DialogHeader', L('#AppProperties_CompatibilityPage', it ? 'Compatibilità' : 'Compatibility')));
        const body = el('div', 'DialogBody');
        const section = el('div', null, L('#Settings_SteamPlay_SteamPlay', 'Steam Play'));
        section.style.cssText = 'font-size:12px;text-transform:uppercase;letter-spacing:.06em;color:#8b929a;margin:4px 0 14px';
        const row = el('div');
        row.style.cssText = 'display:flex;align-items:center;justify-content:space-between;gap:16px;padding:10px 0;border-bottom:1px solid rgba(255,255,255,.08)';
        const label = el('div', null, L('#AppProperties_Compat_SelectTool', it ? 'Scegli strumento di compatibilità' : 'Choose compatibility tool'));
        label.style.cssText = 'color:#fff;font-size:14px';
        const select = el('select');
        select.style.cssText = 'min-width:220px;padding:6px 10px;background:#32353c;color:#fff;border:1px solid #4b5059;border-radius:3px;font-size:13px';
        const add = (value, text) => { const o = el('option', null, text); o.value = value; select.append(o); };
        if (kind !== 'winOnly') add('', L('#Settings_SteamPlay_DefaultToolEntry_Fallback', it ? 'Predefinito' : 'Default'));
        if (kind !== 'macOnly') for (const [name, display] of S.tools) add(name, display);
        if (current && ![...select.options].some(o => o.value === current)) add(current, (d && d.strCompatToolDisplayName) || current);
        select.value = current;
        select.disabled = kind === 'macOnly';
        const silo = siloSection(doc, appid, el);
        const showSilo = () => { silo.style.display = select.value === S.siloTool ? '' : 'none'; };
        select.addEventListener('change', () => {
          try { SteamClient.Apps.SpecifyCompatTool(appid, select.value); } catch (e) {}
          showSilo();
        });
        row.append(label, select);
        const note = el('div', null, T[kind]);
        note.style.cssText = 'color:#8b929a;font-size:12px;margin-top:10px;line-height:1.4';
        showSilo();
        body.append(section, row, note, silo);
        inner.append(body);
        page.append(inner);
        return page;
      }

      // The "Silo" section: the game's own Silo settings, shown while Silo is its tool.
      function siloSection(doc, appid, el) {
        const box = el('div');
        box.dataset.siloSettings = '1';
        const header = el('div', null, T.silo);
        header.style.cssText = 'font-size:12px;text-transform:uppercase;letter-spacing:.06em;color:#8b929a;margin:28px 0 14px';
        const row = el('div');
        row.style.cssText = 'display:flex;align-items:center;justify-content:space-between;gap:16px;padding:10px 0;border-bottom:1px solid rgba(255,255,255,.08)';
        const label = el('div', null, T.graphics);
        label.style.cssText = 'color:#fff;font-size:14px';
        const select = el('select');
        select.style.cssText = 'min-width:220px;padding:6px 10px;background:#32353c;color:#fff;border:1px solid #4b5059;border-radius:3px;font-size:13px';
        for (const [value, text] of [['auto', T.auto], ['gptk', 'GPTK / D3DMetal'], ['dxmt', 'DXMT']]) {
          const o = el('option', null, text); o.value = value; select.append(o);
        }
        const note = el('div');
        note.style.cssText = 'color:#8b929a;font-size:12px;margin-top:10px;line-height:1.4';
        const shared = el('div', null, T.shared);
        shared.style.cssText = 'color:#8b929a;font-size:12px;margin-top:14px;line-height:1.4;font-style:italic';
        const refresh = () => {
          select.value = valueOf(appid, 'graphics');
          const learned = valueOf(appid, 'learned');
          note.textContent = select.value === 'auto' && learned ? T.learned(learned) : T.graphicsNote;
        };
        select.addEventListener('change', () => {
          const key = String(appid);
          S.settings[key] = Object.assign({}, S.settings[key] || DEFAULTS, { graphics: select.value });
          S.changes.push({ appid, key: 'graphics', value: select.value });
          refresh();
        });
        box.__siloRefresh = refresh;
        refresh();
        row.append(label, select);
        box.append(header, row, note, shared);
        return box;
      }

      // New values from the guard (config.json changed): every open Silo section shows them.
      S.setSettings = values => {
        S.settings = values || {};
        try {
          for (const p of window.g_PopupManager.GetPopups()) {
            const d = p.m_popup && p.m_popup.document; if (!d) continue;
            for (const box of d.querySelectorAll('[data-silo-settings]')) if (box.__siloRefresh) box.__siloRefresh();
          }
        } catch (e) {}
        return true;
      };
      S.takeChanges = () => { const c = S.changes; S.changes = []; return c; };

      // A new version replaces the old one's tabs and pages (their listeners belong to the old script).
      try {
        for (const p of window.g_PopupManager.GetPopups()) {
          const d = p.m_popup && p.m_popup.document; if (!d) continue;
          if (d.defaultView.__siloCompatState) close(d);
          for (const n of d.querySelectorAll('[data-silo-compat],[data-silo-compat-page]')) n.remove();
          d.defaultView.__siloCompatState = null;
        }
      } catch (e) {}
      S.pause = on => { S.paused = !!on; return true; };
      if (S.timer) clearInterval(S.timer);
      S.timer = setInterval(() => {
        if (S.paused) return;
        try {
          for (const p of window.g_PopupManager.GetPopups()) {
            const w = p.m_popup; if (!w || !w.document) continue;
            attach(w.document);
          }
        } catch (e) {}
      }, 500);
      S.installed = true;
      return 'silo compat page v' + S.version + ' (' + S.tools.length + ' tools)';
    })()
    """#
}
