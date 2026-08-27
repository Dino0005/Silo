# Silo 0.5.5

A correction to 0.5.4, worth its own release.

## The startup sweep stayed out of CrossOver's bottles

0.5.4 began clearing the `server-*` directories a dead `wineserver` leaves in `/tmp`. It cleared too many:
those directories belong to whichever prefix created them, and if you run CrossOver alongside Silo, its
bottles leave them there too.

Measured on a machine with both installed — `/tmp` held seven, **six of them CrossOver's**, and opening
Silo removed all seven. Nothing breaks (CrossOver recreates them on the next launch), but an app reaching
into another app's files isn't something to leave shipped, and the code claimed not to: it said a
CrossOver directory would be left alone, which held only while that bottle was running.

Ownership is now worked out rather than assumed. A directory's name derives from its prefix's device and
inode, so Silo computes the names its own bottles would produce — the Steam bottle, its Media Foundation
twin, every manual game's — and never looks at anything else.

One consequence worth stating: the leftover of a bottle you've since **deleted** now stays, because
without the prefix its name can't be computed. Better one stale directory than reaching into someone
else's.

## The Media Foundation bottle was missing from the list

The same list drives **Stop All Bottle Processes** and the quit prompt, so a game running in the Media
Foundation bottle was invisible to both — it wouldn't be stopped, and quitting wouldn't mention it. It's
in the list now.

---

Silo downloads its own Wine (built from CrossOver's FOSS source in CI) and imports Apple's GPTK from your
`.dmg`. Runs on macOS 15+ on Apple Silicon.

Gatekeeper: the build is ad-hoc signed, so right-click → **Open** on first launch, then allow it in
**System Settings → Privacy & Security** — macOS blocks the first attempt and offers the override there.
If you'd rather use the terminal, move Silo.app to Applications first, then
`xattr -dr com.apple.quarantine /Applications/Silo.app`.
