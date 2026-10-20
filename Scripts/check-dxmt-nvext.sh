#!/usr/bin/env bash
# Check DXMT's NVIDIA extensions in a finished install and make sure Wine treats them as builtin.
#
# DXMT built with -Denable_nvapi=true -Denable_nvngx=true (win64 only — nvapi64 does not build for i386, and
# CrossOver ships the pair for x86_64 alone) installs nvapi64.dll + nvngx.dll in x86_64-windows. Silo's DXMT
# launches load them as builtin (`nvapi64,nvngx=b`, see LaunchOrchestrator.makePlan): DLSS calls → MetalFX's
# temporal scaler. Wine only finds a builtin carrying the "Wine builtin DLL" marker at offset 0x40, which
# DXMT's meson `winebuild --builtin` step writes into the build tree — but an install that ran before that
# step copied the unmarked file (seen on a manual rebuild, 2026-10-20): Wine then fell back to whatever sat in
# the bottle's system32 and DLSS stayed "not supported". So: require both files, and mark any that lack it.
#
# Usage: check-dxmt-nvext.sh <dxmt install dir> <winebuild binary>
set -euo pipefail
INSTALL="${1:?usage: check-dxmt-nvext.sh <dxmt install dir> <winebuild>}"
WINEBUILD="${2:?usage: check-dxmt-nvext.sh <dxmt install dir> <winebuild>}"

is_builtin() { [ "$(dd if="$1" bs=1 skip=64 count=16 2>/dev/null)" = "Wine builtin DLL" ]; }

for f in "$INSTALL/x86_64-windows/nvapi64.dll" "$INSTALL/x86_64-windows/nvngx.dll"; do
  [ -e "$f" ] || { echo "ERROR: DXMT's NVIDIA extensions missing: $f (was -Denable_nvapi/-Denable_nvngx passed?)"; exit 1; }
  if ! is_builtin "$f"; then
    echo "    $(basename "$f"): no Wine builtin marker — marking it"
    "$WINEBUILD" --builtin "$f"
  fi
  is_builtin "$f" || { echo "ERROR: $f still lacks the Wine builtin marker"; exit 1; }
done
echo "    NVIDIA extensions present and builtin: x86_64-windows/nvapi64.dll + nvngx.dll"
