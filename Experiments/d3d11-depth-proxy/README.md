# d3d11 depth proxy (experiment, God of War on GPTK)

Our own `d3d11.dll` placed in front of D3DMetal's `d3d11` (loaded as `d3dm_d3d11.dll`). It changes one thing:
a depth-stencil state with `DepthFunc = EQUAL` and depth writes off is created as `GREATER_EQUAL` (God of War
is reverse-Z; its G-buffer pass tests EQUAL against the prepass depth, and on Metal some pixels miss → white
specks). Everything else is passed through. `SILO_DEPTH_EQUAL_FIX=0` turns the change off.

**Verified on device 2026-10-12** (user): GoW on GPTK through Silo — correct lighting, no specks, FSR Quality
and DLSS Quality. The log showed 88 `EQUAL / write 0 / stencil 1` states swapped. This source is exactly the
build that was tested (it still logs every `CreateDepthStencilState` to `Z:\tmp\silo-proxy.log`).

Build (llvm-mingw, the toolchain `Scripts/build-dxmt.sh` downloads):

    x86_64-w64-mingw32-gcc -O2 -shared -o d3d11.dll proxy.c proxy.def -ldxguid

Manual setup used for the test (not wired into Silo):
- `cp <runtime>/lib/wine/x86_64-windows/d3d11.dll <same dir>/d3dm_d3d11.dll` — must be redone whenever GPTK
  is re-imported/updated, or the copy goes stale against D3DMetal's unix side;
- `d3d11.dll` (this proxy) next to the game's exe;
- the game's `envFlags.extra` in `config.json`: `WINEDLLOVERRIDES = d3d11=n,b` and
  `SILO_REAL_D3D11 = Z:\…\lib\wine\x86_64-windows\d3dm_d3d11.dll` (full path: a prefix that was not booted by
  that runtime has no `system32` placeholder for the renamed module, so `LoadLibrary` by name fails with 126).

Not a CodeWeavers or Apple binary: our own code, loading the user's own D3DMetal at run time.
