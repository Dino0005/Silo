#!/usr/bin/env bash
# Install CrossOver's own Wine (from an installed CrossOver.app) into Silo's Runtimes dir for LOCAL
# testing — automates what we did by hand: copy CrossOver's internal Wine tree, symlink wine64 to its
# real Mach-O loader (wineloader — CrossOver's own top-level "wine" is a Perl wrapper script, not a
# binary, so `bin/wine64` must point at `wineloader` for Silo's runtime discovery / dylib bundling to
# work), then bundle its dependency dylibs exactly like install-local-wine.sh does.
#
# Usage: Scripts/install-local-crossover-wine.sh [/path/to/CrossOver.app]
#   Defaults to /Applications/CrossOver.app. The runtime is named wine-crossover-<version>, where
#   <version> is read from CrossOver.app's own Info.plist — so re-running after a CrossOver update
#   installs alongside the old one under a new name, instead of silently overwriting it.
set -euo pipefail

APP="${1:-/Applications/CrossOver.app}"

if [ ! -d "$APP" ]; then
  echo "ERROR: '$APP' not found."
  echo "Usage: Scripts/install-local-crossover-wine.sh [/path/to/CrossOver.app]"
  exit 1
fi

PLIST="$APP/Contents/Info.plist"
if [ ! -f "$PLIST" ]; then
  echo "ERROR: '$PLIST' not found — is '$APP' really a CrossOver.app bundle?"
  exit 1
fi

# CFBundleShortVersionString first (the human "26.2.0" version); CFBundleVersion as a fallback for any
# build that only sets one of the two.
VER="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$PLIST" 2>/dev/null || true)"
if [ -z "$VER" ]; then
  VER="$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$PLIST" 2>/dev/null || true)"
fi
if [ -z "$VER" ]; then
  echo "ERROR: could not read a version string from '$PLIST'."
  echo "Pass a name manually by copying this script's steps, or check the Info.plist by hand:"
  echo "  /usr/libexec/PlistBuddy -c 'Print' '$PLIST' | grep -i version"
  exit 1
fi

SRC="$APP/Contents/SharedSupport/CrossOver"
if [ ! -d "$SRC" ]; then
  echo "ERROR: '$SRC' not found — CrossOver.app's internal layout may differ from what this script expects."
  exit 1
fi

NAME="wine-crossover-$VER"
DEST="$HOME/Library/Application Support/Silo/Runtimes/$NAME"

echo "==> CrossOver version: $VER"
echo "==> Installing to: $DEST"

mkdir -p "$(dirname "$DEST")"
rm -rf "$DEST"
mkdir -p "$DEST"
cp -R "$SRC"/. "$DEST"/

# CrossOver's own top-level "wine" (and bin/wine64, if present) is a Perl dispatcher script, not a Mach-O
# binary — Silo's runtime discovery / dylib-bundling (lipo, otool) needs a real executable at bin/wine64.
# wineloader is that real binary. This is the exact fix we worked out by hand: `file bin/wineloader` showed
# "Mach-O 64-bit executable x86_64" while `bin/wine`/`bin/wine64` showed "Perl script text executable".
if [ ! -f "$DEST/bin/wineloader" ]; then
  echo "ERROR: '$DEST/bin/wineloader' not found — CrossOver's internal layout may have changed."
  echo "Installed but NOT yet usable: fix the wine64 symlink by hand before using this runtime."
  exit 1
fi
rm -f "$DEST/bin/wine64"
ln -s wineloader "$DEST/bin/wine64"
echo "==> Linked bin/wine64 -> bin/wineloader (the real Mach-O loader, not CrossOver's Perl wine script)"

# Bundle its dependency dylibs (freetype/gstreamer/…) so it's self-contained, matching install-local-wine.sh.
"$(dirname "$0")/bundle-wine-dylibs.sh" "$DEST" || echo "(warning: dylib bundling failed — wine may need Homebrew deps)"

echo "Installed CrossOver's Wine '$NAME' for local testing:"
echo "  $DEST"
echo "Open Silo → Wine Manager → Wine tab → Set default."

# CrossOver also bundles a REAL, standalone DXMT build — distinct from GPTK's own D3DMetal bridge (which
# lives in lib/wine and also ships a winemetal.dll under the same name, but always alongside d3d12.dll;
# real DXMT never covers d3d12 — see GraphicsBackend.dllOverrides / RuntimeManager.isRealDXMTModuleDir).
# Install it as its own separate runtime, in the exact top-level layout Silo's standardDXMTLibDir expects
# (x86_64-windows directly at the root — NOT nested under lib/wine/, which is only where DXMT lands when
# overlaid onto an EXISTING wine runtime, e.g. a variant clone).
DXMT_SRC="$SRC/lib/dxmt"
if [ -d "$DXMT_SRC/x86_64-windows" ]; then
  DXMT_NAME="dxmt-crossover-$VER"
  DXMT_DEST="$HOME/Library/Application Support/Silo/Runtimes/$DXMT_NAME"
  echo ""
  echo "==> Found CrossOver's bundled DXMT — installing to: $DXMT_DEST"
  rm -rf "$DXMT_DEST"
  mkdir -p "$DXMT_DEST"
  for arch in x86_64-windows i386-windows x86_64-unix; do
    [ -d "$DXMT_SRC/$arch" ] && cp -R "$DXMT_SRC/$arch" "$DXMT_DEST/$arch"
  done
  echo "Installed CrossOver's DXMT '$DXMT_NAME':"
  echo "  $DXMT_DEST"
  echo "Open Silo → Wine Manager → DXMT tab → Set default."
else
  echo ""
  echo "(No lib/dxmt found in this CrossOver install — skipping DXMT extraction.)"
fi
