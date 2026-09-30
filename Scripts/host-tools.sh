#!/usr/bin/env bash
# Install the HOST tools the Wine build runs (bison >= 3, cmake, pkgconf) from the native arm64 Homebrew, and
# print the directories to put first on PATH on the LAST line (colon-separated).
# Shared by Scripts/build-wine.sh and .github/workflows/build-wine.yml so the two can't drift.
#
# Why native: they only run on the build machine — nothing they are ships in the runtime — and an x86_64
# Homebrew can no longer be installed on a fresh Mac ("Homebrew on macOS is only supported on Apple Silicon
# processors!", measured on the CI runner 2026-09-29). Every x86_64 library the runtime ships is built from
# source by Scripts/build-deps.sh / build-gst-libav.sh instead.
#
# Usage: Scripts/host-tools.sh
set -euo pipefail
BREW=/opt/homebrew/bin/brew
[ -x "$BREW" ] || { echo "ERROR: native Homebrew not found at $BREW (https://brew.sh)"; exit 1; }
export HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_INSTALL_CLEANUP=1 HOMEBREW_NO_ENV_HINTS=1 HOMEBREW_NO_INSTALL_UPGRADE=1
softwareupdate --install-rosetta --agree-to-license >/dev/null 2>&1 || true   # the x86_64 build runs under it
"$BREW" install bison cmake pkgconf >&2
# bison is keg-only (macOS has its own 2.3, too old for Wine and glib): its bin dir must come first explicitly.
echo "$("$BREW" --prefix bison)/bin:$("$BREW" --prefix)/bin"
