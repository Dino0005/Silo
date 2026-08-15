# Silo 0.5.0

Media Foundation video playback in a second bottle, saves shared between the two, and a setup that
tells the truth about what it did.

## Highlights

- **Media Foundation.** Some games' in-engine videos stay black because Wine's Media Foundation can't
  decode them. Silo can now use Windows' real DLLs — you supply them from a licensed Windows install —
  and applies them to a **separate `SteamBottleMF` bottle**, cloned from the Steam one. It has to be a
  separate bottle: the configuration that fixes Soulcalibur VI stops Devil May Cry 5 and Mortal Kombat 1
  from starting at all. A per-game toggle picks which bottle a game runs in, and Silo switches the Steam
  client to match.
- **Shared saves across the two bottles.** The MF bottle is a clone, so the same game would keep two
  separate save sets. Turning the toggle on offers the game's save folders, and the chosen ones are
  symlinked to the normal bottle's copy. Identical copies (a freshly cloned bottle) are linked silently;
  genuinely divergent ones are flagged and never merged or deleted behind your back.
- **The MF bottle knows which Wine built it.** Its recipe writes into the prefix, and a Wine change
  regenerates the prefix's fakedlls over the top — the bottle then still looks installed while the videos
  come up black again. Silo now notices and offers to rebuild instead of leaving you to find out from a
  game.
- **Cover art for non-Steam games.** Pick an image in a manual game's settings; it's copied into Silo, so
  a cover taken off an external drive keeps working once that drive is unplugged.
- **Wine and DXMT can be imported from an installed CrossOver, from inside the app.** No terminal, no
  cloning the repo for a shell script. CrossOver's Wine is the better one to have here: it carries
  GStreamer with its plugin tree, which the built Wine can't, and the `apple_gptk` tree Silo wires up. The
  copy is self-contained — CrossOver can be uninstalled afterwards.
- **Fullscreen fix for GPTK games.** Every Steam game shares the Steam client's own Wine virtual desktop,
  which was hardcoded to 1440×900 — so no game could exceed that size whatever resolution it asked for
  (confirmed on Tekken 8, DMC5, and Soulcalibur VI). Steam's desktop is now sized to the real screen's
  native resolution, picked up each time Steam launches.
- **Italian + English localization**, 250+ keys across the UI, including every error message.
- **GPU vendor fix**: the AMD→NVIDIA rename (`nvngx-on-metalfx` → `nvngx` + builtin override) that
  unblocks DLSS→MetalFX translation in GPTK titles.
- **Metal 3 / Metal 4 selector** for GPTK's DirectX 12 path, per game.

## Setup and reliability

- Errors from a first run read as sentences instead of `The operation couldn't be completed.
  (SiloKit.RuntimeManager.RuntimeError error 4.)` — a rate-limited GitHub, a missing checksum, a full
  disk and a wrong `.dmg` each say what happened, in your language.
- Setup no longer reports plain success over a half-provisioned bottle: components that didn't install
  are named. Core Fonts is satisfied only when all eleven actually landed, not when the second one did.
- An interrupted `wineboot` is retried instead of being mistaken for a booted prefix, and the default
  DLL override set is versioned by its content so a later change reaches bottles that already exist.
- A runtime deleted outside Silo no longer leaves the readiness gates green, and a crash-leftover
  extraction directory is no longer offered as an installed runtime.
- Guided setup adopts a runtime that's already in `Runtimes/` instead of downloading a second one.
- The release search pages, so a runtime tag can't sink out of sight under the app's own releases.
- A manual game whose executable is unreachable (external drive unplugged) is hidden, like the Steam
  games on that same drive, and comes back when the drive does.
- `d3dcompiler_47` is finally installed for real — the old command exited 0 without writing anything.
- **The library no longer closes the app on launch.** SwiftPM's generated `Bundle.module` looks beside the
  .app and then in the build directory of whoever compiled it, and traps when neither exists — which is
  every machine but the one that built the app. The Steam toolbar icon is now loaded by path instead.
- A bottle counts as busy only while a `wineserver` actually holds its lock. The files it leaves in `/tmp`
  outlive the process, so after a crash or a force-quit every launch was refused with no explanation until
  those files were deleted by hand.
- Setup no longer leaves a Steam client running when it finishes: the updater re-execs a client Silo never
  spawned, and that one survived the shutdown.

---

Silo downloads its own Wine (built from CrossOver's FOSS source in CI) and imports Apple's GPTK from your
`.dmg`. Runs on macOS 15+ on Apple Silicon. Gatekeeper: the build is ad-hoc signed, so right-click →
**Open** on first launch (or `xattr -dr com.apple.quarantine Silo.app`).
