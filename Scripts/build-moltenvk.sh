#!/usr/bin/env bash
# Build MoltenVK (Wine's Vulkan → Metal driver, dlopen'd by winevulkan) from the CrossOver FOSS tarball's own
# `sources/moltenvk` (1.2.10 — the version CrossOver 26.3.0 ships in lib64) instead of x86_64 Homebrew.
#
# MoltenVK builds only with Xcode's xcodebuild (the runtime build, not Silo's app — that stays SwiftPM-only;
# build-dxmt.sh needs full Xcode too). Its dependencies aren't in the tarball except SPIRV-Cross: the rest
# (cereal, Vulkan-Headers, glslang + its SPIRV-Tools/Headers, Vulkan-Tools, Volk) are cloned by MoltenVK's own
# `fetchDependencies` at the exact commits the tarball pins in `ExternalRevisions/`. SPIRV-Cross is the
# tarball's copy (--spirv-cross-root), so CrossOver's version of it is what gets compiled.
#
# Output, like CrossOver's: an x86_64-only `@rpath/libMoltenVK.dylib` depending on system frameworks only,
# installed into build-deps.sh's prefix (.wine-build/deps/prefix/lib) for Wine's configure and the bundler.
#
# Usage: run by Scripts/build-deps.sh at its end (it needs that prefix); standalone to rebuild MoltenVK alone.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="${SILO_CX_SOURCES:-$ROOT/.wine-build/src/sources}/moltenvk"
WORK="$ROOT/.wine-build/deps/moltenvk"
PREFIX="$ROOT/.wine-build/deps/prefix"
[ -f "$SRC/fetchDependencies" ] || { echo "ERROR: MoltenVK sources not found at $SRC"; exit 1; }
[ -d "$PREFIX/lib" ] || { echo "ERROR: run Scripts/build-deps.sh first ($PREFIX missing)"; exit 1; }
xcodebuild -version >/dev/null 2>&1 || { echo "ERROR: MoltenVK needs full Xcode (xcodebuild)"; exit 1; }
# build-deps.sh's autotools environment must not reach xcodebuild (it would try to spawn "$CC" as one binary).
unset CC CXX CFLAGS CXXFLAGS CPPFLAGS LDFLAGS PKG_CONFIG PKG_CONFIG_LIBDIR PKG_CONFIG_PATH

ver="$(grep -hE '#define MVK_VERSION_(MAJOR|MINOR|PATCH)' "$SRC"/MoltenVK/MoltenVK/API/*.h | awk '{print $3}' | paste -sd. -)"
echo "==> MoltenVK $ver"
rm -rf "$WORK" && mkdir -p "$WORK"
cp -Rp "$SRC" "$WORK/src"
# fetchDependencies deletes External/SPIRV-Cross before linking --spirv-cross-root there — keep the copy outside.
mv "$WORK/src/External/SPIRV-Cross" "$WORK/SPIRV-Cross"
# Build-setting overrides for every xcodebuild the two steps run (highest precedence, project files untouched):
# current Xcode refuses the projects' 10.15 deployment target (supported: 12.0+), and only the x86_64 slice ships.
cat > "$WORK/override.xcconfig" <<'EOF'
MACOSX_DEPLOYMENT_TARGET = 12.0
ARCHS = x86_64
ONLY_ACTIVE_ARCH = NO
EOF
export XCODE_XCCONFIG_FILE="$WORK/override.xcconfig"

( cd "$WORK/src" && ./fetchDependencies --macos --spirv-cross-root "$WORK/SPIRV-Cross" > "$WORK/fetch.log" 2>&1 ) \
  || { echo "ERROR: fetchDependencies failed — see $WORK/fetch.log"; exit 1; }
( cd "$WORK/src" && make macos > "$WORK/make.log" 2>&1 ) \
  || { echo "ERROR: MoltenVK build failed — see $WORK/make.log"; exit 1; }

built="$WORK/src/Package/Release/MoltenVK/dynamic/dylib/macOS/libMoltenVK.dylib"
[ -f "$built" ] || built="$(find "$WORK/src/Package" -name libMoltenVK.dylib -path '*macOS*' | head -1)"
[ -f "$built" ] || { echo "ERROR: libMoltenVK.dylib not found under $WORK/src/Package"; exit 1; }
out="$PREFIX/lib/libMoltenVK.dylib"
lipo "$built" -thin x86_64 -output "$out" 2>/dev/null || cp "$built" "$out"   # already thin → copy
install_name_tool -id "@rpath/libMoltenVK.dylib" "$out" 2>/dev/null
strip -x "$out" 2>/dev/null   # local symbols out, like CrossOver's (966 vs its 967 symbols)
codesign --force --sign "${SILO_SIGN_IDENTITY:--}" "$out" 2>/dev/null
[ "$(lipo -archs "$out")" = "x86_64" ] || { echo "ERROR: libMoltenVK.dylib is not x86_64-only"; exit 1; }
bad="$(otool -L "$out" | awk 'NR>1 {print $1}' | grep -vE '^(@rpath/libMoltenVK|/usr/lib/|/System/)' || true)"
[ -z "$bad" ] || { echo "ERROR: libMoltenVK.dylib references: $bad"; exit 1; }
echo "Built: $out"
