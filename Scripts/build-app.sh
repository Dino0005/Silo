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

# App icon. The source is Resources/AppIcon.icon (Icon Composer, Liquid Glass): actool compiles it into
# Assets.car — found through CFBundleIconName, with the light/dark/clear/tinted appearances — plus an
# AppIcon.icns for older systems. actool ships only with full Xcode (the release runner has it), so a
# Command Line Tools-only machine falls back to the committed Resources/AppIcon.icns, which
# Scripts/make-icon.sh regenerates from the same .icon. When actool IS present and fails, the build
# stops: falling back silently would ship the flat icon without anyone noticing.
if [ -d Resources/AppIcon.icon ] && xcrun --find actool >/dev/null 2>&1; then
    echo "==> Compile app icon (actool)"
    ICON_PLIST=$(mktemp)
    # Absolute paths: actool hands the .icon to a long-lived helper that resolves relative paths against
    # ITS working directory (measured: the directory of a previous actool run), not this script's.
    if ! xcrun actool "$PWD/Resources/AppIcon.icon" --compile "$PWD/$APP/Contents/Resources" --platform macosx \
            --minimum-deployment-target "$MIN_OS" --app-icon AppIcon \
            --output-partial-info-plist "$ICON_PLIST" >/dev/null \
            || [ ! -f "$APP/Contents/Resources/Assets.car" ]; then
        rm -f "$ICON_PLIST"
        echo "ERROR: actool could not compile Resources/AppIcon.icon." >&2
        exit 1
    fi
    rm -f "$ICON_PLIST"
else
    echo "==> actool unavailable: using the fallback Resources/AppIcon.icns"
    [ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/"
fi

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

# The game-app loader redirector (Scripts/game-loader, see GameAppLoader.swift): injected into the Wine processes of a
# game started from macOS Steam so that every process of the game runs from the game's .app. Required like the host:
# without it macOS-Steam launches fall back to the alt-loader host, which can't follow a game that relaunches itself.
echo "==> Build game-app loader redirector"
LOADER_OUT=Scripts/game-loader/silo-game-loader.dylib
rm -f "$LOADER_OUT"
if ! clang -Wall -O2 -dynamiclib -arch x86_64 -arch arm64 -o "$LOADER_OUT" Scripts/game-loader/silo-game-loader.c \
    || ! lipo -archs "$LOADER_OUT" 2>/dev/null | grep -qw x86_64; then
    echo "ERROR: the game-app loader redirector did not build (Scripts/game-loader)." >&2
    exit 1
fi
cp "$LOADER_OUT" "$APP/Contents/Helpers/silo-game-loader.dylib"

# Silo's library inside macOS Steam (Scripts/steam-hook): hands the front to a game app started from macOS Steam,
# and — opt-in, SILO_STEAM_COMPAT=1 — turns on Steam's compatibility layer in memory. Loaded only when Silo starts Steam.
echo "==> Build Steam hook"
HOOK_OUT=Scripts/steam-hook/silo-steam-hook.dylib
rm -f "$HOOK_OUT"
if ! clang -Wall -O2 -dynamiclib -arch arm64 -arch x86_64 -fobjc-arc -framework AppKit -o "$HOOK_OUT" \
    Scripts/steam-hook/compat.c Scripts/steam-hook/activation.m Scripts/steam-hook/shortcuts.m; then
    echo "ERROR: the Steam hook did not build (Scripts/steam-hook)." >&2
    exit 1
fi
cp "$HOOK_OUT" "$APP/Contents/Helpers/silo-steam-hook.dylib"

# Silo's fix for Steam's overlay (Scripts/overlay-fix, see SteamOverlayFix.swift): injected next to Steam's overlay into
# games started from macOS Steam, so the overlay draws in the game's pixel format instead of coloured noise.
echo "==> Build overlay fix"
OVERLAY_FIX_OUT=Scripts/overlay-fix/silo-overlay-fix.dylib
rm -f "$OVERLAY_FIX_OUT"
if ! clang -Wall -O2 -dynamiclib -arch x86_64 -arch arm64 -fobjc-arc -framework Foundation -framework Metal \
    -framework QuartzCore -o "$OVERLAY_FIX_OUT" Scripts/overlay-fix/overlay-fix.m; then
    echo "ERROR: the overlay fix did not build (Scripts/overlay-fix)." >&2
    exit 1
fi
cp "$OVERLAY_FIX_OUT" "$APP/Contents/Helpers/silo-overlay-fix.dylib"

# Silo's pipeline cache (Scripts/pipeline-cache, see PipelineCache.swift): MacGameFix's GPL-3.0 cache, injected into a
# game started from macOS Steam under GPTK when its switch is on. Manual retain/release (no -fobjc-arc), as upstream.
echo "==> Build pipeline cache"
PIPELINE_CACHE_OUT=Scripts/pipeline-cache/silo-pipeline-cache.dylib
rm -f "$PIPELINE_CACHE_OUT"
if ! clang++ -arch x86_64 -arch arm64 -std=c++17 -dynamiclib -mmacosx-version-min=14.0 -Wall -Wextra -Werror \
    -framework Foundation -framework Metal -install_name @rpath/silo-pipeline-cache.dylib -o "$PIPELINE_CACHE_OUT" \
    Scripts/pipeline-cache/silo_pipeline_cache.mm Scripts/pipeline-cache/pipeline_cache.mm; then
    echo "ERROR: the pipeline cache did not build (Scripts/pipeline-cache)." >&2
    exit 1
fi
cp "$PIPELINE_CACHE_OUT" "$APP/Contents/Helpers/silo-pipeline-cache.dylib"

# The "Steam (Silo)" launcher (Scripts/steam-launcher): copied by `Silo --install-steam-launcher` into
# ~/Applications/Steam (Silo).app. Compiled, so macOS can list it in Privacy & Security (Steam inherits its grants).
echo "==> Build Steam launcher"
LAUNCHER_OUT=Scripts/steam-launcher/SiloSteamLauncher
rm -f "$LAUNCHER_OUT"
if ! clang -Wall -O2 -arch arm64 -arch x86_64 -framework ApplicationServices -framework CoreFoundation -o "$LAUNCHER_OUT" Scripts/steam-launcher/launcher.c; then
    echo "ERROR: the Steam launcher did not build (Scripts/steam-launcher)." >&2
    exit 1
fi
cp "$LAUNCHER_OUT" "$APP/Contents/Helpers/SiloSteamLauncher"

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
