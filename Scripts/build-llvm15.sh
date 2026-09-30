#!/usr/bin/env bash
# Build the LLVM DXMT links into winemetal.so (its DXBC → Metal AIR shader converter, airconv) — x86_64,
# static libraries — from the official llvm-project release, with the cmake recipe DXMT's own configure.sh
# uses for its x86_64 darwin build (no targets, no tools, zstd off) — except ASSERTIONS OFF, like the Homebrew
# llvm@15 every tested DXMT was built with: with them on, winemetal.so grew from ~20 MB to 31.8 MB (CrossOver's
# is 24 MB) and every shader conversion pays for the checks (measured 2026-09-30).
# Prints the install prefix on the LAST line (build-dxmt.sh passes it as -Dnative_llvm_path).
#
# Why: it used to be x86_64 Homebrew's llvm@15, and an x86_64 Homebrew can no longer be installed on a fresh
# Mac ("only supported on Apple Silicon", measured on the CI runner 2026-09-29). Unlike the Wine build's
# host tools, this LLVM SHIPS — statically inside winemetal.so — so it's built from source like the rest.
#
# Idempotent: skips the build when the prefix already holds this version (the CI caches it).
#
# Usage: Scripts/build-llvm15.sh [prefix]   (default: .dxmt-llvm/llvm-<version> — outside .dxmt-build, which
#                                            build-dxmt.sh wipes)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
set -a; . "$ROOT/versions.env"; set +a
PREFIX="${1:-$ROOT/.dxmt-llvm/llvm-$DXMT_LLVM_VERSION}"
WORK="$ROOT/.dxmt-llvm/work"
STAMP="$PREFIX/.silo-llvm-$DXMT_LLVM_VERSION-noassert"   # the recipe is part of the stamp

if [ -f "$STAMP" ] && [ -f "$PREFIX/lib/libLLVMCore.a" ]; then
  echo "==> LLVM $DXMT_LLVM_VERSION already built at $PREFIX" >&2
  echo "$PREFIX"; exit 0
fi
command -v cmake >/dev/null || { echo "ERROR: cmake not on PATH (Scripts/host-tools.sh)"; exit 1; }
command -v ninja >/dev/null || { echo "ERROR: ninja not on PATH (build-dxmt.sh provides it)"; exit 1; }

echo "==> LLVM $DXMT_LLVM_VERSION (x86_64, static, DXMT's recipe, assertions off) — ~6 min on an M-series Mac, longer on CI" >&2
mkdir -p "$WORK"
TARBALL="$WORK/llvm-project-$DXMT_LLVM_VERSION.src.tar.xz"
[ -f "$TARBALL" ] || curl -fsSL \
  "https://github.com/llvm/llvm-project/releases/download/llvmorg-$DXMT_LLVM_VERSION/llvm-project-$DXMT_LLVM_VERSION.src.tar.xz" \
  -o "$TARBALL"
echo "$DXMT_LLVM_SHA256  $TARBALL" | shasum -a 256 -c --status || { echo "ERROR: LLVM tarball sha256 mismatch"; exit 1; }
rm -rf "$WORK/src" "$WORK/build" "$PREFIX" && mkdir -p "$WORK/src"
tar -xf "$TARBALL" -C "$WORK/src" --strip-components=1

SDK="$(xcrun --show-sdk-path)"
# cmake and ninja are native host tools; CMAKE_OSX_ARCHITECTURES makes the code x86_64 (llvm-tblgen, which runs
# during the build, is x86_64 too and simply runs under Rosetta). The SDK is explicit and both Homebrew roots
# are ignored, so no library from either can be found (the options below turn every optional one off anyway).
cmake -S "$WORK/src/llvm" -B "$WORK/build" -G Ninja \
  -DCMAKE_INSTALL_PREFIX="$PREFIX" \
  -DCMAKE_OSX_ARCHITECTURES=x86_64 -DCMAKE_OSX_SYSROOT="$SDK" -DCMAKE_OSX_DEPLOYMENT_TARGET=11.0 \
  -DCMAKE_IGNORE_PREFIX_PATH="/opt/homebrew;/usr/local" \
  -DLLVM_HOST_TRIPLE=x86_64-apple-darwin \
  -DLLVM_ENABLE_ASSERTIONS=Off \
  -DLLVM_ENABLE_ZSTD=Off \
  -DCMAKE_BUILD_TYPE=Release \
  -DLLVM_TARGETS_TO_BUILD="" \
  -DLLVM_BUILD_TOOLS=Off \
  -DLLVM_INCLUDE_TESTS=Off -DLLVM_INCLUDE_BENCHMARKS=Off -DLLVM_INCLUDE_EXAMPLES=Off \
  -DBUG_REPORT_URL="https://github.com/3Shain/dxmt" \
  -DPACKAGE_VENDOR="DXMT" \
  -DLLVM_VERSION_PRINTER_SHOW_HOST_TARGET_INFO=Off \
  > "$WORK/cmake.log" 2>&1 || { echo "ERROR: LLVM cmake failed — see $WORK/cmake.log"; exit 1; }
ninja -C "$WORK/build" install > "$WORK/build.log" 2>&1 || { echo "ERROR: LLVM build failed — see $WORK/build.log"; exit 1; }

[ "$(lipo -archs "$PREFIX/lib/libLLVMCore.a" 2>/dev/null)" = "x86_64" ] \
  || { echo "ERROR: $PREFIX/lib/libLLVMCore.a missing or not x86_64"; exit 1; }
touch "$STAMP"
rm -rf "$WORK/src" "$WORK/build"   # ~2 GB of intermediates; the tarball stays for a rebuild
echo "$PREFIX"
