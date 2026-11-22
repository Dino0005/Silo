# Spider-Man 2 fix carrier (`amd_ags_x64.dll`)

Silo's own `amd_ags_x64.dll` for Marvel's Spider-Man 2, carrying **macprotips' SpiderMan2Fix**
([github.com/macprotips/SpiderMan2Fix](https://github.com/macprotips/SpiderMan2Fix), Unlicense / public domain).
On M1–M4 Macs D3DMetal reads and writes typed buffer views only up to element 2^28; the game's 2 GB character mesh
pool goes past it, hence the T-pose, the missing heads and the broken symbiote. The fix creates those views raw and
swaps the four shaders that use them for raw-access copies.

| File | Whose |
| --- | --- |
| `carrier.c`, `carrier.def` | Silo's: the AGS carrier (all 36 exports forwarded to `amd_ags_x64_real.dll`), the `d3d12.dll` load notification that points `D3D12CreateDevice`'s export at it, vtable hooks, the fog barrier |
| `sm2fix_core.c`, `sm2fix_core.h` | macprotips', unchanged (shader hash, pipeline-stream parsing) |
| `../../Sources/CShaderFix` | macprotips', unchanged (the shader rewrite Silo runs on the user's Mac) |

The device hooks in `carrier.c` (raw views, shader swap, the build/ini checks) are macprotips' `fix.c` as it is.
The fog barrier follows vkd3d-proton's workaround for `Spider-Man2.exe` (shader `324071d329f05ccc`,
`vkd3d_proton_app_workarounds.json`). Nothing comes from MacGameFix (GPL-3), which carries the same fix differently.

**How Silo uses it:** `SpiderMan2Fix.sync`, before every launch of the game (`LaunchOrchestrator.launchInBottle`),
with `EnvFlags.spiderMan2Fix` on (the default) and GPTK: the shaders are rebuilt from the user's own
`Spider-Man2.exe` with Microsoft's DXC (`DXCTools`, release `dxc-<commit>` built by `build-dxc.yml`), the game's
DLL becomes `amd_ags_x64_real.dll`, this file takes its place, and `silo-sm2-fix.ini` names the game build. Off, or
under DXMT, the folder goes back as shipped. The carrier logs to `silo-sm2-fix.log` beside itself.

**Build:** `Scripts/build-sm2-fix.sh` → the committed resource `Sources/SiloKit/Resources/silo-sm2-fix-amd_ags_x64.dll`
(llvm-mingw, like the depth-fix proxy). Re-run it after changing the sources and commit the result.

**Verified on device 2026-11-22** (M3 Pro, GPTK, Metal 3, game build `6a79a155-0d069000`): characters animate,
heads back; log: 1 wide SRV + 1 wide UAV made raw, 4 shaders replaced, ~10 900 fog barriers in one session.
