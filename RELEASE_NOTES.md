# Silo 0.5.0

Games launched through GPTK now actually fill the screen — fixed at the root cause instead of papered over per title.

## Highlights
- **Fullscreen fix for GPTK games.** Every Steam game shares the Steam client's own Wine virtual desktop, which was hardcoded to 1440×900 — so no game could ever exceed that size, no matter what resolution it asked for (confirmed on Tekken 8, DMC5, and Soulcalibur VI). Steam's desktop is now sized to the real screen's native resolution instead, picked up automatically each time Steam launches.
- **Italian + English localization**, 175 keys across the UI.
- **GPU vendor fix**: the AMD→NVIDIA rename (`nvngx-on-metalfx` → `nvngx` + builtin override) that unblocks DLSS→MetalFX translation in GPTK titles.
- **MSync fix** for isolated (non-Steam) bottles.
- Fixes to `build-wine.sh` (gnutls/arch/xargs), external-drive library discovery, `CX_ROOT` for the CrossOver runtime, `CX_APPLEGPTK_LIBD3DSHARED_PATH` + GStreamer (unblocked Tekken 8 launching at all), and two DXMT bugs (a false-positive detection, and a wrong standard path).
- Developer ID signing.

---

Silo downloads its own Wine (built from CrossOver's FOSS source in CI) and imports Apple's GPTK from your `.dmg`. Runs on macOS 15+ on Apple Silicon. Gatekeeper: the build is ad-hoc signed, so right-click → **Open** on first launch (or `xattr -dr com.apple.quarantine Silo.app`).
