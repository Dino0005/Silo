#!/usr/bin/env bash
# Build CrossOver's Wine from FOSS source LOCALLY, then upload it as a GitHub Release asset.
# (Same recipe as .github/workflows/build-wine.yml — use whichever is easier.)
#
# The result is a ~250 MB wine.tar.xz. Do NOT commit it into git — attach it to a Release with the
# `gh release` command printed at the end. The app downloads it from Silo.wineRepo's Releases.
#
# We build Wine ONLY. GPTK/D3DMetal is Apple-licensed and is imported in-app from the user's .dmg.
#
# Usage: Scripts/build-wine.sh [crossover_version] [release_tag]
#   e.g. Scripts/build-wine.sh 26.2.0 wine-cx-26.2.0
#   With no version, defaults to CROSSOVER_VERSION from versions.env (the single source of truth).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
set -a; . "$ROOT/versions.env"; set +a
VER="${1:-$CROSSOVER_VERSION}"
TAG="${2:-wine-cx-$VER}"
WORK="$ROOT/.wine-build"
ARCH="arch -x86_64"   # CrossOver is x86_64; runs on Apple Silicon via Rosetta
BREW=/usr/local/bin/brew

echo "==> Rosetta + x86_64 Homebrew dependencies"
"$ROOT/Scripts/bootstrap-x86-brew.sh" bison mingw-w64 freetype gnutls gstreamer sdl2 molten-vk cmake

echo "==> Fetch CrossOver source $VER"
mkdir -p "$WORK" && cd "$WORK"
curl -fL "https://media.codeweavers.com/pub/crossover/source/crossover-sources-${VER}.tar.gz" -o sources.tar.gz
rm -rf src && mkdir src && tar -xzf sources.tar.gz -C src
WINE_SRC="$(find src -maxdepth 3 -type d -name wine | head -1)"
[ -n "$WINE_SRC" ] || { echo "ERROR: wine source dir not found in tarball"; exit 1; }

echo "==> Configure + build (x86_64, wow64) — this takes ~30–60 min"
export PATH="$($ARCH "$BREW" --prefix bison)/bin:$PATH"
# The x86_64 Homebrew prefix (normally /usr/local on Apple Silicon under Rosetta). macOS's linker, unlike
# Linux's, does NOT search /usr/local/lib by default, so configure's AC_CHECK_LIB(gnutls, ...) / dbus /
# similar link-time checks silently report "not found" without an explicit -L — even though pkg-config
# and the plain header check (which DOES pick up /usr/local/include via the toolchain's default search
# path) succeed. Computing these here — instead of relying on a caller's shell-exported LDFLAGS, which
# does not reliably survive the arch -x86_64 + env nesting below — makes the build reproducible regardless
# of the invoking shell's environment.
BREW_PREFIX="$($ARCH "$BREW" --prefix)"
export PKG_CONFIG_PATH="$BREW_PREFIX/lib/pkgconfig:$BREW_PREFIX/share/pkgconfig:$($ARCH "$BREW" --prefix gnutls)/lib/pkgconfig"
export LDFLAGS="-L$BREW_PREFIX/lib"
export CPPFLAGS="-I$BREW_PREFIX/include"
# CRITICAL: `arch -x86_64` only picks which slice of the (universal) clang/gcc DRIVER BINARY runs under
# Rosetta — it does NOT tell clang which architecture to GENERATE CODE FOR. Without an explicit `-arch
# x86_64`, clang defaults to the host's native arch (arm64 on Apple Silicon), so configure's link checks
# (e.g. AC_CHECK_LIB against gnutls) produce an arm64 conftest that can't link against the x86_64-only
# Homebrew libraries under /usr/local — "ld: ... found architecture 'x86_64', required architecture
# 'arm64'". Matches .github/workflows/build-wine.yml, which already sets this for CI.
export CC="clang -arch x86_64"
export CXX="clang++ -arch x86_64"
rm -rf build install && mkdir build install && cd build
# -fvisibility=default: build Wine with all symbols visible so winemac.drv ('macdrv') exposes its
# Metal/window-surface helpers via dlsym — this is what lets **GPTK/D3DMetal GAMES** present correctly
# (without it the macOS surface path is broken for layered windows and D3D→Metal output is black). NOTE:
# this is NOT what fixes the Steam *client* CEF UI — that black window is fixed at RUNTIME by forcing CEF
# onto its SwiftShader software-GL renderer (STEAM_CEF_COMMAND_LINE + the --in-process-gpu wrapper, see
# SteamBottle.steamEnvironment), not by Metal presentation. Set on BOTH CFLAGS (Wine's Unix-side .so
# thunks, incl. winemac.so) AND CROSSCFLAGS (the PE-side built-in DLLs). -O2 keeps the optimization an
# explicit *FLAGS would otherwise drop. gnutls = Wine's schannel TLS (Steam's networking needs it).
# --without-sdl: build winebus WITHOUT the SDL game-controller backend. On macOS that backend `dlopen`s
# libSDL2, whose initializer pops an NSAlert off the main thread → the whole Wine process aborts the moment
# winebus loads (before Steam draws). Costs in-Wine controller support; gains a Wine that actually launches.
$ARCH env CFLAGS="-fvisibility=default -O2" CROSSCFLAGS="-fvisibility=default -O2" \
  PKG_CONFIG_PATH="$PKG_CONFIG_PATH" LDFLAGS="$LDFLAGS" CPPFLAGS="$CPPFLAGS" \
  "$WORK/$WINE_SRC/configure" --prefix="$WORK/install" \
  --enable-archs=i386,x86_64 --disable-tests --without-x \
  --with-freetype --with-gstreamer --with-gnutls --without-sdl
$ARCH make -j"$(sysctl -n hw.ncpu)"
$ARCH make install

echo "==> Build the steamwebhelper wrapper (forces CEF --in-process-gpu + software GL so Steam's UI paints)"
mkdir -p "$WORK/install/share/silo"
WRAPPER="$WORK/install/share/silo/steamwebhelper-wrapper.exe"
"$($ARCH "$BREW" --prefix mingw-w64)/bin/x86_64-w64-mingw32-gcc" -O2 -municode -mwindows \
  -o "$WRAPPER" "$ROOT/Scripts/steamwebhelper-wrapper.c"
# The wrapper is load-bearing — fail the build if its CEF flags are wrong (shared check, also run in CI).
python3 "$ROOT/Scripts/check-webhelper-wrapper.py" "$WRAPPER"

echo "==> Bundle dependency dylibs (self-contained runtime)"
"$ROOT/Scripts/bundle-wine-dylibs.sh" "$WORK/install"

# Sign every Mach-O in the tree (wine64, wineserver, winemac.so, and all other PE/Unix-side .so's
# `make install` produced) with the SAME identity used for the bundled dylibs and the app itself.
# Without this, only the copied third-party dylibs would carry a real Developer ID and the actual
# Wine binaries would ship completely unsigned — inconsistent, and still effectively "ad-hoc" in
# practice. Uses SILO_SIGN_IDENTITY if set (see Scripts/sign.sh); falls back to ad-hoc ("-"),
# matching upstream, when it isn't.
WINE_IDENTITY="${SILO_SIGN_IDENTITY:--}"
echo "==> Signing Wine tree with identity: $WINE_IDENTITY"
# -exec ... \; (not `find | xargs`): xargs on macOS (BSD) can fail outright with "command line cannot
# be assembled, too long" when the calling shell's environment is already large (as it is here, with
# PKG_CONFIG_PATH/LDFLAGS/CPPFLAGS exported above) — even with -I{} substituting one file per invocation,
# BSD xargs still needs headroom to construct that one invocation and can come up short. -exec spawns one
# process per file directly from find, with no command-line assembly step, so it can't hit that limit.
find "$WORK/install" -type f \( -perm -u+x -o -name '*.so' -o -name '*.dylib' \) \
  -exec sh -c 'file "$1" | grep -q "Mach-O" && codesign --force --sign "$2" "$1" 2>/dev/null' _ {} "$WINE_IDENTITY" \;

echo "==> Package"
mkdir -p "$ROOT/dist"
# New WoW64 builds install a unified `wine`; add a wine64 alias for consumers expecting it.
if [ -e "$WORK/install/bin/wine" ] && [ ! -e "$WORK/install/bin/wine64" ]; then
  ( cd "$WORK/install/bin" && ln -s wine wine64 )
fi
( cd "$WORK/install" && tar -cJf "$ROOT/dist/wine.tar.xz" . )
( cd "$ROOT/dist" && shasum -a 256 wine.tar.xz > wine.tar.xz.sha256 )   # app verifies this before extracting
echo "Built: $ROOT/dist/wine.tar.xz (+ .sha256)"
echo
echo "Publish BOTH as Release assets (NOT committed to git):"
echo "  gh release create $TAG \"$ROOT/dist/wine.tar.xz\" \"$ROOT/dist/wine.tar.xz.sha256\" -t \"$TAG\" -n \"CrossOver Wine $VER (FOSS source build)\""
echo "or if the release already exists:"
echo "  gh release upload $TAG \"$ROOT/dist/wine.tar.xz\" \"$ROOT/dist/wine.tar.xz.sha256\""
