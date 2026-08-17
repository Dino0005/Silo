# Silo 0.5.1

The GPTK you pick is now the GPTK that runs.

## The fix that matters

On a CrossOver-derived runtime, Silo overlaid the chosen GPTK into `lib/` — but CrossOver's wine loads
D3DMetal from its own `lib64/apple_gptk` tree, which was left untouched. So the app installed one GPTK and
executed another: Tekken 8's performance HUD reported **Game Porting Toolkit 3.0** with GPTK 4.0 beta 2
selected in Settings, and it was telling the truth.

That one mismatch was behind a lot:

- the **"AMD graphics driver" warning** some games show at startup — the NVIDIA/MetalFX bridge in play
  belonged to the older build;
- the **Metal 3 / Metal 4 selector** doing nothing (`D3DM_MTL4` is a GPTK 4 option);
- **picking a GPTK in Settings** having no real effect.

The overlay now writes to that tree as well, with the same module handling as `lib/` — the
`nvngx-on-metalfx` → `nvngx` activation, the recreated relative `.so` symlinks, the witness copied last.
It has its own idempotency check and runs before the `lib/` early-return, so a runtime that was already
overlaid gets repaired rather than skipped. A runtime with no `lib64/apple_gptk` — one built by
`build-wine.sh` — is unaffected.

**Consequence worth knowing:** with GPTK 4 genuinely running, DLSS is unavailable (a GPTK 4 limitation
others have reported too). It was never gone before — GPTK 3 was quietly still running. Choosing GPTK 3 in
Settings brings DLSS back, on both Tekken 8 and God of War. The choice is now a real one.

## Also in this release

- **DXMT disables GPTK's NVIDIA shims.** The GPTK overlay leaves `nvapi64`/`nvngx` in the runtime tree, so
  under DXMT they still resolved as builtin even though DXMT has no D3DMetal behind them — a game could
  half-bind an NVIDIA adapter that isn't there. Same family as the DXMT/D3D12 mismatch behind Fatal Fury's
  misaligned display.
- **GPTK's NVIDIA shims are seeded into the game prefix.** `wineboot` only creates a `system32` stub for
  names wine already knows, and bottles are booted against the base runtime — so on a runtime that doesn't
  ship them, neither name resolves and the `=b` override has nothing to bind. Insurance for a runtime that
  isn't CrossOver-derived.

Both ported from upstream's `aec535a`, a commit that in turn credits this fork for the three controls it
re-implements.

---

Silo downloads its own Wine (built from CrossOver's FOSS source in CI) and imports Apple's GPTK from your
`.dmg`. Runs on macOS 15+ on Apple Silicon. Gatekeeper: the build is ad-hoc signed, so right-click →
**Open** on first launch (or `xattr -dr com.apple.quarantine` on the app).
