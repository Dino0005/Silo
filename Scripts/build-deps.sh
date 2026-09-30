#!/usr/bin/env bash
# Build the third-party libraries Silo's Wine runtime SHIPS (x86_64) from source instead of x86_64 Homebrew:
# gmp, nettle (static), gnutls, freetype — the versions in the CrossOver FOSS tarball.
#
# Why: Homebrew's installer now refuses an x86_64 install on macOS ("Homebrew on macOS is only supported on
# Apple Silicon processors!" — measured on the CI runner, 2026-09-29), and x86_64 bottles are disappearing,
# so a build that takes these from x86_64 Homebrew can't run on a fresh Mac. gmp and gnutls are the tarball's
# own sources; nettle and freetype come from their official releases at the same versions, sha256-pinned in
# versions.env (the tarball's copies are git exports without their generated build files).
# Built the way CrossOver builds them, measured on its lib64: gnutls depends only on libgmp (nettle/hogweed
# and libtasn1 folded in; no p11-kit, idn, unistring or NLS); freetype only on the system's libbz2 (zlib
# built in, no libpng/harfbuzz/brotli).
#
# Output: .wine-build/deps/prefix — headers + pkg-config for Wine's configure (build-wine.sh puts it first on
# PKG_CONFIG_PATH/LDFLAGS) and the dylibs bundle_wine_dylibs.py relocates into lib64 (SILO_DEPS_PREFIX).
# Install names are @rpath/<leaf> from the start.
#
# Only host tools are needed (make, m4, a pkg-config) — they run natively and never ship.
#
# Usage: Scripts/build-deps.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
set -a; . "$ROOT/versions.env"; set +a
WORK="$ROOT/.wine-build/deps"
SRC="${SILO_CX_SOURCES:-$ROOT/.wine-build/src/sources}"
PREFIX="$WORK/prefix"
JOBS="$(sysctl -n hw.ncpu)"
ARCH="arch -x86_64"
SDK="$(xcrun --show-sdk-path)"
[ -d "$SRC/gnutls" ] && [ -d "$SRC/freetype" ] || { echo "ERROR: CrossOver sources not found at $SRC"; exit 1; }
PKGCONF="$(command -v pkgconf || command -v pkg-config || true)"
[ -n "$PKGCONF" ] || { echo "ERROR: no pkg-config on PATH (brew install pkgconf — the native one is fine)"; exit 1; }

# x86_64 code, the SDK made explicit so clang's default /usr/local search paths (x86_64 Homebrew, if any)
# can never leak in, and @rpath install names so the bundler has nothing to rewrite.
export CC="clang -arch x86_64 -isysroot $SDK -mmacosx-version-min=11.0"
export CXX="clang++ -arch x86_64 -isysroot $SDK -mmacosx-version-min=11.0"
export CFLAGS="-O2 -fPIC"
export LDFLAGS="-L$PREFIX/lib -Wl,-headerpad_max_install_names"
export CPPFLAGS="-I$PREFIX/include"
export PKG_CONFIG="$PKGCONF" PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig" PKG_CONFIG_PATH=
# --host = --build = generic x86_64: autotools stays in native mode (configure's test programs run under
# Rosetta) and gmp picks its GENERIC x86_64 code instead of tuning for whatever CPU Rosetta reports.
TRIPLE=x86_64-apple-darwin

rm -rf "$PREFIX" && mkdir -p "$PREFIX" "$WORK/build"

autotools() {   # <name> <source dir> [configure options...]
  local name="$1" src="$2"; shift 2
  echo "==> $name"
  rm -rf "$WORK/build/$name" && cp -Rp "$src" "$WORK/build/$name"
  ( cd "$WORK/build/$name" \
    && $ARCH /bin/sh ./configure --prefix="$PREFIX" --build=$TRIPLE --host=$TRIPLE "$@" > "$WORK/$name-configure.log" 2>&1 \
    && $ARCH /usr/bin/make -j"$JOBS" > "$WORK/$name-make.log" 2>&1 \
    && $ARCH /usr/bin/make install > "$WORK/$name-install.log" 2>&1 ) \
    || { echo "ERROR: $name failed — see $WORK/$name-*.log"; exit 1; }
}

fetch() {   # <url> <sha256> <dest dir> — an official release tarball, verified, unpacked flat
  local url="$1" sha="$2" dest="$3" file="$WORK/$(basename "$1")"
  curl -fsSL "$url" -o "$file"
  echo "$sha  $file" | shasum -a 256 -c --status || { echo "ERROR: sha256 mismatch for $url"; exit 1; }
  rm -rf "$dest" && mkdir -p "$dest" && tar -xf "$file" -C "$dest" --strip-components=1
}

autotools gmp "$SRC/gnutls/gmp" --enable-shared --disable-static
# nettle: the official release, not the tarball's copy (a git export missing its Makefile.in; see versions.env).
fetch "https://ftp.gnu.org/gnu/nettle/nettle-${NETTLE_VERSION}.tar.gz" "$NETTLE_SHA256" "$WORK/nettle-src"
autotools nettle "$WORK/nettle-src" --disable-shared --enable-static --disable-documentation \
  --disable-openssl --with-include-path="$PREFIX/include" --with-lib-path="$PREFIX/lib"
autotools gnutls "$SRC/gnutls/gnutls" --enable-shared --disable-static \
  --with-included-libtasn1 --with-included-unistring --without-p11-kit --without-idn --disable-nls \
  --disable-cxx --disable-doc --disable-manpages --disable-tests --disable-tools --disable-guile \
  --without-zlib --without-brotli --without-zstd --without-tpm --without-tpm2 --disable-libdane \
  NETTLE_LIBS="-lnettle" HOGWEED_LIBS="-lhogweed -lgmp" GMP_LIBS="-lgmp"   # static nettle: gmp spelled out

# freetype: the official release, not the tarball's copy (a git export without builds/unix/configure).
fetch "https://download.savannah.gnu.org/releases/freetype/freetype-${FREETYPE_VERSION}.tar.xz" "$FREETYPE_SHA256" \
  "$WORK/freetype-src"
autotools freetype "$WORK/freetype-src" --enable-shared --disable-static \
  --with-zlib=no --with-bzip2=yes --with-png=no --with-harfbuzz=no --with-brotli=no

echo "==> @rpath install names + check"
for f in "$PREFIX"/lib/*.dylib; do
  [ -L "$f" ] && continue
  install_name_tool -id "@rpath/$(basename "$f")" "$f"
  for ref in $(otool -L "$f" | awk 'NR>1 {print $1}' | grep "^$PREFIX/" || true); do
    install_name_tool -change "$ref" "@rpath/$(basename "$ref")" "$f"
  done
  codesign --force --sign "${SILO_SIGN_IDENTITY:--}" "$f" 2>/dev/null
  bad="$(otool -L "$f" | awk 'NR>1 {print $1}' | grep -vE '^(@rpath/|/usr/lib/|/System/)' || true)"
  [ -z "$bad" ] || { echo "ERROR: $(basename "$f") still references: $bad"; exit 1; }
  [ "$(lipo -archs "$f")" = "x86_64" ] || { echo "ERROR: $(basename "$f") is not x86_64-only"; exit 1; }
done
ls "$PREFIX/lib" | grep -E '\.dylib$' | tr '\n' ' '; echo
echo "Built: $PREFIX"
