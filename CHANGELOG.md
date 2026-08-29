# Changelog

This fork's history. It starts at 0.5.0, the first release built on top of
[mikaelhug/Silo](https://github.com/mikaelhug/Silo); anything earlier belongs to upstream.

Upstream commits are integrated selectively — each one judged on its own, several deliberately left out
(DXVK is irrelevant to a library with no DirectX 9 titles). Where a port diverges from upstream's version,
the commit message says why.

## 0.5.6

### Changed
- **"Run Installer in this bottle…" is now "Run a Program in this bottle…"**, and appears in the tile's
  ••• menu as well. It always ran anything in the game's existing bottle — verified with a GOG language
  selector: same prefix, same executable, nothing new created — but its name and the picker's wording
  both suggested installers only. The completion status now reads "Run finished". The add-game screen's
  *Run Installer* keeps its name; there it really does install.
- **The Metal backend picker is hidden when the graphics choice is DXMT.** It sets `D3DM_MTL4`, a
  D3DMetal option that does nothing there. Automatic still shows it, since it resolves to GPTK for most
  games.

### Fixed
- **The DXMT/D3D12 warning no longer appears when `-d3d11` is already among the launch options** — it was
  recommending a remedy the user had already applied.
- **File-picker messages and the Choose button weren't translated.** `chooseExecutable` and
  `chooseDirectory` take them as plain `String`s, which never reach the strings table. All five messages
  and the button are localised; a search for every visible text passed that way confirms none is left.

## 0.5.5

### Fixed
- **The startup sweep removed CrossOver's leftover directories too.** `server-*` directories belong to
  whichever prefix made them, and 0.5.4's sweep judged them only by whether their lock was free. Measured
  with both apps installed: seven in `/tmp`, six of them CrossOver's, all gone after opening Silo. Silo
  now computes the names its own bottles would produce — from each prefix's device and inode — and
  ignores everything else. The leftover of a deleted bottle now stays, since without the prefix its name
  can't be derived.
- **The Media Foundation bottle wasn't in the list of bottles.** A game running there was invisible to
  both *Stop All Bottle Processes* and the quit prompt.

## 0.5.4

### Added
- **Silo → Stop All Bottle Processes**, for when a crash or a force-quit leaves something running and the
  only remedy was a terminal. Acts immediately — it's explicit, and chosen on purpose.
- **Quitting with something still running asks what to do**, defaulting to leaving it running: a game
  outliving Silo is deliberate, and the case it protects (quitting to free memory mid-game) is real. The
  prompt only appears when something is actually running.
- Both stop bottles with `wineserver -k` rather than killing processes, so the session ends the way it
  would on a normal shutdown instead of being cut off mid-write.

### Fixed
- **Leftover `server-*` directories are cleared at startup.** A wineserver that dies badly leaves one in
  `/tmp` and nothing removes it; they no longer block launches but they accumulate and make it impossible
  to tell, by looking, what's really running. A directory whose lock nobody holds is removed; one whose
  lock is held is left alone, whoever owns it. Startup only — sweeping at quit would pull the socket from
  under a game Silo deliberately let outlive it.
- The sweep waits a minute before touching anything, closing a race the tests surfaced: between creating
  its directory and taking its lock, a starting server's lock reads as free.

## 0.5.3

### Fixed
- **Tile artwork is cached on disk**, in `Artwork/` by app ID. The tile used to guess its image URL from
  the app ID and fetch it every time, so the library came up blank with no network — images are evicted
  from URLSession's cache long before JSON is. The stored file draws first and is refreshed behind it, at
  most once a day, and a failed refresh leaves the existing image alone.
- **Games whose `header.jpg` doesn't exist now get artwork.** The guessed address 404s for some apps
  (seen on 3764200) while their store page has an image; when it fails, Silo asks the API for the real
  `header_image` — one request, only for those games, and the result is stored.
- The Steam card falls back to the cached file when the network is gone. Its description and metadata
  still require a connection.
- **Settings-pane status messages were never translated.** Wine, GPTK, DXMT, Media Foundation and Backend
  answered in English whenever the message carried a name — "Removed wine cx 26.3.0.", "Installed …" —
  because an interpolated string can't match a fixed catalogue key. Twenty-two now resolve. Four were
  written across two lines and escaped the first pass, which searched for a single spelling.
- Corrected the 0.5.2 notes: the subtitle read "the games Steam doesn't know about", which is the reverse
  of how the game card works — it exists precisely because Steam does know them.

## 0.5.2

### Added
- **A game card for non-Steam games.** Point a manual game at the matching Steam app ID (Settings → Game
  card) and its tile opens a card with hero art, description, developer, genres and release date instead
  of the settings sheet. No Store button — the copy in play wasn't bought there — and the destructive
  action is Remove rather than Uninstall, which is what it actually does. With no association the tile
  behaves exactly as before, and removing one restores that.
- When a manual game has no cover, the association downloads Steam's artwork into `Covers/`, so the tile
  draws without a network. A chosen cover is never replaced, and removing the card keeps it.

### Fixed
- **Status messages carrying a game's name were never translated.** "Launched God of War.", "Added …",
  "Removed …" and twenty-two others interpolate a name, so the runtime string could never match a fixed
  catalogue key — the same defect fixed for error messages earlier. One of them was also split across a
  `+`, which would have put half the sentence in the key.
- Reworded the bottle-switch message: it told you to close the game running in the other bottle, when
  what's usually running there is Steam alone.

## 0.5.1

### Fixed
- **Silo installed one GPTK and ran another.** On a CrossOver-derived runtime the overlay wrote to `lib/`,
  but CrossOver's wine loads D3DMetal from `lib64/apple_gptk` — left untouched, so the runtime kept
  executing the GPTK CrossOver shipped. Measured: GPTK 4.0 beta 2 selected, Tekken 8's HUD reporting
  "Game Porting Toolkit 3.0", `lib/external/D3DMetal` at 7,578,032 bytes against 5,263,744 in
  `lib64/apple_gptk/external`. This is what made the "AMD graphics driver" warning appear, the Metal 3 /
  Metal 4 selector inert, and the GPTK choice in Settings ineffective. The overlay now covers that tree
  too, with its own idempotency check, running before the `lib/` early-return so an already-overlaid
  runtime is repaired instead of skipped.
- **DXMT no longer leaves GPTK's NVIDIA shims resolvable.** `nvapi64`/`nvngx` stay in the runtime tree
  after a GPTK overlay, so under DXMT — which has no D3DMetal behind them — a game could half-bind an
  NVIDIA adapter that isn't there. They're now explicitly disabled for that backend.

### Added
- GPTK's NVIDIA shims are seeded into the game prefix, so they resolve by name on a runtime that doesn't
  ship them (a wine built from source). A no-op on a CrossOver-derived runtime, which carries them already.

The last two are ports of upstream's `aec535a`, itself credited to this fork for the three controls it
re-implements.

### Note
With GPTK 4 genuinely in play, DLSS is unavailable — a GPTK 4 limitation, not a regression here. It had
been working only because GPTK 3 was still the one running. Selecting GPTK 3 restores it.

## 0.5.0

Media Foundation video playback in a second bottle, saves shared between the two, and a setup that tells
the truth about what it did.

### Added
- **Media Foundation support.** Windows' real MF DLLs (user-supplied, from a licensed install) applied to
  a separate `SteamBottleMF` bottle cloned from the Steam one — separate because the configuration that
  fixes Soulcalibur VI stops DMC5 and Mortal Kombat 1 from starting. Per-game toggle, with the Steam
  client switched to match.
- **Shared save folders** between the two bottles: a picker at toggle time, symlinks into the canonical
  bottle, and removal when a folder is unticked. Identical copies are linked silently; divergent ones are
  flagged and never merged.
- **Cover art for non-Steam games**, copied into `Covers/` so an image from an external drive survives
  that drive being unplugged.
- **Metal 3 / Metal 4 selector** for GPTK's D3D12 path (ported from upstream).
- Backend badge on Steam games' tiles, and a direct shortcut to Wine's Game Controllers panel.
- Italian + English localization across the whole UI, error messages included.
- **Import Wine and DXMT from an installed CrossOver**, from the app: offered during onboarding, and
  available afterwards from Settings → Wine and → DXMT (e.g. after a CrossOver update). DXMT is installed
  as a runtime of its own, since the copy inside CrossOver's Wine tree isn't where detection looks.

### Fixed
- **Fullscreen on GPTK.** Steam's Wine virtual desktop was hardcoded to 1440×900, capping every game
  regardless of the resolution it asked for. It's now sized to the screen's native resolution.
- **GPU vendor identity** for DLSS→MetalFX: `nvngx-on-metalfx` renamed to `nvngx`, plus the builtin
  override.
- **`d3dcompiler_47` was never installed** — the extraction command exited 0 without writing a file.
  Replaced with a native CAB reader (ported from upstream).
- **Half-provisioned bottles reported as success.** Failed components are now named; Core Fonts counts as
  satisfied only when all eleven land, not when the second one does.
- **An interrupted `wineboot` looked like a booted prefix**, making every later setup build on a half-
  booted bottle. Recorded only once it completes.
- **A deleted runtime left the readiness gates green**, because the persisted path was never cleared.
- **Crash-leftover extraction directories** were listed and selectable as installed runtimes.
- **Release search didn't paginate**, so a runtime tag would eventually sink under the app's own releases
  and onboarding would report nothing published.
- **A missing `.sha256` sidecar threw away a completed download** on the first transient failure; it now
  gets one retry, while a 404 stays conclusive.
- **Wrong-`.dmg` GPTK imports** were published and reported as successful while `installed()` found
  nothing.
- The default DLL override set is versioned by content, so a change reaches bottles already set up.
- Guided setup adopts an installed runtime instead of downloading a second one.
- "Open Steam" no longer starts a second client when one is already running in the other bottle.
- A manual game on an unplugged drive is hidden rather than offering a Play button that can only fail.
- MSync isolation for non-Steam bottles; external-drive Steam library discovery; `CX_ROOT`,
  `CX_APPLEGPTK_LIBD3DSHARED_PATH` and GStreamer environment for CrossOver-derived runtimes (which
  unblocked Tekken 8 launching at all); two DXMT detection bugs.
- **The app crashed on opening the library on any Mac but the one that built it.** SwiftPM's generated
  `Bundle.module` accessor resolves the resource bundle beside the .app and then at the absolute build
  path of whoever compiled — neither exists in a shipped app, and it traps rather than returning nil. The
  Steam toolbar icon is loaded by path now, and `build-app.sh` also copies SiloKit's resources flat into
  `Contents/Resources` where `Bundle.main` finds them.
- **A crashed bottle stayed "busy" forever.** Liveness was `fileExists` on the wineserver socket, but the
  files in `/tmp` outlive the process — so after a `kill -9`, a crash or an incomplete shutdown every
  launch was silently refused. It's now `fcntl(F_GETLK)` on the server's lock: who holds it, asked without
  taking it.
- **Setup left a Steam client running.** The shutdown terminated only the tracked pid, but the updater
  re-execs a client Silo didn't spawn; two `steam.exe` and a `wineserver` survived a clean onboarding.
- Developer ID signing.

### Changed
- Error types conform to `LocalizedError`, so a first run's failures read as sentences rather than
  `The operation couldn't be completed. (SiloKit.… error 4.)`.
- Steam readiness failsafe tuned to 25 s against a measured cold start.
- `updateRepo` points at this fork; `wineRepo` stays upstream.
