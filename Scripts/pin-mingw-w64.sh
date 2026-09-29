#!/usr/bin/env bash
# Provide the pinned mingw-w64 cross compiler Wine's Windows-side DLLs are built with (versions.env:
# MINGW_W64_BOTTLE / MINGW_W64_BOTTLE_SHA256 / MINGW_GCC_VERSION), and print its directory on the LAST line.
# Shared by Scripts/build-wine.sh and .github/workflows/build-wine.yml so the two can't drift.
#
# Why pinned: it used to be whatever mingw-w64 Homebrew happened to have installed (GCC 16.1.0 here on
# 2026-09-29, 16.2.0 in a fresh `brew install` the same day; CrossOver uses 13.2), so a runtime built in CI
# could differ from the one tested. The tested one is GCC 16.1.0 (DMC5 + TEKKEN 8 verified); llvm-mingw
# 20231017 was tried and broke Steam's sign-in.
#
# Usage: Scripts/pin-mingw-w64.sh <scratch-dir>
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
set -a; . "$ROOT/versions.env"; set +a
TOOLS="${1:?usage: pin-mingw-w64.sh <scratch-dir>}"
ARCH="arch -x86_64"
BREW=/usr/local/bin/brew
export HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_INSTALL_CLEANUP=1 HOMEBREW_NO_ENV_HINTS=1 HOMEBREW_NO_INSTALL_UPGRADE=1
echo "==> mingw-w64 $MINGW_W64_BOTTLE (GCC $MINGW_GCC_VERSION)" >&2
# Wine's Windows-side DLLs used to be compiled by whatever mingw-w64 Homebrew happened to have installed, so a
# runtime built elsewhere (CI) could differ from the one tested here. Pinned to one exact bottle. brew must pour
# it itself: a bottle carries /usr/local/Cellar/… paths and @@HOMEBREW_…@@ placeholders that brew rewrites on
# install, even inside object files (crt2.o differs by 4 bytes before/after) — measured, unpacking it by hand
# gave a compiler that picked the wrong ld and rejected its own crt2.o. So: if that revision isn't the one
# installed, fetch its bottle by digest from Homebrew's registry, verify it, and `brew install` the file.
BREW_PFX="$($ARCH "$BREW" --prefix)"
MINGW="$BREW_PFX/Cellar/mingw-w64/$MINGW_W64_BOTTLE"
if [ ! -x "$MINGW/bin/x86_64-w64-mingw32-gcc" ]; then
  mkdir -p "$TOOLS"
  BOTTLE="$TOOLS/mingw-w64--$MINGW_W64_BOTTLE.x86_64.bottle.tar.gz"
  TOKEN="$(curl -fsSL "https://ghcr.io/token?scope=repository:homebrew/core/mingw-w64:pull" \
    | python3 -c 'import sys,json; print(json.load(sys.stdin)["token"])')"
  curl -fsSL -H "Authorization: Bearer $TOKEN" \
    "https://ghcr.io/v2/homebrew/core/mingw-w64/blobs/sha256:$MINGW_W64_BOTTLE_SHA256" -o "$BOTTLE"
  echo "$MINGW_W64_BOTTLE_SHA256  $BOTTLE" | shasum -a 256 -c - >&2 || { echo "ERROR: mingw-w64 bottle digest mismatch"; exit 1; }
  if $ARCH "$BREW" list --versions mingw-w64 >/dev/null 2>&1; then $ARCH "$BREW" unlink mingw-w64 || true; fi
  $ARCH "$BREW" install "$BOTTLE" >&2
fi
[ -x "$MINGW/bin/x86_64-w64-mingw32-gcc" ] || { echo "ERROR: mingw-w64 $MINGW_W64_BOTTLE not at $MINGW"; exit 1; }
mkdir -p "$TOOLS"
for t in x86_64 i686; do
  v="$($ARCH "$MINGW/bin/$t-w64-mingw32-gcc" -dumpfullversion)"
  [ "$v" = "$MINGW_GCC_VERSION" ] \
    || { echo "ERROR: $t-w64-mingw32-gcc is GCC $v, expected $MINGW_GCC_VERSION (versions.env)"; exit 1; }
  # …and it must actually compile (a missing compiler-internal library only shows up here).
  echo 'int main(void){return 0;}' > "$TOOLS/probe.c"
  $ARCH "$MINGW/bin/$t-w64-mingw32-gcc" "$TOOLS/probe.c" -o "$TOOLS/probe-$t.exe" \
    || { echo "ERROR: the pinned $t-w64-mingw32-gcc cannot compile"; exit 1; }
done
echo "$MINGW"
