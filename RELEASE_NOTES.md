# Silo 0.6.0

Shortcuts that look like they belong.

## The macOS shape

0.5.9 got the game's own icon onto its shortcut. It arrived as a full-bleed square, which is not what a
macOS icon is: the system's own are rounded squares covering about 82% of their tile, and anything filling
the whole thing reads as foreign in the Dock.

Every icon Silo derives now goes through that shape — from the executable, from the artwork cache, from
the store. A rectangular source is **cropped to its centre** rather than squashed: header art is 460×215,
and stretching it into a square distorted the artwork for no gain. The sides are usually background.

The proportions were checked against real images with a throwaway preview before being written down,
rather than guessed at in the code.

## Bring your own

Some executables carry no icon at all — copy protection strips the resource section — and the store
artwork that stands in for them isn't always what you'd choose.

Drop a PNG in Silo's `Covers/` folder and it wins outright, ahead of the executable's icon and everything
else. Name it after the Steam app ID with `_icon.png` appended (`3764200_icon.png`), or after a non-Steam
game's cover file the same way (`538C9332-…_icon.png`). It's used **exactly as given** — no crop, no mask,
your transparency intact — so the margin is yours to leave: the artwork should cover about 82% of the
canvas, 422×422 centred on 512×512, or 844×844 on 1024×1024.

`Covers/` and not `Artwork/` on purpose: the latter is a cache Silo writes and may empty, where a
hand-made file would eventually vanish.

---

Silo downloads its own Wine (built from CrossOver's FOSS source in CI) and imports Apple's GPTK from your
`.dmg`. Runs on macOS 15+ on Apple Silicon.

Gatekeeper: the build is ad-hoc signed, so right-click → **Open** on first launch, then allow it in
**System Settings → Privacy & Security** — macOS blocks the first attempt and offers the override there.
If you'd rather use the terminal, move Silo.app to Applications first, then
`xattr -dr com.apple.quarantine /Applications/Silo.app`.
