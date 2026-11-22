#!/usr/bin/env bash
# Build Microsoft's DirectX Shader Compiler tools (dxc, dxa, dxv + libdxcompiler) for Apple Silicon and pack
# them as dxc.tar.xz — the shader tools Silo downloads the first time the Spider-Man 2 fix needs them
# (`SpiderMan2Fix`). They rebuild the fix's four shaders on the user's Mac from their own Spider-Man2.exe, so
# no game data ever ships with Silo.
#
# Pinned to DXC_COMMIT (versions.env): the commit macprotips' SpiderMan2Fix verified, so the rebuilt shaders are
# byte-identical to the ones they tested in the game (Silo checks every result's hash). Shared by
# .github/workflows/build-dxc.yml so the two can't drift. DXC is open source (University of Illinois/NCSA);
# its LICENSE.TXT and ThirdPartyNotices.txt ship inside the archive.
#
# Needs cmake (Scripts/host-tools.sh) and Xcode or the Command Line Tools. ~10 min on an M3 Pro.
# Usage: Scripts/build-dxc.sh [work dir]      → <repo>/dist/dxc.tar.xz (+ .sha256)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
. "$ROOT/versions.env"
WORK="${1:-$ROOT/.dxc-build}"
OUT="$ROOT/dist"
STAGE="$WORK/stage/dxc"

mkdir -p "$WORK"
if [ ! -d "$WORK/src/.git" ]; then
  git init -q "$WORK/src"
  git -C "$WORK/src" remote add origin https://github.com/microsoft/DirectXShaderCompiler.git
fi
echo "==> Fetch DXC $DXC_COMMIT"
git -C "$WORK/src" fetch -q --depth 1 origin "$DXC_COMMIT"
git -C "$WORK/src" checkout -q FETCH_HEAD
git -C "$WORK/src" submodule update -q --init --depth 1 --recursive

echo "==> Configure + build (arm64, release)"
# Unix Makefiles, not Ninja: nothing to install beyond cmake. The flags are macprotips' build-dxc.sh.
cmake -S "$WORK/src" -B "$WORK/build" -G "Unix Makefiles" -C "$WORK/src/cmake/caches/PredefinedParams.cmake" \
  -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=13.0 \
  -DSPIRV_WERROR=OFF -DCLANG_FORMAT_EXE=OFF -DHLSL_INCLUDE_TESTS=OFF -DLLVM_INCLUDE_TESTS=OFF \
  -DCLANG_INCLUDE_TESTS=OFF -DENABLE_SPIRV_CODEGEN=OFF -DSPIRV_BUILD_TESTS=OFF >/dev/null
make -C "$WORK/build" -j"$(sysctl -n hw.ncpu)" dxc dxa dxv

echo "==> Package"
rm -rf "$WORK/stage"
mkdir -p "$STAGE/bin" "$STAGE/lib" "$STAGE/licenses"
for tool in dxc dxa dxv; do
  # The build's bin/dxc may be a symlink to a versioned file: copy what it points at, under the plain name.
  cp "$(cd "$WORK/build/bin" && pwd -P)/$(readlink "$WORK/build/bin/$tool" || echo "$tool")" "$STAGE/bin/$tool"
done
cp "$WORK/build/lib/libdxcompiler.dylib" "$STAGE/lib/"
# The tools find the library through @executable_path/../lib — the layout above keeps that true.
strip -x "$STAGE"/bin/* "$STAGE"/lib/*.dylib
# arm64 code must carry a signature to run; strip may have invalidated the linker's one, so sign again (ad hoc).
codesign --force --sign - "$STAGE"/lib/libdxcompiler.dylib "$STAGE"/bin/*
cp "$WORK/src/LICENSE.TXT" "$STAGE/licenses/DXC-LICENSE.txt"
cp "$WORK/src/ThirdPartyNotices.txt" "$STAGE/licenses/DXC-ThirdPartyNotices.txt"
echo "$DXC_COMMIT" > "$STAGE/COMMIT"
"$STAGE/bin/dxc" --version

mkdir -p "$OUT"
( cd "$WORK/stage" && tar -cJf "$OUT/dxc.tar.xz" dxc )
( cd "$OUT" && shasum -a 256 dxc.tar.xz > dxc.tar.xz.sha256 )
ls -la "$OUT/dxc.tar.xz"
echo "==> Built $OUT/dxc.tar.xz"
