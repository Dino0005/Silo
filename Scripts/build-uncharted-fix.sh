#!/usr/bin/env bash
# Build Silo's Uncharted fix d3d12 proxy (Proxy/uncharted-quit-fix) into the committed resource
# Sources/SiloKit/Resources/silo-uncharted-fix-d3d12.dll.
#
# Same scheme as Scripts/build-depth-proxy.sh: a Windows PE needs a mingw cross-compiler, which the normal
# SwiftPM build (constraint #1) doesn't have, so the built file is COMMITTED and this script only regenerates
# it after the source changes. Toolchain: mstorsjo/llvm-mingw at LLVM_MINGW_VERSION (versions.env), fetched
# once into .toolchains/ (git-ignored). No Homebrew.
#
# Usage: Scripts/build-uncharted-fix.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
. "$ROOT/versions.env"

MINGW_DIR="llvm-mingw-${LLVM_MINGW_VERSION}-ucrt-macos-universal"
TOOLCHAINS="$ROOT/.toolchains"
CC="$TOOLCHAINS/$MINGW_DIR/bin/x86_64-w64-mingw32-gcc"
SRC="$ROOT/Proxy/uncharted-quit-fix"
OUT="$ROOT/Sources/SiloKit/Resources/silo-uncharted-fix-d3d12.dll"

if [ ! -x "$CC" ]; then
  echo "==> Fetch llvm-mingw $LLVM_MINGW_VERSION"
  mkdir -p "$TOOLCHAINS"
  curl -fL "https://github.com/mstorsjo/llvm-mingw/releases/download/${LLVM_MINGW_VERSION}/${MINGW_DIR}.tar.xz" \
    -o "$TOOLCHAINS/llvm-mingw.tar.xz"
  tar -xf "$TOOLCHAINS/llvm-mingw.tar.xz" -C "$TOOLCHAINS"
  rm "$TOOLCHAINS/llvm-mingw.tar.xz"
fi

echo "==> Build $(basename "$OUT")"
# Built as d3d12.dll (its export-table name is the output file name), then stored under the resource name.
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
"$CC" -O2 -shared -s -std=gnu11 -Wall -Wextra -Wno-unused-parameter -Wno-cast-function-type \
  -o "$TMP/d3d12.dll" "$SRC/proxy.c" "$SRC/thunks.S" "$SRC/proxy.def" -Wl,--kill-at -ldxguid
cp "$TMP/d3d12.dll" "$OUT"

# The marker Silo uses to recognise its own file in a game folder must survive.
grep -q "Silo Uncharted fix d3d12 proxy" "$OUT" || { echo "ERROR: marker missing from $OUT"; exit 1; }
echo "==> Built $OUT"
