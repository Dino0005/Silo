#!/usr/bin/env bash
# Regenerate the fallback Resources/AppIcon.icns from the icon source, Resources/AppIcon.icon.
#
# AppIcon.icon (Icon Composer, Liquid Glass) is the source of truth: build-app.sh compiles it with actool
# into Assets.car, which macOS picks through CFBundleIconName. This .icns is only used when actool is
# unavailable (a Command Line Tools-only machine), so it's committed and refreshed by hand after editing
# the .icon. Needs full Xcode, for Icon Composer's ictool.
set -euo pipefail
cd "$(dirname "$0")/.."

ICTOOL="$(xcode-select -p)/../Applications/Icon Composer.app/Contents/Executables/ictool"
if [ ! -x "$ICTOOL" ]; then
    echo "ERROR: ictool not found — this needs full Xcode (Icon Composer), not just the Command Line Tools." >&2
    exit 1
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# ictool renders the shape edge to edge; legacy macOS icons sit on the 824/1024 grid (the same inset
# actool gives its own .icns), so render at 824 and pad back out to 1024.
"$ICTOOL" Resources/AppIcon.icon --export-image --output-file "$TMP/shape.png" \
    --platform macOS --rendition Default --width 824 --height 824 --scale 1 >/dev/null
SRC="$TMP/icon-1024.png"
sips --padToHeightWidth 1024 1024 "$TMP/shape.png" --out "$SRC" >/dev/null

ICONSET="$TMP/AppIcon.iconset"
mkdir -p "$ICONSET"
gen() { sips -z "$2" "$2" "$SRC" --out "$ICONSET/$1" >/dev/null; }
gen icon_16x16.png 16
gen icon_16x16@2x.png 32
gen icon_32x32.png 32
gen icon_32x32@2x.png 64
gen icon_128x128.png 128
gen icon_128x128@2x.png 256
gen icon_256x256.png 256
gen icon_256x256@2x.png 512
gen icon_512x512.png 512
gen icon_512x512@2x.png 1024

iconutil -c icns "$ICONSET" -o Resources/AppIcon.icns
echo "wrote Resources/AppIcon.icns"
