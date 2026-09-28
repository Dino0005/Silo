#!/usr/bin/env bash
# Build the GStreamer media add-on for CrossOver's Wine: gst-libav (FFmpeg decoders) + matroska, compiled
# for the EXACT GStreamer CrossOver ships (1.24.4 / glib 2.78, from the CrossOver FOSS tarball).
#
# Why: CrossOver 26.3 ships 17 GStreamer plugins and no FFmpeg, so there is no VC-1 / WMV3 / WMA decoder.
# Devil May Cry 5 (and RE2/RE3, same engine) crash when a VC-1-in-ASF movie starts — the skill previews in
# the customisation menu, "History of DMC" in the main menu. H.264 already works (applemedia/VideoToolbox).
# The decoders live in gst-libav; a newer build (say Homebrew's 1.28) is useless here, because the 1.24
# core refuses any plugin built for a newer minor (gstreamer/gst/gstplugin.c: `minor > GST_VERSION_MINOR`).
# So: build 1.24.4 from the same tarball, then gst-libav + matroska against it and FFmpeg FFMPEG_VERSION
# (the FFmpeg that GStreamer's own FFmpeg.wrap pins for 1.24).
#
# Output: dist/gst-libav-<gst>/lib64/{gstreamer-1.0/libgstlibav.dylib, gstreamer-1.0/libgstmatroska.dylib,
# libav*.dylib, libsw*.dylib} — every install name and reference @rpath, so the files drop into a
# CrossOver-layout runtime's lib64 and resolve its 1.24.4 GStreamer/glib (identical compatibility versions)
# with no Homebrew and no DYLD_* variable. Add them to a runtime with Scripts/add-gst-libav.sh.
#
# FFmpeg is built LGPL-only (no --enable-gpl): VC-1, WMV and WMA are LGPL decoders. Encoders, muxers,
# devices and networking are off — decoding is all Wine asks of it.
#
# Tools: meson + ninja in a Python venv (native), nasm from source (native); everything they produce is
# x86_64. bison >= 2.4 comes from the x86_64 Homebrew the Wine build already requires.
#
# Usage: Scripts/build-gst-libav.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
set -a; . "$ROOT/versions.env"; set +a
WORK="$ROOT/.wine-build/gst"
SRC="$ROOT/.wine-build/src/sources"
PREFIX="$WORK/prefix"
JOBS="$(sysctl -n hw.ncpu)"
BISON="$(arch -x86_64 /usr/local/bin/brew --prefix bison 2>/dev/null)/bin"
[ -x "$BISON/bison" ] || { echo "ERROR: x86_64 Homebrew bison not found (Scripts/bootstrap-x86-brew.sh bison)"; exit 1; }

mkdir -p "$WORK" && cd "$WORK"

echo "==> CrossOver source $CROSSOVER_VERSION"
if [ ! -d "$SRC/gstreamer" ]; then
  mkdir -p "$ROOT/.wine-build" && cd "$ROOT/.wine-build"
  curl -fL "https://media.codeweavers.com/pub/crossover/source/crossover-sources-${CROSSOVER_VERSION}.tar.gz" -o sources.tar.gz
  rm -rf src && mkdir src && tar -xzf sources.tar.gz -C src
  cd "$WORK"
fi
GST_VERSION="$(sed -n "s/^ *version *: *'\([0-9.]*\)'.*/\1/p" "$SRC/gstreamer/meson.build" | head -1)"
echo "    GStreamer $GST_VERSION"
# The tarball ships glib's gvdb git submodule as an EMPTY directory; meson then refuses the subproject
# ("exists but has no meson.build") instead of using the gvdb.wrap next to it.
gvdb="$SRC/glib/subprojects/gvdb"
if [ -d "$gvdb" ] && [ -z "$(ls -A "$gvdb")" ]; then rmdir "$gvdb"; fi

echo "==> Tools: meson/ninja (venv), nasm $NASM_VERSION"
if [ ! -x "$WORK/venv/bin/meson" ]; then
  python3 -m venv "$WORK/venv"
  # setuptools: glib 2.78's gdbus-codegen still imports distutils, gone from Python >= 3.12.
  "$WORK/venv/bin/pip" install -q meson ninja setuptools
fi
if [ ! -x "$WORK/tools/bin/nasm" ]; then
  curl -fsSL "https://www.nasm.us/pub/nasm/releasebuilds/${NASM_VERSION}/nasm-${NASM_VERSION}.tar.xz" -o nasm.tar.xz
  rm -rf nasm && mkdir nasm && tar -xf nasm.tar.xz -C nasm --strip-components=1
  ( cd nasm && ./configure -q --prefix="$WORK/tools" >/dev/null && make -j"$JOBS" -s >/dev/null && make -s install >/dev/null )
fi
export PATH="$BISON:$WORK/venv/bin:$WORK/tools/bin:$PATH"
# Only our own prefix is visible to pkg-config — nothing is picked up from Homebrew by accident.
export PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig" PKG_CONFIG_PATH=
rm -rf "$PREFIX" && mkdir -p "$PREFIX"

echo "==> FFmpeg $FFMPEG_VERSION (x86_64, LGPL, decoders only)"
curl -fsSL "https://ffmpeg.org/releases/ffmpeg-${FFMPEG_VERSION}.tar.xz" -o ffmpeg.tar.xz
rm -rf ffmpeg && mkdir ffmpeg && tar -xf ffmpeg.tar.xz -C ffmpeg --strip-components=1
( cd ffmpeg && ./configure --prefix="$PREFIX" --enable-shared --disable-static --disable-programs --disable-doc \
    --enable-cross-compile --arch=x86_64 --target-os=darwin --cc="clang -arch x86_64" --cxx="clang++ -arch x86_64" \
    --x86asmexe="$WORK/tools/bin/nasm" --disable-autodetect --disable-network --disable-encoders --disable-muxers \
    --disable-devices --disable-indevs --disable-outdevs --install-name-dir='@rpath' \
    --extra-cflags="-mmacosx-version-min=11.0" \
    --extra-ldflags="-mmacosx-version-min=11.0 -Wl,-headerpad_max_install_names" > "$WORK/ffmpeg-configure.log" \
  && make -j"$JOBS" > "$WORK/ffmpeg-make.log" 2>&1 && make install > /dev/null ) \
  || { echo "ERROR: FFmpeg build failed — see $WORK/ffmpeg-*.log"; exit 1; }
grep -q "^License: LGPL" "$WORK/ffmpeg-configure.log" || { echo "ERROR: FFmpeg is not LGPL-only"; exit 1; }

# A meson cross file: host = x86_64 darwin, so meson knows what it's generating; the test binaries it
# runs during configure are x86_64 and simply run under Rosetta (needs_exe_wrapper = false).
cat > "$WORK/x86_64-darwin.ini" <<'EOF'
[binaries]
c = ['clang', '-arch', 'x86_64']
cpp = ['clang++', '-arch', 'x86_64']
objc = ['clang', '-arch', 'x86_64']
objcpp = ['clang++', '-arch', 'x86_64']
ar = 'ar'
strip = 'strip'
pkg-config = '/usr/local/bin/pkgconf'

[built-in options]
c_args = ['-mmacosx-version-min=11.0']
cpp_args = ['-mmacosx-version-min=11.0']
objc_args = ['-mmacosx-version-min=11.0']
c_link_args = ['-mmacosx-version-min=11.0', '-Wl,-headerpad_max_install_names']
cpp_link_args = ['-mmacosx-version-min=11.0', '-Wl,-headerpad_max_install_names']
objc_link_args = ['-mmacosx-version-min=11.0', '-Wl,-headerpad_max_install_names']

[properties]
needs_exe_wrapper = false

[host_machine]
system = 'darwin'
kernel = 'xnu'
cpu_family = 'x86_64'
cpu = 'x86_64'
endian = 'little'
EOF

meson_build() {   # <name> <source dir> [meson options...]
  local name="$1" src="$2"; shift 2
  echo "==> $name"
  rm -rf "$WORK/$name-build"
  meson setup "$WORK/$name-build" "$src" --cross-file "$WORK/x86_64-darwin.ini" --prefix="$PREFIX" \
      --libdir=lib --buildtype=release "$@" > "$WORK/$name-setup.log" 2>&1 \
    || { echo "ERROR: $name configure failed — see $WORK/$name-setup.log"; exit 1; }
  ninja -C "$WORK/$name-build" install > "$WORK/$name-build.log" 2>&1 \
    || { echo "ERROR: $name build failed — see $WORK/$name-build.log"; exit 1; }
}

# glib: build dependency only (the runtime keeps CrossOver's own) — the plugins must compile against 2.78.
meson_build glib "$SRC/glib" -Dnls=disabled -Dtests=false -Dman=false -Dgtk_doc=false -Ddtrace=false \
  -Dsysprof=disabled -Dselinux=disabled -Dxattr=false -Dlibmount=disabled

# GStreamer: likewise build dependencies, except the two plugins we ship. auto_features=disabled keeps
# every optional plugin off; the libraries (audio, video, tag, pbutils, riff, …) are always built.
GST="$SRC/gstreamer/subprojects"
common=(--wrap-mode=nodownload -Dauto_features=disabled -Ddoc=disabled -Dtests=disabled)
meson_build gstreamer "$GST/gstreamer" "${common[@]}" -Dnls=disabled -Dexamples=disabled -Dtools=enabled \
  -Dintrospection=disabled -Dptp-helper=disabled
meson_build gst-plugins-base "$GST/gst-plugins-base" "${common[@]}" -Dnls=disabled -Dexamples=disabled \
  -Dtools=disabled -Dintrospection=disabled
meson_build gst-plugins-good "$GST/gst-plugins-good" "${common[@]}" -Dnls=disabled -Dexamples=disabled \
  -Dmatroska=enabled
meson_build gst-libav "$GST/gst-libav" "${common[@]}"

echo "==> Check: the decoders Wine needs are there"
export GST_PLUGIN_SYSTEM_PATH="$PREFIX/lib/gstreamer-1.0" GST_REGISTRY="$WORK/registry.bin"
rm -f "$GST_REGISTRY"
for element in avdec_vc1 avdec_wmv3 avdec_wmv2 avdec_wmav2 avdec_wmapro matroskademux; do
  "$PREFIX/bin/gst-inspect-1.0" --exists "$element" || { echo "ERROR: $element missing"; exit 1; }
done

echo "==> Package"
OUT="$ROOT/dist/gst-libav-$GST_VERSION"
rm -rf "$OUT" && mkdir -p "$OUT/lib64/gstreamer-1.0"
python3 - "$PREFIX" "$OUT/lib64" <<'PY'
import os, subprocess, sys
prefix, lib64 = sys.argv[1], sys.argv[2]
plugins = ["libgstlibav.dylib", "libgstmatroska.dylib"]

def run(*a):
    return subprocess.run(a, check=True, capture_output=True, text=True).stdout

def refs(path):
    return [l.strip().split(" (compat")[0] for l in run("otool", "-L", path).splitlines()[1:]]

def rpaths(path):
    lines, out = run("otool", "-l", path).splitlines(), []
    for i, l in enumerate(lines):
        if l.strip() == "cmd LC_RPATH":
            out.append(lines[i + 2].strip()[5:].split(" (offset")[0])
    return out

# FFmpeg closure: the @rpath/libav*|libsw* libraries the plugins need, transitively.
need, queue = set(), [os.path.join(prefix, "lib/gstreamer-1.0", p) for p in plugins]
while queue:
    for r in refs(queue.pop()):
        leaf = os.path.basename(r)
        if r.startswith("@rpath/") and leaf.startswith(("libav", "libsw", "libpostproc")) and leaf not in need:
            need.add(leaf)
            queue.append(os.path.join(prefix, "lib", leaf))

def install(src, dest, rpath):
    subprocess.run(["cp", "-L", src, dest], check=True)
    os.chmod(dest, 0o755)
    args = ["-id", "@rpath/" + os.path.basename(dest)]
    for r in refs(dest):
        if r.startswith(prefix + "/"):              # meson's absolute install names → @rpath
            args += ["-change", r, "@rpath/" + os.path.basename(r)]
    for rp in rpaths(dest):
        if rp != rpath:
            args += ["-delete_rpath", rp]
    if rpath not in rpaths(dest):
        args += ["-add_rpath", rpath]
    run("install_name_tool", *args, dest)
    subprocess.run(["codesign", "--force", "--sign", os.environ.get("SILO_SIGN_IDENTITY") or "-", dest],
                   capture_output=True)
    for r in refs(dest):
        if not r.startswith(("@rpath/", "/usr/lib/", "/System/")):
            sys.exit(f"ERROR: {dest} still references {r}")

for p in plugins:
    install(os.path.join(prefix, "lib/gstreamer-1.0", p), os.path.join(lib64, "gstreamer-1.0", p), "@loader_path/..")
for leaf in sorted(need):
    install(os.path.join(prefix, "lib", leaf), os.path.join(lib64, leaf), "@loader_path")
print("    " + ", ".join(plugins + sorted(need)))
PY
echo "$GST_VERSION" > "$OUT/GSTREAMER_VERSION"
echo "Built: $OUT ($(du -sh "$OUT" | cut -f1))"
echo "Add to a runtime with: Scripts/add-gst-libav.sh <runtime-root>"
