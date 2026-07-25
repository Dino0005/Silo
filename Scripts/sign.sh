#!/usr/bin/env bash
# Sign the app and strip the quarantine bit for local runs.
# Default: ad-hoc ("-"), matching upstream — no Developer ID needed, but Gatekeeper blocks it on
# OTHER Macs and it can't be notarized.
#
# To sign with your own Apple Developer ID instead (needed to distribute to others / notarize):
#   export SILO_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)"
#   ./Scripts/build-app.sh
# Find your identity string with: security find-identity -v -p codesigning
set -euo pipefail
cd "$(dirname "$0")/.."

APP="${1:-dist/Silo.app}"
IDENTITY="${SILO_SIGN_IDENTITY:--}"

# --options runtime (hardened runtime) is REQUIRED by Apple for notarization and is harmless with a
# real Developer ID. It's skipped for ad-hoc ("-") signing: codesign rejects --options runtime with
# the "-" identity on some toolchains, and ad-hoc builds are never notarized anyway.
RUNTIME_FLAG=()
if [ "$IDENTITY" != "-" ]; then
    RUNTIME_FLAG=(--options runtime)
fi

codesign --force --deep ${RUNTIME_FLAG+"${RUNTIME_FLAG[@]}"} --sign "$IDENTITY" \
    --entitlements Resources/silo.entitlements \
    "$APP"
xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true
codesign --verify --verbose "$APP"
if [ "$IDENTITY" = "-" ]; then
    echo "==> Ad-hoc signed: $APP"
else
    echo "==> Signed with '$IDENTITY' (hardened runtime): $APP"
    echo "    Next: notarize with 'xcrun notarytool submit ... --wait' then 'xcrun stapler staple $APP'"
fi
