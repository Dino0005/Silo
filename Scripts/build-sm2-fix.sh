#!/usr/bin/env bash
# Build Silo's Spider-Man 2 fix carrier (Proxy/sm2-tpose-fix) into the committed resource
# Sources/SiloKit/Resources/silo-sm2-fix-amd_ags_x64.dll.
#
# Same scheme as Scripts/build-depth-proxy.sh: a Windows PE needs a mingw cross-compiler, which the normal
# SwiftPM build (constraint #1) doesn't have, so the built file is COMMITTED and this script only regenerates
# it after the source changes. Toolchain: mstorsjo/llvm-mingw at LLVM_MINGW_VERSION (versions.env), fetched
# once into .toolchains/ (git-ignored). No Homebrew.
#
# Usage: Scripts/build-sm2-fix.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
. "$ROOT/versions.env"

MINGW_DIR="llvm-mingw-${LLVM_MINGW_VERSION}-ucrt-macos-universal"
TOOLCHAINS="$ROOT/.toolchains"
CC="$TOOLCHAINS/$MINGW_DIR/bin/x86_64-w64-mingw32-gcc"
SRC="$ROOT/Proxy/sm2-tpose-fix"
OUT="$ROOT/Sources/SiloKit/Resources/silo-sm2-fix-amd_ags_x64.dll"

if [ ! -x "$CC" ]; then
  echo "==> Fetch llvm-mingw $LLVM_MINGW_VERSION"
  mkdir -p "$TOOLCHAINS"
  curl -fL "https://github.com/mstorsjo/llvm-mingw/releases/download/${LLVM_MINGW_VERSION}/${MINGW_DIR}.tar.xz" \
    -o "$TOOLCHAINS/llvm-mingw.tar.xz"
  tar -xf "$TOOLCHAINS/llvm-mingw.tar.xz" -C "$TOOLCHAINS"
  rm "$TOOLCHAINS/llvm-mingw.tar.xz"
fi

echo "==> Build $(basename "$OUT")"
# Built as amd_ags_x64.dll (its export-table name is the output file name), then stored under the resource name.
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
"$CC" -O2 -shared -s -std=c11 -Wall -Wextra -Wno-unused-parameter -Wno-cast-function-type \
  -o "$TMP/amd_ags_x64.dll" "$SRC/carrier.c" "$SRC/sm2fix_core.c" "$SRC/carrier.def" -ldxguid
cp "$TMP/amd_ags_x64.dll" "$OUT"

# The marker Silo uses to recognise its own file in a game folder must survive.
grep -q "Silo Spider-Man 2 fix carrier" "$OUT" || { echo "ERROR: marker missing from $OUT"; exit 1; }
echo "==> Built $OUT"
