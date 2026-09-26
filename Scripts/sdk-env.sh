# Source (don't exec) after versions.env: pins the build to the macOS SDK in MACOS_SDK_VERSION by exporting
# SDKROOT, which swift/clang/xcrun all honour — so Scripts/platform-version.sh reads that SDK too, and
# build-app.sh's recorded-SDK guard checks against it. Fails loudly if the pinned SDK isn't installed.
# Used by release.yml; local builds keep using whatever SDK the selected developer dir provides.
# (From upstream's sdk-env.sh, 2026-09-26.)
_sdk="$(xcrun --sdk "macosx${MACOS_SDK_VERSION:?versions.env not sourced}" --show-sdk-path 2>/dev/null || true)"
if [ -z "$_sdk" ]; then
  echo "ERROR: macOS ${MACOS_SDK_VERSION} SDK not found (developer dir: $(xcode-select -p 2>/dev/null || echo '?'))." >&2
  echo "       Install Xcode ${XCODE_VERSION:-?}, then: sudo xcode-select -s /Applications/Xcode.app" >&2
  return 1 2>/dev/null || exit 1
fi
export SDKROOT="$_sdk"
unset _sdk
echo "==> SDK: $SDKROOT"
