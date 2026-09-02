# Silo 0.5.7

Two small ones.

## Run a program from the game card

**Run Program…** now sits in the toolbar of a non-Steam game's card, where the Steam card keeps its Store
button — which a copy bought elsewhere has no use for, so the slot was free.

It was already in the settings sheet and the tile's ••• menu, but the card is what opens when you click
the tile of a game you've associated with a Steam listing, so it's where you'd look. Same action as the
other two: it runs an installer, a configuration tool or a language selector in that game's own bottle and
waits for the window to close.

## `DYLD_LIBRARY_PATH` no longer reaches the wine child

Silo builds the library search path for its wine processes deliberately, leaving `/usr/local/lib` out:
with Homebrew on that path, `winegstreamer` once loaded both gtk3 and gtk4 and the process died with
*"Class … is implemented in both"*.

That covers `DYLD_FALLBACK_LIBRARY_PATH` — the *fallback* list. `DYLD_LIBRARY_PATH`, without FALLBACK, is
read by dyld ahead of the system paths, so it outranks the fallback entirely. Silo never sets it, but it
was passing it through unchanged if the launching environment happened to have one.

Launched from Finder or the Dock, a GUI app doesn't inherit the shell's configuration, so this was
unlikely to bite. From a terminal it could. The protection shouldn't depend on how Silo was
opened, so the variable is now stripped along with the two loader-injection ones — Silo never sets it
legitimately, so nothing is lost.

---

Silo downloads its own Wine (built from CrossOver's FOSS source in CI) and imports Apple's GPTK from your
`.dmg`. Runs on macOS 15+ on Apple Silicon.

Gatekeeper: the build is ad-hoc signed, so right-click → **Open** on first launch, then allow it in
**System Settings → Privacy & Security** — macOS blocks the first attempt and offers the override there.
If you'd rather use the terminal, move Silo.app to Applications first, then
`xattr -dr com.apple.quarantine /Applications/Silo.app`.
