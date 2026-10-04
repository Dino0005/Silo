#!/usr/bin/env bash
# Sign every Mach-O in an installed Wine tree (wine64, wineserver, the loader, winemac.so and every other
# Unix-side .so `make install` produced) with SILO_SIGN_IDENTITY, or ad-hoc ("-") when it isn't set.
# Shared by Scripts/build-wine.sh and .github/workflows/build-wine.yml so the two can't drift.
#
# It isn't cosmetic. The window-owning loader, lib/wine/x86_64-unix/wine, embeds an Info.plist
# (__TEXT,__info_plist: LSUIElement, NSPrincipalClass WineApplication), and macOS only honours an embedded
# Info.plist when the binary is signed. Unsigned, LaunchServices registers every Wine process with no bundle
# at all, and Stage Manager on macOS 27 shows Steam's window with NO icon; signed, it gets the generic one,
# exactly like CrossOver's (signed) loader. Measured 2026-10-04: the CI build had skipped this step while
# local builds ran it — the only difference between the two.
#
#   Scripts/sign-wine-tree.sh <install-root>
set -euo pipefail
ROOT="${1:?usage: sign-wine-tree.sh <install-root>}"
IDENTITY="${SILO_SIGN_IDENTITY:--}"
echo "==> Signing Wine tree with identity: $IDENTITY"
# -exec ... \; (not `find | xargs`): xargs on macOS (BSD) can fail outright with "command line cannot be
# assembled, too long" when the calling shell's environment is already large (as it is in build-wine.sh,
# with PKG_CONFIG_PATH/LDFLAGS/CPPFLAGS exported) — even with -I{} substituting one file per invocation.
# -exec spawns one process per file directly from find, with no command-line assembly step.
find "$ROOT" -type f \( -perm -u+x -o -name '*.so' -o -name '*.dylib' \) \
  -exec sh -c 'file "$1" | grep -q "Mach-O" && codesign --force --sign "$2" "$1" 2>/dev/null' _ {} "$IDENTITY" \;

# The one that matters for the window manager must actually carry it.
LOADER="$ROOT/lib/wine/x86_64-unix/wine"
if [ -f "$LOADER" ]; then
  info="$(codesign -dv "$LOADER" 2>&1 || true)"
  if ! printf '%s\n' "$info" | grep -q "Info.plist entries="; then
    echo "error: $LOADER is not signed with its embedded Info.plist:" >&2
    printf '%s\n' "$info" >&2
    exit 1
  fi
fi
