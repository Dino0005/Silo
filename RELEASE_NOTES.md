# Silo 0.5.3

The library draws itself with no network, and the settings panes finish speaking Italian.

## Tile artwork lives on disk

A Steam game's tile guessed its image address from the app ID — `…/steam/apps/<id>/header.jpg` — without
asking Steam anything. Fast, and it's why opening the library made no API calls. Two things followed:

- **Some games have no `header.jpg` at all.** Their tile stayed blank while their card showed artwork
  perfectly well, because the card uses the `header_image` the store actually returns.
- **With no network the tiles came up empty.** They relied on URLSession's cache, and images are evicted
  from it long before the small JSON responses are.

Artwork is now stored in `Artwork/`, one file per app ID. The saved file is drawn immediately — instantly,
offline included — and refreshed behind it. Not on every open: a file younger than a day is left alone,
because Steam rotates seasonal art but re-fetching everything each time would be waste. A failed refresh
never blanks a tile that was drawing fine.

When the guessed address 404s, and only then, Silo asks the store for the real one. One request, for the
few games that need it, and the answer lands on disk so it isn't asked again.

The card falls back to that same file when the network is gone. Its description and metadata still don't
survive offline — they arrive in the same API response, and caching those is a separate job.

`Artwork/` is deliberately not `Covers/`: that holds images you chose, this is a cache the app can empty
without losing anything.

## Italian, actually finished

The 0.5.2 notes said the translation was done. The library's messages were; the **settings panes** weren't
— Wine, GPTK, DXMT, Media Foundation and Backend still answered in English whenever the message carried a
name: "Removed wine cx 26.3.0.", "Installed …". Same cause as before, an interpolated string can't match a
fixed catalogue key. Twenty-two of them now resolve.

---

Silo downloads its own Wine (built from CrossOver's FOSS source in CI) and imports Apple's GPTK from your
`.dmg`. Runs on macOS 15+ on Apple Silicon.

Gatekeeper: the build is ad-hoc signed, so right-click → **Open** on first launch, then allow it in
**System Settings → Privacy & Security** — macOS blocks the first attempt and offers the override there.
If you'd rather use the terminal, move Silo.app to Applications first, then
`xattr -dr com.apple.quarantine /Applications/Silo.app`.
