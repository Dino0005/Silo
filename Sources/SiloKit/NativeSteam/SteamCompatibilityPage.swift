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
    public static let version = 10

    /// JavaScript that answers whether this version of the page is live in Steam.
    public static let probe = "String(window.__siloCompat && window.__siloCompat.version === \(version) && window.__siloCompat.installed === true)"

    /// Stops (true) or restarts (false) the script's timer — paused while a game runs, like the library filters.
    public static func pause(_ on: Bool) -> String {
        "String(!!(window.__siloCompat && window.__siloCompat.pause && window.__siloCompat.pause(\(on))))"
    }

    /// The script, with the installed tools and Silo's two game lists (`NativeSteamInstaller.windowsGameIDsInCache`).
    public static func script(tools: [(name: String, display: String)], windowsOnly: [UInt32], windowsBuild: [UInt32],
                              known: [UInt32] = []) -> String {
        func list(_ ids: [UInt32]) -> String { ids.sorted().map(String.init).joined(separator: ",") }
        let pairs = tools.map { [$0.name, $0.display] }
        let json = (try? JSONSerialization.data(withJSONObject: pairs)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        return template
            .replacingOccurrences(of: "__SILO_VERSION__", with: String(version))
            .replacingOccurrences(of: "__SILO_TOOLS__", with: json)
            .replacingOccurrences(of: "__SILO_WINDOWS_ONLY__", with: list(windowsOnly))
            .replacingOccurrences(of: "__SILO_WINDOWS_BUILD__", with: list(windowsBuild))
            .replacingOccurrences(of: "__SILO_KNOWN__", with: list(known))
            .replacingOccurrences(of: "__SILO_TOOL__", with: SiloCompatTool.name)
    }

    static let template = #"""
    (() => {
      const S = window.__siloCompat || (window.__siloCompat = {});
      S.version = __SILO_VERSION__;
      S.tools = __SILO_TOOLS__;            // [[name, display name], ...] installed in compatibilitytools.d
      S.winOnly = new Set([__SILO_WINDOWS_ONLY__]);
      S.win = new Set([__SILO_WINDOWS_BUILD__]);
      // A game Steam knows but Silo's lists above don't: the lists are read from appinfo.vdf when this script is put
      // into Steam, so a game bought since (Spider-Man 2, 2026-11-21) is in neither until Steam restarts. Its
      // platforms come from Steam itself, once (`vecPlatforms` of its app details — exact for such a game, which Silo
      // hasn't protected yet).
      S.known = new Set([__SILO_KNOWN__]);
      S.live = S.live || {};
      S.pendingLive = S.pendingLive || {};
      S.classify = appid => {
        if (S.known.has(appid) || appid in S.live) return Promise.resolve(S.live[appid]);
        if (S.pendingLive[appid]) return S.pendingLive[appid];
        return S.pendingLive[appid] = new Promise(resolve => {
          let done = false, handle = null;
          const finish = d => {
            if (done) return;
            done = true;
            try { handle && handle.unregister(); } catch (e) {}
            const p = (d && d.vecPlatforms) || [];
            const win = p.includes('windows'), mac = p.includes('osx') || p.includes('macos');
            const kind = !d ? undefined : win && !mac ? 'winOnly' : win ? 'win' : 'mac';
            if (kind) S.live[appid] = kind;
            if (kind === 'win' || kind === 'winOnly') S.win.add(appid);
            if (kind === 'winOnly') S.winOnly.add(appid);
            delete S.pendingLive[appid];
            resolve(kind);
          };
          try { handle = SteamClient.Apps.RegisterForAppDetails(appid, finish); } catch (e) { finish(null); }
          setTimeout(() => finish(null), 3000);
        });
      };
      // What an earlier injection learnt that way carries over (the lists above are rebuilt from the file).
      for (const [id, kind] of Object.entries(S.live)) {
        if (kind !== 'mac') S.win.add(Number(id));
        if (kind === 'winOnly') S.winOnly.add(Number(id));
      }
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
        shared: 'Sono le stesse impostazioni del gioco in Silo: cambiarle qui o in Silo è la stessa cosa.',
        performance: 'Prestazioni', sync: 'Sincronizzazione', msync: 'MSync (consigliato)', esync: 'ESync', off: 'Disattivato',
        avx: 'Supporto AVX (Rosetta)', hud: 'HUD prestazioni (FPS / frame time)', metalFX: 'Upscaling MetalFX',
        dxr: 'Ray tracing DirectX (M3 o successivi)', metalBackend: 'Backend Metal', metal4: 'Metal 4', metal3: 'Metal 3 (compatibilità)',
        perfNote: "MSync + Supporto AVX è la configurazione di base consigliata per Apple Silicon. L'HUD Prestazioni mostra FPS/frame time in tempo reale sul gioco. MetalFX aumenta gli FPS tramite upscaling; il ray tracing richiede un M3 o successivo. Backend Metal sceglie il renderer attraverso cui passa il percorso DirectX 12 di GPTK: Automatico segue la scelta predefinita di Apple — Metal 3 su macOS 26, Metal 4 su macOS 27 e successivi. Se un gioco è peggiorato dopo un aggiornamento di GPTK, prova prima Metal 3. Solo GPTK.",
        perfNoteDXMT: "MSync + Supporto AVX è la configurazione di base consigliata per Apple Silicon. L'HUD Prestazioni mostra FPS/frame time in tempo reale sul gioco. MetalFX aumenta gli FPS tramite upscaling; il ray tracing richiede un M3 o successivo.",
        rendering: 'Rendering', depthFix: 'Correzione profondità',
        depthNote: "Elimina i puntini bianchi sui personaggi in God of War: il gioco ridisegna la scena con un test di profondità esatto, che su Metal alcuni pixel non superano. Solo per God of War, da Steam o GOG. Funziona con GPTK e DXMT.",
        sm2Fix: 'Correzione Spider-Man 2',
        sm2Note: "Corregge i personaggi bloccati in T-pose, le teste mancanti e il simbionte sui Mac M1–M4 (la correzione di macprotips). Silo la mette nella cartella del gioco prima di ogni avvio e ne ricostruisce gli shader dalla tua copia del gioco; la prima volta scarica gli strumenti shader di Microsoft (6 MB). Se la disattivi, la cartella torna com'era. Solo GPTK.",
        unchartedFix: 'Correzione Uncharted',
        unchartedNote: "Corregge il crash quando esci dal menu del gioco, e la richiesta della modalità provvisoria che lasciava all'avvio successivo: il gioco rilascia alcune texture una volta di troppo, e Silo le tiene in vita un istante in più perché quel rilascio non faccia danni. Silo mette un piccolo d3d12.dll suo nella cartella del gioco prima di ogni avvio; disattivata, lo toglie. Solo GPTK.",
        dualSense: 'DualSense', dsWired: 'DualSense Bluetooth come via cavo', dsActuators: 'Vibrazione sugli attuatori HD',
        dsXInput: 'DualSense come controller XInput',
        dsNote: 'Con Steam Input spento per il gioco: allora è Wine a leggere il DualSense. Da MacGameFix, di Mathias Kowoll.',
        controllers: 'Controller (Steam per macOS)', hidraw: 'Disattiva hidraw',
        hidrawNote: 'Quando Steam Input gestisce un controller, Silo lo nasconde al gioco, così i due non lo usano insieme, e il gioco riceve invece il controller virtuale di Steam, come controller Xbox (i giochi che chiedono a Steam il tipo di controller mostrano comunque i simboli PlayStation). «Disattiva hidraw» fa leggere ogni controller tramite SDL (simboli Xbox), per un pad che non funziona bene: usalo con Steam Input disattivato.',
        mf: 'Media Foundation', mfToggle: 'Esegui nella bottiglia Media Foundation',
        mfNote: 'Per i giochi i cui video interni restano neri. Ha effetto al prossimo avvio. Le cartelle di salvataggio da condividere con quella bottiglia si scelgono in Silo.'
      } : {
        macOnly: 'This game has no Windows version.',
        winOnly: 'Windows-only game: Steam installs and starts it with the chosen tool.',
        dual: 'Default: Steam installs the Mac version. With a tool, Steam installs and starts the Windows version (the installed one is replaced).',
        silo: 'Silo', graphics: 'Graphics backend', auto: 'Automatic',
        graphicsNote: "Automatic picks the best translation layer per game — 32-bit games use DXMT, others start on GPTK / D3DMetal and switch to DXMT if GPTK can't run them. Using DXMT requires installing it in Settings → DXMT. Takes effect next launch.",
        learned: b => 'Automatic is using ' + b + " — GPTK couldn't run this game.",
        shared: "These are the game's settings in Silo: changing them here or in Silo is the same.",
        performance: 'Performance', sync: 'Sync', msync: 'MSync (recommended)', esync: 'ESync', off: 'Off',
        avx: 'Advertise AVX (Rosetta)', hud: 'Performance HUD (FPS / frame time)', metalFX: 'MetalFX upscaling',
        dxr: 'DirectX Raytracing (M3+)', metalBackend: 'Metal backend', metal4: 'Metal 4', metal3: 'Metal 3 (compatibility)',
        perfNote: "MSync + advertise-AVX is the recommended Apple-Silicon baseline. The Performance HUD overlays live FPS/frame time on the game. MetalFX upscales for more FPS; Raytracing needs an M3 or newer. Metal backend picks the renderer GPTK's DirectX 12 path translates through: Automatic follows Apple's default — Metal 3 on macOS 26, Metal 4 on macOS 27 and later. If a game regressed after a GPTK update, try Metal 3 first. GPTK only.",
        perfNoteDXMT: 'MSync + advertise-AVX is the recommended Apple-Silicon baseline. The Performance HUD overlays live FPS/frame time on the game. MetalFX upscales for more FPS; Raytracing needs an M3 or newer.',
        rendering: 'Rendering', depthFix: 'Depth fix',
        depthNote: "Fixes white specks on characters in God of War: the game redraws the scene with an exact depth test, which a few pixels fail on Metal. God of War only, from Steam or GOG. Works with GPTK and DXMT.",
        sm2Fix: 'Spider-Man 2 fix',
        sm2Note: "Fixes characters stuck in a T-pose, missing heads and the symbiote on M1–M4 Macs (macprotips' fix). Silo puts it in the game's folder before each launch and rebuilds its shaders from your copy of the game; the first time, it downloads Microsoft's shader tools (6 MB). Turned off, the folder goes back to how the game shipped it. GPTK only.",
        unchartedFix: 'Uncharted fix',
        unchartedNote: "Fixes the crash when you quit from the game's menu, and the safe-mode prompt it left for the next start: the game releases some textures one time too many, and Silo keeps them alive a moment longer so the extra release does no harm. Silo puts a small d3d12.dll of its own in the game's folder before each launch; turned off, it takes it away. GPTK only.",
        dualSense: 'DualSense', dsWired: 'Bluetooth DualSense as wired', dsActuators: 'Rumble on the HD actuators',
        dsXInput: 'DualSense as an XInput controller',
        dsNote: 'With Steam Input off for the game: then Wine reads the DualSense itself. From MacGameFix, by Mathias Kowoll.',
        controllers: 'Controllers (macOS Steam)', hidraw: 'Disable hidraw',
        hidrawNote: "While Steam Input handles a controller, Silo hides it from the game so the two don't drive it together, and the game gets Steam's virtual controller instead, as an Xbox controller (games that ask Steam for the controller type still show PlayStation glyphs). \"Disable hidraw\" reads every controller through SDL (Xbox glyphs), for a pad that misbehaves — use it with Steam Input off.",
        mf: 'Media Foundation', mfToggle: 'Run in the Media Foundation bottle',
        mfNote: 'For games whose in-game videos come up black. Takes effect next launch. The save folders to share with that bottle are chosen in Silo.'
      };
      S.defaults = S.defaults || {};
      const valueOf = (appid, key) => {
        const g = S.settings[String(appid)];
        if (g && g[key] != null) return g[key];
        return S.defaults[key] != null ? S.defaults[key] : '';
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
        await S.classify(appid);   // a game bought since Steam started isn't in the lists yet
        const d = await details(appid);
        const current = (d && d.strCompatToolName) || '';
        const kind = S.winOnly.has(appid) ? 'winOnly' : S.win.has(appid) ? 'dual' : 'macOnly';
        const el = (tag, cls, text) => { const n = doc.createElement(tag); if (cls) n.className = cls; if (text != null) n.textContent = text; return n; };
        const page = el('div', 'DialogContent _DialogLayout');
        page.dataset.siloCompatPage = '1';
        page.setAttribute('role', 'tabpanel');
        // Steam's page background with its light turned the other way (bottom left instead of top left), so the page
        // darkens upwards like the sidebar beside it (user, 2026-11-21). Steam's own pages keep theirs.
        page.style.background = 'radial-gradient(circle at bottom left, rgba(74, 81, 92, 0.4) 0%, rgba(75, 81, 92, 0) 60%), #25282e';
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

      // Checkboxes drawn by hand: the native one is white when off, which jumps out of Steam's dark page. Off = Steam's
      // background (#181D24, sampled from Steam by the user) with a thin border; on = Steam's blue with a black tick, as the native one drew it.
      function ensureCheckStyle(doc) {
        if (doc.getElementById('silo-check-style')) return;
        const st = doc.createElement('style');
        st.id = 'silo-check-style';
        st.textContent = `
          input.silo-check { -webkit-appearance: none; appearance: none; margin: 0; width: 18px; height: 18px;
            border-radius: 3px; border: 1px solid #4b5059; background: #181d24; cursor: pointer; flex: none; }
          input.silo-check:hover { border-color: #8b929a; }
          input.silo-check:checked { border-color: #1a9fff; background: #1a9fff center / 12px 12px no-repeat
            url("data:image/svg+xml;utf8,<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 12 12'><path d='M2 6.2l2.6 2.6L10 3.4' fill='none' stroke='black' stroke-width='2' stroke-linecap='round' stroke-linejoin='round'/></svg>"); }
          input.silo-check:focus-visible { outline: 2px solid #1a9fff; outline-offset: 2px; }`;
        (doc.head || doc.documentElement).append(st);
      }

      // The "Silo" section: the game's own Silo settings, shown while Silo is its tool — the same groups, labels and
      // notes as Silo's settings sheet for the game.
      function siloSection(doc, appid, el) {
        const box = el('div');
        box.dataset.siloSettings = '1';
        const refreshers = [];
        const header = text => {
          const h = el('div', null, text);
          h.style.cssText = 'font-size:12px;text-transform:uppercase;letter-spacing:.06em;color:#8b929a;margin:28px 0 6px';
          box.append(h);
        };
        const noteEl = () => {
          const n = el('div');
          n.style.cssText = 'color:#8b929a;font-size:12px;margin-top:8px;line-height:1.4';
          box.append(n);
          return n;
        };
        const rowEl = label => {
          const row = el('div');
          row.style.cssText = 'display:flex;align-items:center;justify-content:space-between;gap:16px;padding:9px 0;border-bottom:1px solid rgba(255,255,255,.08)';
          const l = el('div', null, label);
          l.style.cssText = 'color:#fff;font-size:14px';
          row.append(l);
          box.append(row);
          return row;
        };
        const change = (key, value) => {
          const k = String(appid);
          S.settings[k] = Object.assign({}, S.defaults, S.settings[k] || {}, { [key]: value });
          S.changes.push({ appid, key, value });
          refreshers.forEach(f => f());
        };
        const picker = (key, label, options) => {
          const row = rowEl(label);
          const select = el('select');
          select.style.cssText = 'min-width:220px;padding:6px 10px;background:#32353c;color:#fff;border:1px solid #4b5059;border-radius:3px;font-size:13px';
          for (const [value, text] of options) { const o = el('option', null, text); o.value = value; select.append(o); }
          select.addEventListener('change', () => change(key, select.value));
          row.append(select);
          refreshers.push(() => { select.value = valueOf(appid, key); });
          return row;
        };
        const toggle = (key, label) => {
          const row = rowEl(label);
          const box2 = el('input');
          box2.type = 'checkbox';
          box2.className = 'silo-check';
          ensureCheckStyle(doc);
          box2.addEventListener('change', () => change(key, box2.checked ? '1' : '0'));
          row.append(box2);
          refreshers.push(() => { box2.checked = valueOf(appid, key) === '1'; });
          return row;
        };

        header(T.silo);
        picker('graphics', T.graphics, [['auto', T.auto], ['gptk', 'GPTK / D3DMetal'], ['dxmt', 'DXMT']]);
        const graphicsNote = noteEl();
        refreshers.push(() => {
          const learned = valueOf(appid, 'learned');
          graphicsNote.textContent = valueOf(appid, 'graphics') === 'auto' && learned ? T.learned(learned) : T.graphicsNote;
        });

        header(T.performance);
        picker('syncMode', T.sync, [['msync', T.msync], ['esync', T.esync], ['none', T.off]]);
        toggle('advertiseAVX', T.avx);
        toggle('metalHUD', T.hud);
        toggle('metalFX', T.metalFX);
        toggle('dxr', T.dxr);
        // Like Silo's sheet: the Metal backend is a D3DMetal option, so it isn't offered under DXMT.
        const metalRow = picker('metalBackend', T.metalBackend, [['auto', T.auto], ['metal4', T.metal4], ['metal3', T.metal3]]);
        const perfNote = noteEl();
        refreshers.push(() => {
          const dxmt = valueOf(appid, 'graphics') === 'dxmt';
          metalRow.style.display = dxmt ? 'none' : 'flex';
          perfNote.textContent = dxmt ? T.perfNoteDXMT : T.perfNote;
        });

        // Each fix is offered for its own game only; the section only when the game has one.
        if (appid === 1593500 || appid === 2651280 || appid === 1659420) header(T.rendering);
        // God of War only (DepthFix.steamAppID).
        if (appid === 1593500) {
          toggle('depthFix', T.depthFix);
          noteEl().textContent = T.depthNote;
        }
        // Marvel's Spider-Man 2 only (SpiderMan2Fix.appID).
        if (appid === 2651280) {
          toggle('spiderMan2Fix', T.sm2Fix);
          noteEl().textContent = T.sm2Note;
        }
        // UNCHARTED: Legacy of Thieves Collection only (UnchartedFix.appID).
        if (appid === 1659420) {
          toggle('unchartedFix', T.unchartedFix);
          noteEl().textContent = T.unchartedNote;
        }

        header(T.controllers);
        toggle('disableHidraw', T.hidraw);
        noteEl().textContent = T.hidrawNote;
        header(T.dualSense);
        toggle('dualSenseBluetoothAsWired', T.dsWired);
        toggle('dualSenseRumbleOnActuators', T.dsActuators);
        toggle('dualSenseAsXInput', T.dsXInput);
        noteEl().textContent = T.dsNote;

        // Only once the Media Foundation bottle exists, like Silo's sheet.
        const mfBox = el('div'); box.append(mfBox);
        const mfStart = box.children.length;
        header(T.mf);
        toggle('mediaFoundationNative', T.mfToggle);
        noteEl().textContent = T.mfNote;
        const mfParts = [...box.children].slice(mfStart);
        mfParts.forEach(n => mfBox.append(n));
        refreshers.push(() => { mfBox.style.display = S.mediaFoundation ? '' : 'none'; });

        const shared = el('div', null, T.shared);
        shared.style.cssText = 'color:#8b929a;font-size:12px;margin-top:22px;line-height:1.4;font-style:italic';
        box.append(shared);

        box.__siloRefresh = () => refreshers.forEach(f => f());
        box.__siloRefresh();
        return box;
      }

      // New values from the guard (config.json changed): every open Silo section shows them.
      S.setSettings = payload => {
        payload = payload || {};
        S.settings = payload.games || {};
        S.defaults = payload.defaults || {};
        S.mediaFoundation = !!payload.mediaFoundation;
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
