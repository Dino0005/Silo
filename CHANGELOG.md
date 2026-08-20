# Changelog

This fork's history. It starts at 0.5.0, the first release built on top of
[mikaelhug/Silo](https://github.com/mikaelhug/Silo); anything earlier belongs to upstream.

Upstream commits are integrated selectively — each one judged on its own, several deliberately left out
(DXVK is irrelevant to a library with no DirectX 9 titles). Where a port diverges from upstream's version,
the commit message says why.

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
