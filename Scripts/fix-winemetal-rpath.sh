#!/usr/bin/env bash
# Make DXMT's winemetal.so match CrossOver's own: install name @rpath/winemetal.so, references
# @rpath/winemac.so + @rpath/ntdll.so and an rpath of @loader_path/ (it is overlaid next to them, in
# <runtime>/lib/wine/x86_64-unix). Shared by Scripts/build-dxmt.sh and .github/workflows/build-dxmt.yml.
#
# Why: winemetal.so records the install names of the winemac.so/ntdll.so it was linked against (@rpath/… in
# Silo's Wine, like CrossOver's), which need an rpath here; an absolute build-machine path is rewritten. It also refuses a winemetal.so that still references anything outside the system and Wine.
#
# Usage: Scripts/fix-winemetal-rpath.sh <winemetal.so>
set -euo pipefail
SO="${1:?usage: fix-winemetal-rpath.sh <winemetal.so>}"
args=()
# Its OWN install name: DXMT's link gives it winemac.so's (measured on the CI build: LC_ID_DYLIB =
# /Users/runner/work/_temp/wine-install/lib/wine/x86_64-unix/winemac.so). CrossOver's is @rpath/winemetal.so.
id="$(otool -D "$SO" | sed -n 2p)"
[ "$id" = "@rpath/winemetal.so" ] || args+=(-id "@rpath/winemetal.so")
for ref in $(otool -L "$SO" | awk 'NR>1 {print $1}' | grep -vxF "$id"); do
  case "$ref" in
    @rpath/*) ;;
    */winemac.so|*/ntdll.so) args+=(-change "$ref" "@rpath/$(basename "$ref")") ;;
  esac
done
# (captured first: with pipefail, `grep -q` closing the pipe early would make the test fail spuriously)
rpaths="$(otool -l "$SO" | grep -A2 LC_RPATH || true)"
case "$rpaths" in *"path @loader_path/ "*) ;; *) args+=(-add_rpath "@loader_path/") ;; esac
if [ ${#args[@]} -gt 0 ]; then
  install_name_tool "${args[@]}" "$SO" 2>/dev/null
  codesign --force --sign "${SILO_SIGN_IDENTITY:--}" "$SO" 2>/dev/null
fi
bad="$(otool -L "$SO" | awk 'NR>1 {print $1}' | grep -vE '^(@rpath/(winemac|ntdll|winemetal)\.so|/usr/lib/|/System/)' || true)"
[ -z "$bad" ] || { echo "ERROR: $(basename "$SO") references outside the system and Wine: $bad"; exit 1; }
echo "    winemetal.so: id @rpath/winemetal.so, @rpath/winemac.so + @rpath/ntdll.so, rpath @loader_path/ (as CrossOver's)"
