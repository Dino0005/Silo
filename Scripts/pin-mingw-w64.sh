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
# Native (arm64) Homebrew, the arm64 bottle of that SAME revision (same GCC 16.1.0, same target code): an x86_64
# Homebrew can no longer be installed on a fresh Mac ("only supported on Apple Silicon", measured on the CI runner
# 2026-09-29). The compiler runs on the host; what it produces is Windows PE code either way.
#
# Usage: Scripts/pin-mingw-w64.sh <scratch-dir>
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
set -a; . "$ROOT/versions.env"; set +a
TOOLS="${1:?usage: pin-mingw-w64.sh <scratch-dir>}"
BREW=/opt/homebrew/bin/brew
[ -x "$BREW" ] || { echo "ERROR: native Homebrew not found at $BREW (https://brew.sh)"; exit 1; }
export HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_INSTALL_CLEANUP=1 HOMEBREW_NO_ENV_HINTS=1 HOMEBREW_NO_INSTALL_UPGRADE=1
echo "==> mingw-w64 $MINGW_W64_BOTTLE (GCC $MINGW_GCC_VERSION)" >&2
# brew must pour the bottle itself: a bottle carries Cellar paths and @@HOMEBREW_…@@ placeholders that brew
# rewrites on install, even inside object files (crt2.o differs by 4 bytes before/after) — measured, unpacking
# it by hand gave a compiler that picked the wrong ld and rejected its own crt2.o. And brew 6 no longer installs
# a bottle FILE ("No available formula"). So: the formula exactly as homebrew-core had it at
# MINGW_W64_FORMULA_COMMIT (its bottle block lists our digest), in a local tap, with root_url pointing back at
# homebrew-core's registry — brew then downloads that bottle, checks its sha256 and pours it (measured
# 2026-09-30). Only mingw-w64 itself is pinned; its runtime deps (gmp, mpfr, isl…) are current bottles.
BREW_PFX="$("$BREW" --prefix)"
MINGW="$BREW_PFX/Cellar/mingw-w64/$MINGW_W64_BOTTLE"
if [ ! -x "$MINGW/bin/x86_64-w64-mingw32-gcc" ]; then
  mkdir -p "$TOOLS"
  FORMULA="$TOOLS/mingw-w64.rb"
  curl -fsSL "https://raw.githubusercontent.com/Homebrew/homebrew-core/$MINGW_W64_FORMULA_COMMIT/Formula/m/mingw-w64.rb" \
    -o "$FORMULA"
  grep -q "arm64_tahoe: *\"$MINGW_W64_BOTTLE_SHA256\"" "$FORMULA" \
    || { echo "ERROR: formula at $MINGW_W64_FORMULA_COMMIT doesn't list bottle $MINGW_W64_BOTTLE_SHA256"; exit 1; }
  # Never `brew tap silo/pinned`: for a tap that isn't there it would clone github.com/silo/homebrew-pinned.
  TAP="$("$BREW" --repository)/Library/Taps/silo/homebrew-pinned"
  [ -d "$TAP" ] || "$BREW" tap-new --no-git silo/pinned >&2
  mkdir -p "$TAP/Formula"
  sed 's|^  bottle do$|  bottle do\n    root_url "https://ghcr.io/v2/homebrew/core"|' "$FORMULA" > "$TAP/Formula/mingw-w64.rb"
  if "$BREW" list --versions mingw-w64 >/dev/null 2>&1; then "$BREW" unlink mingw-w64 >&2 || true; fi
  "$BREW" install --force-bottle silo/pinned/mingw-w64 >&2
fi
[ -x "$MINGW/bin/x86_64-w64-mingw32-gcc" ] || { echo "ERROR: mingw-w64 $MINGW_W64_BOTTLE not at $MINGW"; exit 1; }
mkdir -p "$TOOLS"
for t in x86_64 i686; do
  v="$("$MINGW/bin/$t-w64-mingw32-gcc" -dumpfullversion)"
  [ "$v" = "$MINGW_GCC_VERSION" ] \
    || { echo "ERROR: $t-w64-mingw32-gcc is GCC $v, expected $MINGW_GCC_VERSION (versions.env)"; exit 1; }
  # …and it must actually compile (a missing compiler-internal library only shows up here).
  echo 'int main(void){return 0;}' > "$TOOLS/probe.c"
  "$MINGW/bin/$t-w64-mingw32-gcc" "$TOOLS/probe.c" -o "$TOOLS/probe-$t.exe" \
    || { echo "ERROR: the pinned $t-w64-mingw32-gcc cannot compile"; exit 1; }
done
echo "$MINGW"
