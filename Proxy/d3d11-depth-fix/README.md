# d3d11 depth-fix proxy ("Correzione profondità")

Silo's own `d3d11.dll`, placed in front of D3DMetal's `d3d11`. It changes one thing: a depth-stencil state
with `DepthFunc = EQUAL` and depth writes off is created as `GREATER_EQUAL`. Some reverse-Z games (God of War
2018) draw the G-buffer with an EQUAL test against the depth prepass; on Metal a few pixels round differently
between the two passes and fail it — white specks. Everything else is passed through.

**How Silo uses it** (per game, `EnvFlags.depthFix`, the "Depth fix" toggle in the game's settings):
- `GraphicsLinker.overlayGPTK` keeps `d3dm_d3d11.dll` — a copy of D3DMetal's `d3d11.dll` — beside it in the
  runtime (`syncDepthFixRealModule`), refreshed on every overlay, so a GPTK update never leaves it stale. The
  proxy can't load a second module named `d3d11.dll` (Wine returns the loaded one by base name).
- Before every launch `syncDepthFixProxy` puts this file in the bottle's `system32\d3d11.dll` for a GPTK
  launch with the option on, and takes it back out otherwise (Wine's placeholder, or a foreign native file it
  had moved aside). Other games in the same bottle keep `d3d11=b` and load the builtin — measured.
- `LaunchOrchestrator.makePlan` adds `d3d11=n,b` after the backend's overrides and sets `SILO_REAL_D3D11` to
  the copy's `Z:` path (a bottle not booted by that runtime has no placeholder for the name → load by name
  fails with 126). Under DXMT the same toggle sets DXMT's own `d3d11.depthEqualAsGreaterEqual` (patch 0003).

Environment the proxy reads: `SILO_REAL_D3D11`, `SILO_DEPTH_EQUAL_FIX=0` (disable, for A/B),
`SILO_DEPTH_FIX_LOG=<DOS path>` (log file; off when unset).

**Build:** `Scripts/build-depth-proxy.sh` → the committed resource `Sources/SiloKit/Resources/silo-depth-fix-d3d11.dll`
(a Windows PE needs llvm-mingw, which the SwiftPM build doesn't have — same scheme as the committed app icon).
Re-run it after changing `proxy.c` and commit the result.

**Verified on device 2026-10-12** (hand setup: proxy next to the exe, copy in the runtime): God of War on GPTK,
correct lighting, no specks, FSR Quality and DLSS Quality; 88 `EQUAL / write 0 / stencil 1` states swapped.
The `system32` placement and `d3d11=b` co-residency were measured 2026-10-13 with a test program.

Our own code, loading the user's own D3DMetal at run time — not an Apple or CodeWeavers binary.
