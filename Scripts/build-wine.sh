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
#   e.g. Scripts/build-wine.sh 26.3.0 wine-cx-26.3.0
#   With no version, defaults to CROSSOVER_VERSION from versions.env (the single source of truth).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
set -a; . "$ROOT/versions.env"; set +a
VER="${1:-$CROSSOVER_VERSION}"
TAG="${2:-wine-cx-$VER}"
WORK="$ROOT/.wine-build"
ARCH="arch -x86_64"   # CrossOver is x86_64; runs on Apple Silicon via Rosetta
SDK="$(xcrun --show-sdk-path)"

echo "==> Host tools (native Homebrew: bison, cmake, pkgconf) + Rosetta"
# No x86_64 Homebrew anywhere (its installer refuses Intel now — the CI failed on it, 2026-09-29): the tools
# only run here, and every x86_64 library the runtime ships is built from source below — freetype, gnutls,
# MoltenVK (build-deps.sh), GStreamer (build-gst-libav.sh), SDL (pinned, here). The PE cross compiler is one
# pinned mingw-w64 bottle (pin-mingw-w64.sh).
export PATH="$("$ROOT/Scripts/host-tools.sh" | tail -1):$PATH"
PKGCONF="$(command -v pkgconf)"

echo "==> Fetch CrossOver source $VER"
mkdir -p "$WORK" && cd "$WORK"
curl -fL "https://media.codeweavers.com/pub/crossover/source/crossover-sources-${VER}.tar.gz" -o sources.tar.gz
rm -rf src && mkdir src && tar -xzf sources.tar.gz -C src
WINE_SRC="$(find src -maxdepth 3 -type d -name wine | head -1)"
[ -n "$WINE_SRC" ] || { echo "ERROR: wine source dir not found in tarball"; exit 1; }

# Silo's own patches on top of the CrossOver FOSS source (constraint #8 still holds: this IS that
# source, plus changes we keep in-tree and reviewable — nothing from a CrossOver *product*). Each
# one carries its rationale in its own header. Applied in filename order and REQUIRED to apply:
# a silently-skipped patch would ship a runtime that looks patched but isn't.
for p in "$ROOT"/Scripts/patches/*.patch; do
  [ -e "$p" ] || break
  echo "==> Apply $(basename "$p")"
  ( cd "$WINE_SRC" && patch -p1 --forward < "$p" ) \
    || { echo "ERROR: $(basename "$p") did not apply to CrossOver source $VER — rebase it"; exit 1; }
done

echo "==> Build CrossOver's GStreamer $(sed -n "s/^ *version *: *'\([0-9.]*\)'.*/\1/p" "$WORK/src/sources/gstreamer/meson.build" | head -1) from this source (+ libav + matroska)"
# winegstreamer must compile against the SAME GStreamer/glib it will run on — CrossOver's (1.24.4 / 2.78,
# from this very tarball). Built against Homebrew's newer glib it imports g_once_init_enter_pointer, which
# 2.78 doesn't have (measured). build-gst-libav.sh builds that stack into .wine-build/gst/prefix (the
# headers/pkg-config Wine's configure uses below) and packages it, relocated, for the bundler.
"$ROOT/Scripts/build-gst-libav.sh"
GST_PREFIX="$WORK/gst/prefix"
GST_STACK="$(ls -d "$ROOT"/dist/gstreamer-*/lib64 | sort -V | tail -1)"

echo "==> Build the shipped libraries from source (Scripts/build-deps.sh: gmp, nettle, gnutls, freetype, MoltenVK)"
# The same versions and dependency shape as CrossOver's own lib64 (measured). Wine's configure finds them
# through DEPS_PREFIX below; the bundler ships them from there.
"$ROOT/Scripts/build-deps.sh"
DEPS_PREFIX="$WORK/deps/prefix"

echo "==> Pinned PE cross toolchain (Scripts/pin-mingw-w64.sh)"
MINGW="$("$ROOT/Scripts/pin-mingw-w64.sh" "$WORK/toolchains" | tail -1)"
# configure takes the compiler from x86_64_CC / i386_CC below, but winegcc LINKS through the target-named driver
# it finds on PATH (i686-w64-mingw32-gcc) — measured: without this it picked the system-wide Homebrew one. So put
# ONLY the pinned toolchain's *-w64-mingw32-* tools first on PATH.
MINGW_SHIM="$WORK/toolchains/mingw-shim"
rm -rf "$MINGW_SHIM" && mkdir -p "$MINGW_SHIM"
ln -s "$MINGW"/bin/*-w64-mingw32-* "$MINGW_SHIM"/
export PATH="$MINGW_SHIM:$PATH"

echo "==> Build pinned SDL $SDL_VERSION (x86_64) — winebus's game-controller backend dlopens libSDL2"
# Build the EXACT SDL CrossOver ships (versions.env) from libsdl-org source, x86_64 to match Wine. This
# gives Wine's configure the SDL2 headers (so winebus compiles its SDL backend) AND the runtime dylib we
# bundle. A generic Homebrew libSDL2 aborted Wine off the main thread; this pinned build does not.
SDL_PREFIX="$WORK/sdl-install"
curl -fL "https://github.com/libsdl-org/SDL/releases/download/release-${SDL_VERSION}/SDL2-${SDL_VERSION}.tar.gz" -o sdl.tar.gz
rm -rf sdl-src sdl-build "$SDL_PREFIX" && mkdir sdl-src && tar -xzf sdl.tar.gz -C sdl-src --strip-components=1
# cmake itself is native (host tool); CMAKE_OSX_ARCHITECTURES makes the code x86_64. Its default search
# prefixes include its own install prefix — the arm64 Homebrew — so both Homebrew roots are ignored.
cmake -S sdl-src -B sdl-build -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_OSX_ARCHITECTURES=x86_64 -DCMAKE_OSX_DEPLOYMENT_TARGET=11.0 -DCMAKE_OSX_SYSROOT="$SDK" \
  -DCMAKE_IGNORE_PREFIX_PATH="/opt/homebrew;/usr/local" \
  -DCMAKE_INSTALL_PREFIX="$SDL_PREFIX" -DSDL_SHARED=ON -DSDL_STATIC=OFF
cmake --build sdl-build -j"$(sysctl -n hw.ncpu)"
cmake --install sdl-build
test -f "$SDL_PREFIX/lib/libSDL2-2.0.0.dylib" || { echo "ERROR: SDL build produced no libSDL2-2.0.0.dylib"; exit 1; }

echo "==> Configure + build (x86_64, wow64) — this takes ~30–60 min"
# Only Silo's own prefixes are visible, on every search path. LDFLAGS come before pkg-config's -L on the link
# line, so the GStreamer prefix goes FIRST (else `-lglib-2.0` could bind another glib). pkg-config is the
# native one with its default search path replaced (PKG_CONFIG_LIBDIR): its default is the arm64 Homebrew's
# .pc files, which describe arm64 libraries. SDL_PREFIX is there so --with-sdl finds its headers; DEPS_PREFIX
# carries gnutls/freetype/MoltenVK (macOS's linker doesn't search anything by default, so configure's
# link-time checks need these -L's).
export PKG_CONFIG="$PKGCONF"
export PKG_CONFIG_LIBDIR="$GST_PREFIX/lib/pkgconfig:$SDL_PREFIX/lib/pkgconfig:$DEPS_PREFIX/lib/pkgconfig"
export PKG_CONFIG_PATH=
# The rpath is CrossOver's own (measured on its winegstreamer.so / ntdll.so): from lib/wine/x86_64-unix it
# reaches <root>/lib64, where bundle-wine-dylibs.sh puts every third-party dylib with an @rpath install name
# — link-time references AND Wine's leaf-name dlopen()s (freetype, gnutls, SDL) resolve through it, with no
# DYLD_* variable. headerpad leaves room for the bundler's install_name_tool rewrites.
export LDFLAGS="-L$GST_PREFIX/lib -L$SDL_PREFIX/lib -L$DEPS_PREFIX/lib -Wl,-rpath,@loader_path/../../../lib64 -Wl,-headerpad_max_install_names"
export CPPFLAGS="-I$SDL_PREFIX/include -I$DEPS_PREFIX/include"
# CRITICAL: `arch -x86_64` only picks which slice of the (universal) clang/gcc DRIVER BINARY runs under
# Rosetta — it does NOT tell clang which architecture to GENERATE CODE FOR. Without an explicit `-arch
# x86_64`, clang defaults to the host's native arch (arm64 on Apple Silicon), so configure's link checks
# (e.g. AC_CHECK_LIB against gnutls) produce an arm64 conftest that can't link against the x86_64-only
# libraries in DEPS_PREFIX — "ld: ... found architecture 'x86_64', required architecture 'arm64'".
# Matches .github/workflows/build-wine.yml.
# -isysroot (the default SDK, made explicit): it removes clang's DEFAULT /usr/local search paths, so an
# x86_64 Homebrew still present on a dev box can't leak headers or libraries in — the local build sees what
# the CI runner sees (build-gst-libav.sh does the same; glib had linked Homebrew's libintl that way).
export CC="clang -arch x86_64 -isysroot $SDK"
export CXX="clang++ -arch x86_64 -isysroot $SDK"
rm -rf build install && mkdir build install && cd build
# -fvisibility=default: build Wine with all symbols visible so winemac.drv ('macdrv') exposes its
# Metal/window-surface helpers via dlsym — this is what lets **GPTK/D3DMetal GAMES** present correctly
# (without it the macOS surface path is broken for layered windows and D3D→Metal output is black). NOTE:
# this is NOT what fixes the Steam *client* CEF UI — that black window is fixed at RUNTIME by forcing CEF
# onto software rendering in the browser process (the --in-process-gpu steamwebhelper wrapper, see
# SteamBottle.installWebHelperWrapper), not by Metal presentation. Set on BOTH CFLAGS (Wine's Unix-side .so
# thunks, incl. winemac.so) AND CROSSCFLAGS (the PE-side built-in DLLs). -O2 keeps the optimization an
# explicit *FLAGS would otherwise drop. gnutls = Wine's schannel TLS (Steam's networking needs it).
# --with-sdl: build winebus's SDL game-controller backend (dlopens the pinned libSDL2 bundled below). With
# Wine's default Map Controllers=1 it remaps ANY recognized pad to a standard XInput gamepad — the
# "controllers just work" behaviour. An earlier --without-sdl was a workaround for a generic Homebrew
# libSDL2 aborting Wine off the main thread; the pinned SDL_VERSION (= CrossOver's) doesn't, so SDL is on.
$ARCH env CFLAGS="-fvisibility=default -O2" CROSSCFLAGS="-fvisibility=default -O2" \
  PKG_CONFIG="$PKG_CONFIG" PKG_CONFIG_LIBDIR="$PKG_CONFIG_LIBDIR" PKG_CONFIG_PATH= LDFLAGS="$LDFLAGS" CPPFLAGS="$CPPFLAGS" \
  "$WORK/$WINE_SRC/configure" --prefix="$WORK/install" \
  --enable-archs=i386,x86_64 --disable-tests --without-x \
  --with-freetype --with-gstreamer --with-gnutls --with-sdl \
  x86_64_CC="$MINGW/bin/x86_64-w64-mingw32-gcc" i386_CC="$MINGW/bin/i686-w64-mingw32-gcc"
# /usr/bin/make explicitly: it's universal, while Xcode 27's own make (first on PATH in an Xcode-launched
# shell) is arm64-only, so `arch -x86_64 make` failed with "Bad CPU type in executable".
# Wine's build tools run during make, and those that link a shipped library (sfnt2fon → freetype) find it
# through the same rpath as the runtime, @loader_path/../../../lib64 — from build/tools/<tool>/ that is
# $WORK/lib64. Our libraries have @rpath ids (Homebrew's had absolute paths, so this never came up), so point
# $WORK/lib64 at them for the build only.
ln -sfn "$DEPS_PREFIX/lib" "$WORK/lib64"
$ARCH /usr/bin/make -j"$(sysctl -n hw.ncpu)"
$ARCH /usr/bin/make install
rm -f "$WORK/lib64"

echo "==> Build the steamwebhelper wrapper (forces CEF --in-process-gpu + software GL so Steam's UI paints)"
mkdir -p "$WORK/install/share/silo"
WRAPPER="$WORK/install/share/silo/steamwebhelper-wrapper.exe"
"$MINGW/bin/x86_64-w64-mingw32-gcc" -O2 -municode -mwindows \
  -o "$WRAPPER" "$ROOT/Scripts/steamwebhelper-wrapper.c"
# The wrapper is load-bearing — fail the build if its CEF flags are wrong (shared check, also run in CI).
python3 "$ROOT/Scripts/check-webhelper-wrapper.py" "$WRAPPER"

echo "==> Bundle dependency dylibs + GStreamer into lib64 (self-contained, CrossOver's layout)"
# SILO_DEPS_PREFIX: the libraries Wine dlopen()s come from build-deps.sh's prefix (and a Homebrew one in the
# closure is an error). SILO_SDL_DYLIB tells the bundler to ship our pinned libSDL2 (winebus dlopens it by leaf name, resolved
# through the lib64 rpath above).
SILO_DEPS_PREFIX="$DEPS_PREFIX" SILO_GST_STACK="$GST_STACK" SILO_SDL_DYLIB="$SDL_PREFIX/lib/libSDL2-2.0.0.dylib" \
  "$ROOT/Scripts/bundle-wine-dylibs.sh" "$WORK/install"

# Sign every Mach-O in the tree (wine64, wineserver, winemac.so, and all other PE/Unix-side .so's
# `make install` produced) with the SAME identity used for the bundled dylibs and the app itself.
# Without this, only the copied third-party dylibs would carry a real Developer ID and the actual
# Wine binaries would ship completely unsigned — inconsistent, and still effectively "ad-hoc" in
# practice. Uses SILO_SIGN_IDENTITY if set (see Scripts/sign.sh); falls back to ad-hoc ("-"),
# matching upstream, when it isn't. Shared with the CI workflow (which once skipped it, see the script).
"$ROOT/Scripts/sign-wine-tree.sh" "$WORK/install"

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
