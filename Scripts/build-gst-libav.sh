#!/usr/bin/env bash
# Build CrossOver's GStreamer (1.24.4 / glib 2.78, from the CrossOver FOSS tarball) with gst-libav (FFmpeg
# decoders) + matroska on top: an add-on for CrossOver's own Wine, and the full stack for Silo's.
#
# Why: CrossOver 26.3 ships 17 GStreamer plugins and no FFmpeg, so there is no VC-1 / WMV3 / WMA decoder.
# Devil May Cry 5 (and RE2/RE3, same engine) crash when a VC-1-in-ASF movie starts — the skill previews in
# the customisation menu, "History of DMC" in the main menu. H.264 already works (applemedia/VideoToolbox).
# The decoders live in gst-libav; a newer build (say Homebrew's 1.28) is useless here, because the 1.24
# core refuses any plugin built for a newer minor (gstreamer/gst/gstplugin.c: `minor > GST_VERSION_MINOR`).
# So: build 1.24.4 from the same tarball, then gst-libav + matroska against it and FFmpeg FFMPEG_VERSION
# (the FFmpeg that GStreamer's own FFmpeg.wrap pins for 1.24).
#
# Outputs (every install name and reference @rpath, no Homebrew, no DYLD_* variable needed):
#   dist/gst-libav-<gst>/lib64   — the ADD-ON for a CrossOver runtime: libgstlibav + libgstmatroska + FFmpeg,
#                                  resolving CrossOver's own 1.24.4 libs (identical compatibility versions).
#                                  Add it with Scripts/add-gst-libav.sh.
#   dist/gstreamer-<gst>/lib64   — the whole STACK for Silo's own from-source runtime: CrossOver's 17 plugins
#                                  + libav + matroska and every library they and winegstreamer need (glib
#                                  2.78 with its proxy-libintl, as CrossOver). bundle_wine_dylibs.py takes it
#                                  via SILO_GST_STACK — CrossOver parity instead of Homebrew's 270 plugins.
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
SRC="${SILO_CX_SOURCES:-$ROOT/.wine-build/src/sources}"   # CI extracts the tarball elsewhere
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
    --extra-cflags="-mmacosx-version-min=11.0 -isysroot $(xcrun --show-sdk-path)" \
    --extra-ldflags="-mmacosx-version-min=11.0 -isysroot $(xcrun --show-sdk-path) -Wl,-headerpad_max_install_names" \
    > "$WORK/ffmpeg-configure.log" \
  && make -j"$JOBS" > "$WORK/ffmpeg-make.log" 2>&1 && make install > /dev/null ) \
  || { echo "ERROR: FFmpeg build failed — see $WORK/ffmpeg-*.log"; exit 1; }
grep -q "^License: LGPL" "$WORK/ffmpeg-configure.log" || { echo "ERROR: FFmpeg is not LGPL-only"; exit 1; }

# A meson cross file: host = x86_64 darwin, so meson knows what it's generating; the test binaries it
# runs during configure are x86_64 and simply run under Rosetta (needs_exe_wrapper = false).
# -isysroot with the SDK made explicit: clang's DEFAULT search paths include the host's /usr/local/include
# and /usr/local/lib — i.e. x86_64 Homebrew — which pkg-config's LIBDIR doesn't cover. Measured: glib and
# the asf plugin linked Homebrew's /usr/local/opt/gettext/lib/libintl.8.dylib. With an explicit sysroot
# those defaults become <SDK>/usr/local/…, which don't exist, and glib falls back to its proxy-libintl.
SDK="$(xcrun --show-sdk-path)"
cat > "$WORK/x86_64-darwin.ini" <<EOF
[binaries]
c = ['clang', '-arch', 'x86_64']
cpp = ['clang++', '-arch', 'x86_64']
objc = ['clang', '-arch', 'x86_64']
objcpp = ['clang++', '-arch', 'x86_64']
ar = 'ar'
strip = 'strip'
pkg-config = '/usr/local/bin/pkgconf'

[built-in options]
c_args = ['-mmacosx-version-min=11.0', '-isysroot', '$SDK']
cpp_args = ['-mmacosx-version-min=11.0', '-isysroot', '$SDK']
objc_args = ['-mmacosx-version-min=11.0', '-isysroot', '$SDK']
objcpp_args = ['-mmacosx-version-min=11.0', '-isysroot', '$SDK']
c_link_args = ['-mmacosx-version-min=11.0', '-isysroot', '$SDK', '-Wl,-headerpad_max_install_names']
cpp_link_args = ['-mmacosx-version-min=11.0', '-isysroot', '$SDK', '-Wl,-headerpad_max_install_names']
objc_link_args = ['-mmacosx-version-min=11.0', '-isysroot', '$SDK', '-Wl,-headerpad_max_install_names']
objcpp_link_args = ['-mmacosx-version-min=11.0', '-isysroot', '$SDK', '-Wl,-headerpad_max_install_names']

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

# glib 2.78: a build dependency for the add-on (a CrossOver runtime keeps its own), shipped in the full stack.
meson_build glib "$SRC/glib" -Dnls=disabled -Dtests=false -Dman=false -Dgtk_doc=false -Ddtrace=false \
  -Dsysprof=disabled -Dselinux=disabled -Dxattr=false -Dlibmount=disabled

# GStreamer 1.24.4. auto_features=disabled keeps every plugin off unless enabled below; the libraries
# (audio, video, tag, pbutils, riff, …) are always built.
GST="$SRC/gstreamer/subprojects"
common=(--wrap-mode=nodownload -Dauto_features=disabled -Ddoc=disabled -Dtests=disabled)
meson_build gstreamer "$GST/gstreamer" "${common[@]}" -Dnls=disabled -Dexamples=disabled -Dtools=enabled \
  -Dintrospection=disabled -Dptp-helper=disabled
# The plugins: CrossOver 26.3's own 17 (measured from its lib64/gstreamer-1.0) + libav + matroska.
meson_build gst-plugins-base "$GST/gst-plugins-base" "${common[@]}" -Dnls=disabled -Dexamples=disabled \
  -Dtools=disabled -Dintrospection=disabled -Dorc=disabled \
  -Daudioconvert=enabled -Daudioresample=enabled -Dplayback=enabled -Dtypefind=enabled \
  -Dvideoconvertscale=enabled -Dgl=enabled -Dgl_api=opengl -Dgl_platform=cgl -Dgl_winsys=cocoa
meson_build gst-plugins-good "$GST/gst-plugins-good" "${common[@]}" -Dnls=disabled -Dexamples=disabled \
  -Dorc=disabled -Daudioparsers=enabled -Davi=enabled -Ddeinterlace=enabled -Did3demux=enabled \
  -Disomp4=enabled -Dvideofilter=enabled -Dwavparse=enabled -Dmatroska=enabled
meson_build gst-plugins-bad "$GST/gst-plugins-bad" "${common[@]}" -Dnls=disabled -Dexamples=disabled \
  -Dtools=disabled -Dintrospection=disabled -Dorc=disabled -Dgl=enabled -Dapplemedia=enabled -Dvideoparsers=enabled
meson_build gst-plugins-ugly "$GST/gst-plugins-ugly" "${common[@]}" -Dnls=disabled -Dorc=disabled \
  -Dasfdemux=enabled
meson_build gst-libav "$GST/gst-libav" "${common[@]}"

echo "==> Check: the decoders Wine needs are there"
export GST_PLUGIN_SYSTEM_PATH="$PREFIX/lib/gstreamer-1.0" GST_REGISTRY="$WORK/registry.bin"
rm -f "$GST_REGISTRY"
for element in avdec_vc1 avdec_wmv3 avdec_wmv2 avdec_wmav2 avdec_wmapro matroskademux asfdemux qtdemux \
               vtdec decodebin audioconvert videoconvert h264parse; do
  "$PREFIX/bin/gst-inspect-1.0" --exists "$element" || { echo "ERROR: $element missing"; exit 1; }
done

echo "==> Package"
# Two outputs from the same prefix, every file relocated to @rpath and checked:
#   dist/gst-libav-<gst>/lib64   — the add-on for a CrossOver runtime: libav + matroska + FFmpeg only
#                                  (they resolve CrossOver's own 1.24.4 libs). Scripts/add-gst-libav.sh.
#   dist/gstreamer-<gst>/lib64   — the whole stack for Silo's own runtime: CrossOver's 17 plugins + libav +
#                                  matroska, and every library they and winegstreamer need (glib, core, base,
#                                  FFmpeg, …). bundle_wine_dylibs.py takes it via SILO_GST_STACK.
ADDON="$ROOT/dist/gst-libav-$GST_VERSION"
STACK="$ROOT/dist/gstreamer-$GST_VERSION"
rm -rf "$ADDON" "$STACK"
python3 - "$PREFIX" "$ADDON/lib64" "$STACK/lib64" <<'PY'
import os, subprocess, sys
prefix, addon, stack = sys.argv[1:4]
plugdir = os.path.join(prefix, "lib/gstreamer-1.0")
ADDON_PLUGINS = ["libgstlibav.dylib", "libgstmatroska.dylib"]
# CrossOver 26.3's own plugin set (its lib64/gstreamer-1.0, measured from the stock app) + the add-on's two.
CX_PLUGINS = ["libgstapplemedia.dylib", "libgstasf.dylib", "libgstaudioconvert.dylib", "libgstaudioparsers.dylib",
              "libgstaudioresample.dylib", "libgstavi.dylib", "libgstcoreelements.dylib", "libgstdeinterlace.dylib",
              "libgstid3demux.dylib", "libgstisomp4.dylib", "libgstopengl.dylib", "libgstplayback.dylib",
              "libgsttypefindfunctions.dylib", "libgstvideoconvertscale.dylib", "libgstvideofilter.dylib",
              "libgstvideoparsersbad.dylib", "libgstwavparse.dylib"]
# What winegstreamer.so links (as CrossOver's does): the stack must carry these even if no plugin needs them.
WINEGST_LIBS = ["libgstvideo-1.0.0.dylib", "libgstaudio-1.0.0.dylib", "libgsttag-1.0.0.dylib",
                "libgstbase-1.0.0.dylib", "libgstreamer-1.0.0.dylib", "libgobject-2.0.0.dylib", "libglib-2.0.0.dylib"]

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

def ours(ref):
    """The prefix file a reference points at, or None for a system library."""
    if ref.startswith(prefix + "/"):
        return os.path.realpath(ref)
    if ref.startswith("@rpath/"):
        cand = os.path.join(prefix, "lib", ref[len("@rpath/"):])
        if os.path.exists(cand):
            return os.path.realpath(cand)
        sys.exit(f"ERROR: {ref} not found in {prefix}/lib")
    return None

def closure(roots):
    need, queue = {}, list(roots)
    while queue:
        current = queue.pop()
        for r in refs(current):
            real = ours(r)
            # otool -L lists a dylib's own install name first — that's the file itself, not a dependency.
            if real == os.path.realpath(current):
                continue
            if real and os.path.basename(r) not in need:
                need[os.path.basename(r)] = real
                queue.append(real)
    return need

# glib's proxy-libintl exports g_libintl_* — NOT the GNU gettext libintl_* symbols that Homebrew's gnutls,
# libidn2, … import from THEIR libintl.8.dylib. Both have to live in one lib64, so ours gets its own leaf
# (measured 2026-09-28: the two symbol sets don't overlap, so they coexist in one process).
RENAMES = {"libintl.8.dylib": "libproxy-intl.8.dylib"}

def leaf_for(name):
    return RENAMES.get(name, name)

def install(src, dest, rpath, renames=False):
    if renames:
        dest = os.path.join(os.path.dirname(dest), leaf_for(os.path.basename(dest)))
    os.makedirs(os.path.dirname(dest), exist_ok=True)
    subprocess.run(["cp", "-L", src, dest], check=True)
    os.chmod(dest, 0o755)
    args = ["-id", "@rpath/" + os.path.basename(dest)]
    for r in refs(dest):
        leaf = os.path.basename(r)
        if r.startswith(prefix + "/") or (renames and r.startswith("@rpath/") and leaf in RENAMES):
            new = "@rpath/" + (leaf_for(leaf) if renames else leaf)   # meson's absolute install names → @rpath
            if new != r:
                args += ["-change", r, new]
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

def package(out, plugins, extra_roots, keep, renames=False):
    missing = [p for p in plugins if not os.path.exists(os.path.join(plugdir, p))]
    if missing:
        sys.exit(f"ERROR: plugins not built: {', '.join(missing)}")
    roots = [os.path.join(plugdir, p) for p in plugins] + [os.path.join(prefix, "lib", l) for l in extra_roots]
    libs = closure(roots)
    libs.update({l: os.path.realpath(os.path.join(prefix, "lib", l)) for l in extra_roots})
    libs = {leaf: real for leaf, real in libs.items() if keep(leaf)}
    for p in plugins:
        install(os.path.join(plugdir, p), os.path.join(out, "gstreamer-1.0", p), "@loader_path/..", renames)
    for leaf, real in sorted(libs.items()):
        install(real, os.path.join(out, leaf), "@loader_path", renames)
    if renames:   # a renamed leaf must be referenced by its new name only
        with open(os.path.join(out, "RENAMES"), "w") as fh:
            fh.writelines(f"{a} {b}\n" for a, b in RENAMES.items() if a in libs)
    return len(plugins), len(libs)

ffmpeg = lambda leaf: leaf.startswith(("libav", "libsw", "libpostproc"))
n = package(addon, ADDON_PLUGINS, [], ffmpeg)
print(f"    add-on: {n[0]} plugins + {n[1]} FFmpeg libraries")
n = package(stack, CX_PLUGINS + ADDON_PLUGINS, WINEGST_LIBS, lambda leaf: True, renames=True)
print(f"    stack:  {n[0]} plugins + {n[1]} libraries")
PY
echo "$GST_VERSION" > "$ADDON/GSTREAMER_VERSION"
echo "$GST_VERSION" > "$STACK/GSTREAMER_VERSION"
echo "Built: $ADDON ($(du -sh "$ADDON" | cut -f1)) — add to a CrossOver runtime with Scripts/add-gst-libav.sh"
echo "Built: $STACK ($(du -sh "$STACK" | cut -f1)) — for Silo's own runtime: SILO_GST_STACK=$STACK/lib64"
