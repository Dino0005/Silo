#!/usr/bin/env python3
"""Make a self-built Wine install self-contained, in CrossOver's own layout.

CrossOver's Wine keeps every third-party dylib in `<root>/lib64` with an `@rpath/<leaf>` install name,
its GStreamer plugins in `<root>/lib64/gstreamer-1.0`, and gives each of Wine's unix modules the rpath
`@loader_path/../../../lib64` (lib/wine/x86_64-unix → <root>/lib64). Nothing references an absolute
Homebrew path and no DYLD_* variable is needed: dyld resolves link-time `@rpath/` references AND Wine's
leaf-name dlopen()s ("libfreetype.6.dylib", "libgnutls.30.dylib", "libSDL2-2.0.0.dylib", …) through the
caller's LC_RPATH (measured on macOS 27). This script produces exactly that from the x86_64 Homebrew the
build links against:

  * copies the transitive closure of every non-system dylib Wine's Mach-O files reference, plus the libs
    Wine dlopen()s by leaf name (freetype, gnutls, MoltenVK, the pinned SDL), into lib64/;
  * copies GStreamer's plugins into lib64/gstreamer-1.0 (minus DENIED_PLUGINS) and their closure into
    lib64/;
  * rewrites every copied file's install name and references to `@rpath/<leaf>`, replaces its rpaths with
    one pointing at lib64, and rewrites Wine's own references the same way;
  * fails if any Mach-O in the tree still resolves a dependency outside the tree and the system.

Why hermetic matters: the old bundle (lib/silo-bundled + DYLD_FALLBACK_LIBRARY_PATH) could not carry the
media stack — Wine linked glib/GStreamer by absolute Homebrew path, so on a machine WITH Homebrew one copy
loaded from there and another from the bundle ("Class GstCocoaApplicationDelegate is implemented in both",
"cannot register existing type"). With every reference rewritten to @rpath there is only ever one copy.

No gst-plugin-scanner is shipped (CrossOver ships none either): winegstreamer initialises GStreamer with
--gst-disable-registry-fork (dlls/winegstreamer/unixlib.c), so Wine always scans plugins in-process and
caches the result in GST_REGISTRY. That is also why DENIED_PLUGINS matters: on a prefix's first media use,
every shipped plugin is dlopen()ed into the game once.

Idempotent. Refuses to touch a lib64/ it didn't create (a CrossOver-imported tree already has its own).

GStreamer — two sources:
  * SILO_GST_STACK set (what build-wine.sh / build-wine.yml do): CrossOver's own GStreamer 1.24.4 / glib 2.78
    with CrossOver's 17 plugins + libav + matroska, built from the FOSS tarball by build-gst-libav.sh and
    already relocated. It is copied into lib64 as is, and Wine's references into the GStreamer build prefix
    are pointed at it (its RENAMES file maps any leaf it renamed). Wine must have been compiled against that
    prefix: winegstreamer built against Homebrew's newer glib needs symbols 2.78 doesn't have
    (g_once_init_enter_pointer — measured), so that combination is refused.
  * unset (legacy): Homebrew's GStreamer and its plugins, minus DENIED_PLUGINS.

Usage: bundle_wine_dylibs.py <wine-install-dir>
Env:   SILO_GST_STACK      — dist/gstreamer-<ver>/lib64 from Scripts/build-gst-libav.sh (see above)
       SILO_SDL_DYLIB      — the pinned libSDL2 to ship (built by build-wine.sh / build-wine.yml)
       SILO_SIGN_IDENTITY  — codesign identity for modified files (default: ad-hoc "-")
"""
import os
import shutil
import subprocess
import sys

BREW_ROOTS = ("/usr/local/", "/opt/homebrew/")
SYSTEM_ROOTS = ("/usr/lib/", "/System/")
MARKER = ".silo-relocated"

# Libraries Wine dlopen()s by leaf name — invisible to otool, so seeded explicitly.
DLOPEN_PACKAGES = ("freetype", "gnutls", "molten-vk")

# Plugins that would pull a whole toolkit or interpreter into a game process for nothing: GTK video sinks
# (a Wine game never renders into a GTK widget), the Python plugin loader (initialises an embedded Python
# at scan time — CrossOver ships it and every first scan logs "pygobject initialization failed"), and
# gst-validate's test tracer. Wine scans in-process, so each would be dlopen()ed into the game.
DENIED_PLUGINS = {
    "libgstgtk.dylib",
    "libgstgtk4.dylib",
    "libgstpython.dylib",
    "libgstvalidatetracer.dylib",
}
# ...and, belt and braces, any plugin whose closure reaches one of these.
DENIED_DEP_PREFIXES = ("libgtk-", "libgdk-3", "libgdk-4", "libpython")


def run(*args):
    return subprocess.run(args, check=True, capture_output=True, text=True).stdout


def is_macho(path):
    try:
        with open(path, "rb") as f:
            magic = f.read(4)
    except OSError:
        return False
    return magic in (b"\xcf\xfa\xed\xfe", b"\xca\xfe\xba\xbe", b"\xfe\xed\xfa\xcf", b"\xbe\xba\xfe\xca")


def archs(path):
    try:
        return run("lipo", "-archs", path).split()
    except subprocess.CalledProcessError:
        return []


class MachO:
    """otool's view of one file, for the target arch."""

    def __init__(self, path, arch):
        self.path = path
        self.real = os.path.realpath(path)
        self.id = None
        try:
            out = run("otool", "-arch", arch, "-D", path).splitlines()
            if len(out) > 1:
                self.id = out[1].strip()
        except subprocess.CalledProcessError:
            pass
        refs = []
        for line in run("otool", "-arch", arch, "-L", path).splitlines()[1:]:
            ref = line.strip().split(" (compatibility")[0]
            if ref and ref != self.id:
                refs.append(ref)
        self.refs = refs
        self.rpaths = []
        lines = run("otool", "-arch", arch, "-l", path).splitlines()
        for i, line in enumerate(lines):
            if line.strip() == "cmd LC_RPATH":
                for follow in lines[i + 1:i + 4]:
                    follow = follow.strip()
                    if follow.startswith("path "):
                        self.rpaths.append(follow[5:].split(" (offset")[0])
                        break

    def resolve(self, ref):
        """The file a reference points at, from this file's point of view, or None."""
        base = os.path.dirname(self.real)
        if ref.startswith("@loader_path/"):
            cand = os.path.join(base, ref[len("@loader_path/"):])
            return os.path.realpath(cand) if os.path.exists(cand) else None
        if ref.startswith("@rpath/"):
            leaf = ref[len("@rpath/"):]
            for rp in self.rpaths:
                if rp.startswith("@loader_path"):
                    rp = base + rp[len("@loader_path"):]
                elif rp.startswith("@"):
                    continue
                cand = os.path.join(rp, leaf)
                if os.path.exists(cand):
                    return os.path.realpath(cand)
            return None
        if ref.startswith("@"):
            return None
        return os.path.realpath(ref) if os.path.exists(ref) else None


def is_foreign(real):
    return real is not None and not real.startswith(SYSTEM_ROOTS)


class Bundler:
    def __init__(self, wd):
        self.wd = os.path.realpath(wd)
        self.lib64 = os.path.join(self.wd, "lib64")
        self.plugins = os.path.join(self.lib64, "gstreamer-1.0")
        loader = os.path.join(self.wd, "bin", "wine64")
        if not os.path.exists(loader):
            loader = os.path.join(self.wd, "bin", "wine")
        found = archs(loader)
        self.arch = found[0] if found else "x86_64"
        self.identity = os.environ.get("SILO_SIGN_IDENTITY") or "-"
        self.cache = {}
        self.leaf_of = {}      # real source path -> canonical leaf in lib64
        self.source_of = {}    # canonical leaf -> real source path (collision check)
        self.denied = set()    # plugins skipped, for the summary
        self.stack = os.environ.get("SILO_GST_STACK") or None
        self.stack_leafs, self.stack_renames = set(), {}
        if self.stack:
            if not os.path.isdir(os.path.join(self.stack, "gstreamer-1.0")):
                sys.exit(f"ERROR: SILO_GST_STACK={self.stack} is not a GStreamer stack (no gstreamer-1.0/)")
            self.stack_leafs = {f for f in os.listdir(self.stack) if f.endswith(".dylib")}
            renames = os.path.join(self.stack, "RENAMES")
            if os.path.exists(renames):
                for line in open(renames):
                    if line.split():
                        old, new = line.split()
                        self.stack_renames[old] = new

    def stack_leaf(self, ref):
        """The stack file a reference means, or None. Only references that are NOT Homebrew's count: a
        Homebrew library that happens to share a leaf with one of ours (GNU libintl.8.dylib vs our renamed
        proxy-libintl) is a different library and stays Homebrew's."""
        if not self.stack or ref.startswith(BREW_ROOTS) or not (ref.startswith("/") or ref.startswith("@rpath/")):
            return None
        leaf = self.stack_renames.get(os.path.basename(ref), os.path.basename(ref))
        return leaf if leaf in self.stack_leafs else None

    def macho(self, path):
        real = os.path.realpath(path)
        if real not in self.cache:
            self.cache[real] = MachO(path, self.arch)
        return self.cache[real]

    def inside(self, real):
        return real.startswith(self.wd + os.sep)

    def canonical_leaf(self, real):
        m = self.macho(real)
        leaf = os.path.basename(m.id) if m.id else os.path.basename(real)
        prior = self.source_of.get(leaf)
        if prior and prior != real:
            sys.exit(f"ERROR: two different libraries want lib64/{leaf}: {prior} and {real}")
        self.source_of[leaf] = real
        return leaf

    def closure(self, root):
        """Every foreign (non-system, outside the tree) dylib reachable from `root`, as real paths."""
        seen, queue = set(), [root]
        while queue:
            m = self.macho(queue.pop())
            for ref in m.refs:
                if self.stack_leaf(ref) and not self.inside(os.path.realpath(ref) if ref.startswith("/") else ""):
                    continue                      # provided by the GStreamer stack — not copied from anywhere
                if self.stack and ref.startswith(BREW_ROOTS) and os.path.basename(ref) in self.stack_leafs \
                        and os.path.basename(ref).startswith(("libgst", "libglib", "libgobject")):
                    sys.exit(f"ERROR: {m.path} links Homebrew's {ref} but SILO_GST_STACK is set — Wine must be "
                             "compiled against the stack's GStreamer (build-wine.sh puts it first on PKG_CONFIG_PATH)")
                real = m.resolve(ref)
                if real is None:
                    if ref.startswith(BREW_ROOTS):
                        sys.exit(f"ERROR: {m.path} needs {ref}, which is not installed")
                    continue
                if not is_foreign(real) or self.inside(real) or real in seen:
                    continue
                if self.arch not in archs(real):
                    sys.exit(f"ERROR: {real} (needed by {m.path}) has no {self.arch} slice")
                seen.add(real)
                queue.append(real)
        return seen

    # --- rewriting ------------------------------------------------------------------------------------

    def rewrite(self, path, origin, rpath, set_id):
        """Point every foreign reference of `path` at @rpath/<leaf> and make `rpath` its only rpath to
        lib64. References are resolved from `origin` — where the file was copied FROM, since a Homebrew
        lib's own @loader_path/@rpath references only make sense there. Wine's own files (origin == path)
        keep their existing @loader_path rpaths (Wine relies on them)."""
        m = self.macho(origin)
        args = []
        if set_id:
            args += ["-id", "@rpath/" + os.path.basename(path)]
        for ref in m.refs:
            leaf = self.stack_leaf(ref)
            if leaf and not ref.startswith("@rpath/" + leaf):
                args += ["-change", ref, "@rpath/" + leaf]
                continue
            if leaf:
                continue
            real = m.resolve(ref)
            if real is None or not is_foreign(real) or self.inside(real):
                continue
            new = "@rpath/" + self.leaf_of[real]
            if new != ref:
                args += ["-change", ref, new]
        keep_existing = origin == path
        for rp in m.rpaths:
            if rp == rpath or (keep_existing and rp.startswith("@loader_path")):
                continue
            args += ["-delete_rpath", rp]
        if rpath not in m.rpaths:
            args += ["-add_rpath", rpath]
        if args:
            try:
                run("install_name_tool", *args, path)
            except subprocess.CalledProcessError as e:
                sys.exit(f"ERROR: install_name_tool failed on {path}:\n{e.stderr}")
            return True
        return False

    def copy_in(self, real, dest_dir, leaf):
        dest = os.path.join(dest_dir, leaf)
        os.makedirs(dest_dir, exist_ok=True)
        if os.path.lexists(dest):
            os.remove(dest)
        if len(archs(real)) > 1:
            run("lipo", "-thin", self.arch, real, "-output", dest)
        else:
            shutil.copy2(real, dest)
        os.chmod(dest, 0o755)
        return dest

    def sign(self, path):
        subprocess.run(["codesign", "--force", "--sign", self.identity, path], capture_output=True)

    # --- main -----------------------------------------------------------------------------------------

    def brew_prefix(self, formula):
        # /usr/local first: on Apple Silicon that's the x86_64 Homebrew the build links against.
        for root in BREW_ROOTS:
            p = os.path.join(root, "opt", formula)
            if os.path.isdir(p):
                return p
        return None

    def wine_machos(self):
        out = []
        for top in ("bin", "lib"):
            for dirpath, _, files in os.walk(os.path.join(self.wd, top)):
                if os.path.basename(dirpath) == "silo-bundled":
                    continue
                for f in files:
                    p = os.path.join(dirpath, f)
                    if not os.path.islink(p) and is_macho(p) and self.arch in archs(p):
                        out.append(p)
        return out

    def rpath_to_lib64(self, path):
        rel = os.path.relpath(self.lib64, os.path.dirname(path))
        return "@loader_path/" + rel

    def bundle(self):
        if os.path.isdir(self.lib64) and not os.path.exists(os.path.join(self.lib64, MARKER)):
            print(f"{self.lib64} exists and wasn't made by this script (a CrossOver-imported tree?) — leaving it alone")
            return
        print(f"Target arch: {self.arch}")

        wine_files = self.wine_machos()
        libs = set()
        for f in wine_files:
            libs |= self.closure(f)

        aliases = {}   # extra names Wine may dlopen -> real path
        for pkg in DLOPEN_PACKAGES:
            prefix = self.brew_prefix(pkg)
            if not prefix:
                sys.exit(f"ERROR: Homebrew formula '{pkg}' ({self.arch}) not found — install it first")
            libdir = os.path.join(prefix, "lib")
            for name in sorted(os.listdir(libdir)):
                p = os.path.join(libdir, name)
                if name.endswith(".dylib") and self.arch in archs(p):
                    real = os.path.realpath(p)
                    libs |= {real} | self.closure(real)
                    aliases[name] = real

        sdl = os.environ.get("SILO_SDL_DYLIB")
        if sdl:
            if not os.path.isfile(sdl) or self.arch not in archs(sdl):
                sys.exit(f"ERROR: SILO_SDL_DYLIB={sdl} missing or wrong arch ({self.arch})")
            real = os.path.realpath(sdl)
            libs |= {real} | self.closure(real)
            aliases["libSDL2-2.0.0.dylib"] = real

        plugins = {}
        gst = None if self.stack else self.brew_prefix("gstreamer")
        if not self.stack and not gst:
            sys.exit(f"ERROR: Homebrew formula 'gstreamer' ({self.arch}) not found — install it first")
        plugdir = os.path.join(gst, "lib", "gstreamer-1.0") if gst else None
        for name in sorted(os.listdir(plugdir)) if plugdir else []:
            p = os.path.join(plugdir, name)
            if not name.endswith(".dylib") or not os.path.exists(p):
                continue
            real = os.path.realpath(p)
            if name in DENIED_PLUGINS or self.arch not in archs(real):
                self.denied.add(name)
                continue
            deps = self.closure(real)
            if any(os.path.basename(d).startswith(DENIED_DEP_PREFIXES) for d in deps):
                self.denied.add(name)
                continue
            plugins[name] = real
            libs |= deps

        # Fresh lib64 (ours — the marker check above guarantees it), and drop the pre-lib64 bundle so an
        # old tree can't end up with two copies of a library on DYLD_FALLBACK_LIBRARY_PATH.
        shutil.rmtree(self.lib64, ignore_errors=True)
        shutil.rmtree(os.path.join(self.wd, "lib", "silo-bundled"), ignore_errors=True)
        os.makedirs(self.lib64)

        if self.stack:
            # The stack first, as built (already @rpath and signed). Its leafs are reserved: a Homebrew
            # library claiming one would be a second copy under the same name.
            shutil.copytree(self.stack, self.lib64, symlinks=True, dirs_exist_ok=True)
            os.remove(os.path.join(self.lib64, "RENAMES")) if os.path.exists(os.path.join(self.lib64, "RENAMES")) else None
            for leaf in self.stack_leafs:
                self.source_of[leaf] = "the GStreamer stack"
        for real in sorted(libs):
            self.leaf_of[real] = self.canonical_leaf(real)

        copied = []
        for real in sorted(libs):
            copied.append((self.copy_in(real, self.lib64, self.leaf_of[real]), real, "@loader_path", True))
        for name, real in sorted(plugins.items()):
            copied.append((self.copy_in(real, self.plugins, name), real, "@loader_path/..", True))
        for dest, origin, rpath, set_id in copied:
            self.rewrite(dest, origin, rpath, set_id)
            self.sign(dest)

        # Leaf names Wine dlopen()s that differ from the canonical leaf (libfreetype.dylib → .6.dylib).
        for name, real in aliases.items():
            leaf = self.leaf_of[real]
            link = os.path.join(self.lib64, name)
            if name != leaf and not os.path.lexists(link):
                os.symlink(leaf, link)

        # Wine's own files: references → @rpath, and every unix module gets the rpath to lib64 (the
        # leaf-name dlopen()s resolve through it). build-wine.sh already links that rpath in; this covers
        # older trees too.
        for f in wine_files:
            unix_module = os.sep + "lib" + os.sep + "wine" + os.sep in f
            m = self.macho(f)
            needs = any(is_foreign(r) and not self.inside(r) for r in (m.resolve(x) for x in m.refs)) \
                or any(self.stack_leaf(x) for x in m.refs)
            if needs or unix_module:
                if self.rewrite(f, f, self.rpath_to_lib64(f), False):
                    self.sign(f)

        with open(os.path.join(self.lib64, MARKER), "w") as fh:
            fh.write("lib64/ built by Scripts/bundle_wine_dylibs.py — safe for it to rebuild\n")

        self.verify()
        size = run("du", "-sh", self.lib64).split()[0]
        if self.stack:
            n = len([f for f in os.listdir(self.plugins) if f.endswith(".dylib")])
            print(f"Bundled {len(libs)} libraries + the GStreamer stack ({len(self.stack_leafs)} libraries, "
                  f"{n} plugins) into {self.lib64} ({size})")
        else:
            print(f"Bundled {len(libs)} libraries + {len(plugins)} GStreamer plugins into {self.lib64} ({size})")
        if self.denied:
            print(f"Skipped plugins: {', '.join(sorted(self.denied))}")

    def verify(self):
        """Every Mach-O in the tree must resolve all its dependencies inside the tree or the system."""
        self.cache.clear()
        bad = []
        for dirpath, _, files in os.walk(self.wd):
            for f in files:
                p = os.path.join(dirpath, f)
                if os.path.islink(p) or not is_macho(p) or self.arch not in archs(p):
                    continue
                m = self.macho(p)
                for ref in m.refs:
                    if ref.startswith(SYSTEM_ROOTS):
                        continue
                    real = m.resolve(ref)
                    if real is None or not self.inside(real):
                        bad.append(f"{os.path.relpath(p, self.wd)} -> {ref}")
        if bad:
            sys.exit("ERROR: unresolved or out-of-tree dependencies after bundling:\n  " + "\n  ".join(bad[:40]))


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit("usage: bundle_wine_dylibs.py <wine-install-dir>")
    Bundler(sys.argv[1]).bundle()
