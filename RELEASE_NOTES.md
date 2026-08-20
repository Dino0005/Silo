# Silo 0.5.2

A game card for the games Steam doesn't know about, and the last of the Italian translation.

## Game card for non-Steam games

Clicking a Steam game's tile opens a card — hero art, description, developer, genres, release date.
Clicking a non-Steam game's tile opened the settings sheet, because Silo had nowhere to get any of that
from.

It does now, if you tell it where. A manual game's settings gained a **Game card** section: enter the
Steam app ID of the same game — the number in its store page address — and Silo checks it against the
store and keeps it. From then on the tile opens a card like any other game's.

- **The ID is typed, not searched.** A text search returns near-identical candidates — "God of War" also
  matches its sequel, Batman Arkham Knight has several editions — and choosing one on your behalf
  eventually shows you the wrong game with no way to tell why.
- **No Store button**, unlike the Steam card: the copy you're playing wasn't bought there.
- **Remove, not Uninstall**: for a manual game it forgets the entry and its bottle and leaves the
  installed files alone.
- **If the game has no cover yet**, the association downloads Steam's artwork and files it in `Covers/`
  like one you'd pick yourself — so the tile still draws with no network. A cover you chose is never
  replaced, and removing the card leaves it in place.

Entirely optional and reversible: with no association the tile opens the settings, exactly as before.

## Italian, finished

Status messages carrying a game's name — "Launched God of War.", "Added …", "Removed …" — stayed in
English however the app was set. An interpolated message can never match a fixed catalogue key, so the
lookup silently fell through; the same defect fixed for error messages earlier. Twenty-five of them now
resolve properly.

Also reworded the bottle-switch line: it said to close the game running in the other bottle, when what's
usually running there is just Steam.

---

Silo downloads its own Wine (built from CrossOver's FOSS source in CI) and imports Apple's GPTK from your
`.dmg`. Runs on macOS 15+ on Apple Silicon.

Gatekeeper: the build is ad-hoc signed, so right-click → **Open** on first launch, then allow it in
**System Settings → Privacy & Security** — macOS blocks the first attempt and offers the override there.
If you'd rather use the terminal, move Silo.app to Applications first, then
`xattr -dr com.apple.quarantine /Applications/Silo.app`.
