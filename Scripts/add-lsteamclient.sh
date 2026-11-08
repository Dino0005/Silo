#!/usr/bin/env bash
# Valve's Proton lsteamclient + steam.exe helper, built inside Silo's Wine (native-macOS-Steam bridge).
#
# lsteamclient is the bridge from a Windows game's steam_api to the macOS Steam client (steamclient.dylib);
# steam.exe (Proton's steam_helper) is the stand-in Steam process the game is started under. Wine patch 0003
# routes steamclient64.dll / steamclient.dll to lsteamclient (only with SILO_LSTEAMCLIENT=1), patch 0008 lets
# makedep build its C++ unix half. Sources: Proton at PROTON_COMMIT (versions.env), verified by digest, plus
# Silo's own patches in Scripts/lsteamclient-patches — each carries its rationale. Nothing from NotProton.
# Licences: steam_helper is BSD-3 (Valve); lsteamclient/ is under the Steamworks SDK licence (its LICENSE,
# installed next to the binaries); cxx.h is LGPL-2.1 (Wine).
#
# Usage:
#   Scripts/add-lsteamclient.sh source  <wine_src> [cache_dir]
#       before configure: puts dlls/lsteamclient + programs/steam_helper into the Wine source and registers
#       both in its configure script.
#   Scripts/add-lsteamclient.sh install <wine_src> <install_dir>
#       after `make install`: moves steam.exe out of lib/wine (else wineboot would put a placeholder
#       C:\windows\system32\steam.exe into every new prefix) to share/silo/native-steam/, with the licences.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
set -a; . "$ROOT/versions.env"; set +a

# The digest of versions.env: sha256 over the "shasum -a 256" lines of every file, sorted by path.
tree_digest() {
  ( cd "$1" && find lsteamclient steam_helper -type f | LC_ALL=C sort | while IFS= read -r f; do
      shasum -a 256 "$f"; done | shasum -a 256 | cut -d' ' -f1 )
}

cmd_source() {
  local wine_src cache base tarball
  wine_src="$(cd "$1" && pwd)"
  cache="${2:-$ROOT/.wine-build}/proton-$PROTON_COMMIT"
  base="$cache/src"
  tarball="$cache/proton.tar.gz"

  if [ ! -d "$base" ]; then
    mkdir -p "$cache"
    if [ ! -f "$tarball" ]; then
      echo "==> Fetch Proton $PROTON_COMMIT"
      curl -fsSL -o "$tarball.part" "https://codeload.github.com/ValveSoftware/Proton/tar.gz/$PROTON_COMMIT"
      mv "$tarball.part" "$tarball"
    fi
    rm -rf "$base.part" && mkdir -p "$base.part"
    tar -xzf "$tarball" -C "$base.part" --strip-components=1 '*/lsteamclient/' '*/steam_helper/' '*/LICENSE.proton'
    mv "$base.part" "$base"
  fi

  local got; got="$(tree_digest "$base")"
  if [ "$got" != "$PROTON_LSC_DIGEST" ]; then
    echo "ERROR: Proton sources at $base don't match PROTON_LSC_DIGEST" >&2
    echo "       expected $PROTON_LSC_DIGEST" >&2
    echo "       got      $got   (delete $cache to refetch)" >&2
    exit 1
  fi
  echo "==> Proton $PROTON_COMMIT verified"

  # Patch a scratch copy (the patches use Proton's own paths), then move it into the Wine tree.
  local stage="$cache/stage"
  rm -rf "$stage" && mkdir -p "$stage"
  cp -R "$base/lsteamclient" "$base/steam_helper" "$stage/"
  cp "$base/LICENSE.proton" "$stage/steam_helper/LICENSE.proton"
  for p in "$ROOT"/Scripts/lsteamclient-patches/*.patch; do
    [ -e "$p" ] || break
    echo "==> Apply lsteamclient $(basename "$p")"
    ( cd "$stage" && patch -p1 --forward --quiet < "$p" ) \
      || { echo "ERROR: $(basename "$p") did not apply to Proton $PROTON_COMMIT — rebase it" >&2; exit 1; }
  done
  rm -rf "$wine_src/dlls/lsteamclient" "$wine_src/programs/steam_helper"
  mv "$stage/lsteamclient" "$wine_src/dlls/lsteamclient"
  mv "$stage/steam_helper" "$wine_src/programs/steam_helper"

  # Register both modules: configure is what writes the top Makefile's SUBDIRS (config.status rewrites any
  # hand edit). An unset enable_* variable means "build it", like every stock module.
  python3 -I - "$wine_src/configure" <<'EOF'
import sys
path = sys.argv[1]
text = open(path).read()
for anchor, line in (
    ("wine_fn_config_makefile dlls/winebus.sys enable_winebus_sys\n",
     "wine_fn_config_makefile dlls/lsteamclient enable_lsteamclient\n"),
    ("wine_fn_config_makefile programs/start enable_start\n",
     "wine_fn_config_makefile programs/steam_helper enable_steam_helper\n"),
):
    if line in text:
        continue
    if anchor not in text:
        sys.exit("ERROR: configure has no line %r to register %r after" % (anchor.strip(), line.strip()))
    text = text.replace(anchor, anchor + line, 1)
open(path, "w").write(text)
EOF
  echo "==> lsteamclient + steam_helper registered in $wine_src/configure"
}

cmd_install() {
  local wine_src install out
  wine_src="$(cd "$1" && pwd)"
  install="$(cd "$2" && pwd)"
  out="$install/share/silo/native-steam"
  mkdir -p "$out"
  for f in lib/wine/x86_64-windows/lsteamclient.dll lib/wine/i386-windows/lsteamclient.dll \
           lib/wine/x86_64-unix/lsteamclient.so lib/wine/x86_64-windows/steam.exe; do
    [ -f "$install/$f" ] || { echo "ERROR: $f missing from $install — was configure run after 'source'?" >&2; exit 1; }
  done
  mv "$install/lib/wine/x86_64-windows/steam.exe" "$out/steam.exe"
  rm -f "$install/lib/wine/i386-windows/steam.exe"   # the bridge only uses the 64-bit helper
  cp "$wine_src/dlls/lsteamclient/LICENSE" "$out/LICENSE.lsteamclient"
  cp "$wine_src/programs/steam_helper/LICENSE.proton" "$out/LICENSE.steam_helper"
  echo "==> native-steam bridge: lsteamclient in lib/wine, steam.exe in share/silo/native-steam"
}

case "${1:-}" in
  source)  [ $# -ge 2 ] || { echo "usage: $0 source <wine_src> [cache_dir]" >&2; exit 2; }; cmd_source "$2" "${3:-}" ;;
  install) [ $# -eq 3 ] || { echo "usage: $0 install <wine_src> <install_dir>" >&2; exit 2; }; cmd_install "$2" "$3" ;;
  *) echo "usage: $0 source|install ..." >&2; exit 2 ;;
esac
