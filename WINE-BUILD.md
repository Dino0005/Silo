# Wine sourcing strategy

## Decision (2026-06-26)

Silo's game Wine is the **CrossOver-based Wine, built from open source in our own CI and hosted on
our own GitHub Releases** — not a third-party prebuilt that can go stale.

### Why CrossOver-based (not upstream Wine, not built-from-scratch-and-optimized)
- Apple's **D3DMetal** (the DX11/12→Metal layer we extract from the GPTK `.dmg`) is built and
  validated against **CrossOver-patched Wine's ABI**. Pairing it with plain upstream Wine is weaker.
- CrossOver's Wine carries years of game/CEF patches and `msync` that upstream lacks. Re-implementing
  these ourselves would be slower and unmaintainable. On macOS, performance comes from the
  translation layers (D3DMetal / DXMT / DXVK→MoltenVK) and the x86 translator (Rosetta / rosettax87),
  **not** from our Wine compile.
- CrossOver's Wine is **LGPL open source** (CodeWeavers publishes the sources). Apple's
  `apple/apple/game-porting-toolkit` Homebrew formula compiles exactly this base. So we can build the
  same thing ourselves.

### Why self-hosted (vs. Gcenx / Sikarugir prebuilts)
Those projects are just "someone compiled CrossOver's source for you" — convenient, but a third-party
dependency that can lag or disappear (Gcenx's GPTK repo is stale; Kegworks became Sikarugir). Building
it in our own CI removes that dependency and lets us control the cadence.

## How the build runs — two equivalent options
The app doesn't care whether the Wine asset was built in CI or on your Mac; it only downloads the
`wine.tar.xz` attached to a `wine-*` **Release**. Pick whichever is easier:

- **Local (easiest for the first working build):** `Scripts/build-wine.sh <crossover_version> [tag]`
  builds on your Mac and prints the `gh release create …` command to upload the asset. You can
  iterate deps/flags interactively instead of the slow push→CI→logs loop.
- **CI (reproducible / hands-off later):** `.github/workflows/build-wine.yml` (workflow_dispatch).

**Never commit the binary into git.** A ~250 MB blob bloats history and GitHub rejects files >100 MB.
It belongs as a **Release asset** (`gh release`), which is exactly where `Silo.wineRepo` looks.

## Pipeline
Same recipe in both places — `Scripts/build-wine.sh` (local) and `.github/workflows/build-wine.yml` (CI,
manual `workflow_dispatch`: CrossOver version + release tag + `draft`, default **on** for manual runs):

1. **Source:** CrossOver's FOSS tarball (`media.codeweavers.com/pub/crossover/source/crossover-sources-<ver>.tar.gz`).
2. **Our patches:** every `Scripts/patches/*.patch`, required to apply (today: `0002-cfgmgr32-deviceinstance-
   notification` — Steam games like TEKKEN 8 / SoulCalibur VI crashed on every exit).
3. **GStreamer = CrossOver's own:** `Scripts/build-gst-libav.sh` builds GStreamer 1.24.4 + glib 2.78 from the
   same tarball with CrossOver's 17 plugins **plus libav + matroska** (FFmpeg 6.1, LGPL, decoders only — VC-1/WMV/
   WMA, e.g. Devil May Cry 5's movies). Wine is configured against that prefix (it must be: winegstreamer built
   against a newer glib needs symbols 2.78 lacks).
4. **Shipped libraries from source:** `Scripts/build-deps.sh` builds gmp, nettle, gnutls, freetype and (via
   `Scripts/build-moltenvk.sh`, xcodebuild) MoltenVK for x86_64 — the versions in the tarball and the same
   dependency shape as CrossOver's own lib64 (gnutls → only libgmp; freetype → only the system's libbz2). nettle and
   freetype come from their official releases at the tarball's versions (its copies lack their generated build
   files), sha256-pinned in `versions.env`.
5. **Pinned PE compiler:** `Scripts/pin-mingw-w64.sh` provides the exact Homebrew mingw-w64 revision
   (`versions.env`: `MINGW_W64_BOTTLE` 14.0.0_1, its arm64 bottle digest, the homebrew-core formula commit,
   `MINGW_GCC_VERSION` = GCC 16.1.0 — the compiler the tested runtime was built with), installed from a local tap
   and checked by version and a probe compile. llvm-mingw was tried and broke Steam's sign-in.
6. **Configure + make:** x86_64 under Rosetta (CrossOver is Intel code), `--enable-archs=i386,x86_64`.
7. **Self-contained, CrossOver's layout:** `Scripts/bundle_wine_dylibs.py` puts every third-party dylib in
   `lib64/` with `@rpath` names and the GStreamer stack in `lib64/gstreamer-1.0` — no Homebrew path left, no
   `DYLD_*` needed (with `SILO_DEPS_PREFIX` a Homebrew library anywhere in the closure fails the build). Then `wine.tar.xz` + `.sha256`, published as a `wine-cx-*` Release (a draft when asked).

- The app's Wine tab / onboarding pulls Wine from `Silo.wineRepo` (`SILO_GITHUB_REPO`); `RuntimeManager`
  downloads + extracts the tarball and finds `bin/wine64`.
- **GPTK / D3DMetal is NEVER built or bundled here** — it's Apple-licensed; the user imports it from their own
  GPTK `.dmg` via `GPTKImporter`. Silo overlays it into the runtime and sets `CX_APPLEGPTK_LIBD3DSHARED_PATH` to
  the overlaid `libd3dshared.dylib` (it arms a CrossOver hack in ntdll; without it D3D12 games crash).
- **Not in the FOSS source, so never in this runtime:** CrossOver's proprietary `cxcompatdb.so` (its compat DB)
  — only the hook that would load it is in the tarball.

## Keeping Wine current with CrossOver (automatic)
`.github/workflows/wine-autoupdate.yml` runs weekly (and on demand). It reads the latest CrossOver
version from the Homebrew `crossover` cask API (`formulae.brew.sh/api/cask/crossover.json` — the same
number CrossOver publishes its source tarball under), checks the source tarball exists, and if we
haven't already published a `wine-cx-<version>` release, it calls `build-wine.yml` to build + publish
it. So new CrossOver releases get picked up with no manual work.

**App side:** the Wine tab lists the latest `wine-cx-*` releases from `Silo.wineRepo`; a newly
published build shows up there with an Install button (already-installed versions show "Installed"),
so users can update on their own schedule.

### Why the Homebrew cask is the version pointer (not a GitHub repo)
- CodeWeavers has **no public GitHub source repo** (`CodeWeavers/wine` → 404). The authoritative
  source is `media.codeweavers.com`, which has **no browseable index** (HTTP 403).
- The only GitHub mirror, `PhoenicisOrg/winecx`, is a **community mirror that lags** (it was at
  `winecx-25.1.0` while CrossOver was already `26.2.0`) — using it as the source of truth would keep
  us a version behind.
- So we use the Homebrew `crossover` cask only as a **fresh, machine-readable version pointer** (it's
  autobumped to the real CrossOver version); the source we actually build is still CodeWeavers' own
  tarball, verified to exist before building. The cask is the oracle, not the source.

## Status / caveats
- **Local build validated in game (2026-09-29, runtime `wine-cx-26.3.0-gcc16`):** Steam sign-in, Devil May Cry
  5 (VC-1 movies), TEKKEN 8 and SoulCalibur VI start and exit cleanly. **Re-validated with the no-Homebrew recipe
  (2026-09-30, `wine-cx-26.3.0-nobrew`):** Steam sign-in, DMC5 (story video), TEKKEN 8, Spider-Man.
- **CI not yet run with this recipe** — the first run should be a draft. The pinned-compiler step's
  fetch-and-install branch (a runner without that mingw-w64 revision) is untested.
- **No x86_64 Homebrew any more** (its installer refuses Intel installs on current macOS — the first CI run failed
  on it). Host tools (bison, cmake, pkgconf; `Scripts/host-tools.sh`) and mingw-w64 come from the native arm64
  Homebrew; everything x86_64 that ships is built from source. Needs full Xcode (MoltenVK, like DXMT).
- Games that need Windows' own Media Foundation (Wine's MF topology loader is a stub) still need the MF
  bottle — GStreamer additions can't replace it.

## Steam client
Silo runs the Windows Steam client co-resident in the shared bottle on the same runtime. Its CEF UI is kept
painting by the steamwebhelper wrapper shipped in the runtime (`share/silo/steamwebhelper-wrapper.exe`: forces
`--in-process-gpu` + software GL); Silo moves the real helper aside as `steamwebhelper_orig.exe`.
