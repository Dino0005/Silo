# Changelog

This fork's history. It starts at 0.5.0, the first release built on top of
[mikaelhug/Silo](https://github.com/mikaelhug/Silo); anything earlier belongs to upstream.

Upstream commits are integrated selectively — each one judged on its own, several deliberately left out
(DXVK is irrelevant to a library with no DirectX 9 titles). Where a port diverges from upstream's version,
the commit message says why.

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
