# Silo 0.5.9

Games look like themselves now.

## The icon reader never read an icon

A non-Steam game's tile is supposed to show the icon out of its `.exe`. It never did — every game got the
generic controller — and the reason turned out to be one line: a PE's resource tree is three directories
deep (type → name → language) and the parser walked four, asking for a sub-directory of entries that point
at data. That returns nothing, for every executable ever passed in.

It went unnoticed because a manual game usually gets cover art soon after being added, and the cover wins
over the icon. The missing icon is, in fact, why associating a Steam app ID was worth adding at all.

**The tests didn't catch it because they shared the mistake.** The synthetic executable they build had the
same extra level — written alongside the parser, from the same misunderstanding — so the two agreed with
each other while no real file worked. There's now a test that runs against a real game executable, named
by `SILO_TEST_EXE` and skipped when it isn't set. That's what made the bug visible: a file neither side
had built.

## And then, the things that had been hiding behind it

**The placeholder was drawing a controller of its own,** so a tile showed the game's icon and a controller
at once. Invisible until icons started appearing.

**The largest icon was picked by weight, not by size.** A 256×256 stored as PNG is lighter than an
uncompressed 128×128 — measured at 25,714 bytes against 67,646 — so the heaviest entry was the smaller
picture, and the Dock got half the resolution on offer.

## Steam shortcuts too

A Steam game's desktop shortcut used the header art: 460×215 squashed into a square, and it looked it. It
now carries the game's own icon.

Which executable that is can't be guessed — Resident Evil ships three, of which two are a crash reporter
and an installer message; Tekken 8 ships one, a 196 KB launcher — but the launch log names the one that
actually ran, and nobody makes a shortcut before playing. Failing that, the `.exe` files in the game's
folder are tried in turn.

And when none of them has an icon at all — `re9.exe` has no resource section whatsoever, its sections
rewritten by copy protection — the cover art steps in, taken from the on-disk cache first. That last
detail matters: the cover URL is guessed from the app ID and 404s for some titles, so going to the network
first left exactly that game's shortcut blank while the right image sat in `Artwork/`.

## Also

The test suite created its Wine scratch directory in the machine's real `TMPDIR` with default permissions.
Wine requires 0700 there, and CrossOver — which shares that directory — refused to take its lock and
aborted on launch. One `swift test` run was enough to break it until the directory was deleted by hand.

---

Silo downloads its own Wine (built from CrossOver's FOSS source in CI) and imports Apple's GPTK from your
`.dmg`. Runs on macOS 15+ on Apple Silicon.

Gatekeeper: the build is ad-hoc signed, so right-click → **Open** on first launch, then allow it in
**System Settings → Privacy & Security** — macOS blocks the first attempt and offers the override there.
If you'd rather use the terminal, move Silo.app to Applications first, then
`xattr -dr com.apple.quarantine /Applications/Silo.app`.
