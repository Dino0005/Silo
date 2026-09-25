#!/usr/bin/env bash
# Assemble dist/Silo.app from the SwiftPM release build (no Xcode required).
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="Silo"
BIN_NAME="silo"
CONFIG="release"
APP="dist/$APP_NAME.app"

# Versions come from versions.env (the single source of truth). Regenerate the committed Swift mirror so
# the assembled app always matches, then read the marketing version for the Info.plist.
./Scripts/gen-versions.sh
set -a; . ./versions.env; set +a
VERSION="$SILO_VERSION"
BUILD=$(date +%Y%m%d%H%M)

# CI/distribution builds compile wine logging OFF (SILO_QUIET_WINE → WINEDEBUG=-all); LOCAL builds stay
# verbose (+loaddll) so launch logs carry the diagnostics we (and the GraphicsFallback guardrail) need
# while developing. GitHub Actions sets $CI, so the shipped app is automatically silent.
QUIET=""
if [ -n "${CI:-}" ]; then QUIET="-Xswiftc -DSILO_QUIET_WINE"; echo "==> CI build: wine logging OFF"; fi

# The app must declare the SDK it was built against, or macOS draws it in the compatibility appearance.
. ./Scripts/platform-version.sh

echo "==> swift build -c $CONFIG $QUIET (deployment $MIN_OS, SDK $SDK_VERSION)"
swift build -c "$CONFIG" $QUIET "${PLATFORM_VERSION[@]}"
BIN_PATH=".build/$CONFIG/$BIN_NAME"

# Guard, because the flags above are the whole reason the window looks like a macOS app: a toolchain that
# stopped honouring them would ship the compatibility appearance again, and nothing in a diff would say so.
RECORDED_SDK=$(vtool -show-build-version "$BIN_PATH" | awk '/^ *sdk /{print $2; exit}')
if [ "$RECORDED_SDK" != "$SDK_VERSION" ]; then
    echo "!! the binary records SDK $RECORDED_SDK, not $SDK_VERSION — macOS would draw Silo in the" >&2
    echo "   compatibility appearance (see Scripts/platform-version.sh)" >&2
    exit 1
fi

echo "==> assembling $APP (v$VERSION build $BUILD)"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN_PATH" "$APP/Contents/MacOS/$APP_NAME"

sed -e "s/\${VERSION}/$VERSION/g" -e "s/\${BUILD}/$BUILD/g" \
    Resources/Info.plist.template > "$APP/Contents/Info.plist"

printf 'APPL????' > "$APP/Contents/PkgInfo"

# SwiftPM resource bundles (SiloKit has none today; copy any that appear later).
shopt -s nullglob
for bundle in ".build/$CONFIG"/*.bundle; do
    cp -R "$bundle" "$APP/Contents/Resources/"
done
shopt -u nullglob

[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/"

# The alt-loader host (Scripts/altloader-host). Not a SwiftPM target: it must be linked with fixed
# segment addresses and for the RUNTIME's architecture (x86_64 today), which SwiftPM can't express —
# see the header of host.c and STATUS.md. GameHostBundle copies it into each per-game .app, where
# LaunchServices starts it and it adopts the Wine process handed over on CX_ALT_LOADER_SOCKET.
#
# **A missing or broken host FAILS the build** (user's decision, 2026-09-25). It used to be best-effort
# with a WARNING, which meant a release could ship without it and the game icons would silently fall
# back to "wine" — a feature that switches itself off without a word is worse than a build that stops.
# The old binary is removed first: otherwise a failed compile would leave the previous build's `host`
# in place and the check below would package that stale copy.
echo "==> Build alt-loader host"
HOST_OUT=Scripts/altloader-host/host
rm -f "$HOST_OUT"
if ! Scripts/altloader-host/build.sh || [ ! -f "$HOST_OUT" ]; then
    echo "ERROR: the alt-loader host did not build (Scripts/altloader-host/build.sh)." >&2
    exit 1
fi
# Sanity: an x86_64 executable that carries the reserved segment Wine needs (see host.c). A host built
# for the wrong arch, or without WINE_RESERVE, would build fine and then fail at every game launch.
if ! lipo -archs "$HOST_OUT" 2>/dev/null | grep -qw x86_64; then
    echo "ERROR: the alt-loader host is not x86_64 ($(lipo -archs "$HOST_OUT" 2>/dev/null))." >&2
    exit 1
fi
if ! otool -l "$HOST_OUT" | grep -q "segname WINE_RESERVE"; then
    echo "ERROR: the alt-loader host lacks the WINE_RESERVE segment — check its link flags." >&2
    exit 1
fi
mkdir -p "$APP/Contents/Helpers"
cp "$HOST_OUT" "$APP/Contents/Helpers/SiloWineHost"
chmod 755 "$APP/Contents/Helpers/SiloWineHost"

# SiloKit's own resources, flat in Contents/Resources so Bundle.main finds them — the standard macOS app
# layout. The nested SwiftPM bundle copied above is NOT enough on its own: SwiftPM's generated
# `Bundle.module` looks beside the .app and then in the build directory of whoever compiled, so a shipped
# app resolved neither and trapped on first use. See LibraryGridView.steamIconURL.
shopt -s nullglob
for resource in Sources/SiloKit/Resources/*; do
    cp -R "$resource" "$APP/Contents/Resources/"
done
shopt -u nullglob

# Localizations (EN source + IT translation): plain Localizable.strings per language, resolved
# automatically by SwiftUI's default LocalizedStringKey lookup (Bundle.main, table "Localizable") —
# no changes needed at Text()/Button()/etc. call sites in Sources/.
for lproj in Resources/*.lproj; do
    [ -d "$lproj" ] && cp -R "$lproj" "$APP/Contents/Resources/"
done

./Scripts/sign.sh "$APP"
echo "==> Built $APP"
