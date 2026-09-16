# Silo 0.6.2

Three fixes. The first one you can see from across the room.

## The window looks like a Mac app again

Silo's toolbar was four loose icons beside a bordered search field — the way macOS draws an app written
before Liquid Glass. The toolbar code wasn't wrong. It was never consulted.

The binary said this:

    LC_BUILD_VERSION   minos 15.0   sdk 15.0

SwiftPM writes the deployment target into *both* of those fields, and the second one is what AppKit reads
to decide whether an app gets the current design or the compatibility appearance. An app compiled against
the macOS 27 SDK was declaring itself built against the 15. macOS 26 restyled old-SDK apps anyway, so
nothing looked wrong there; 27 doesn't, and the capsule went missing with no code change behind it.

The link step now records the SDK Silo is actually built against, keeping the deployment target where it
belongs — macOS 15 and later, unchanged. And because a mistake of this kind shows up nowhere in a diff,
the build now reads the field back out of the binary and refuses to assemble the app if it disagrees.

## A shortcut could carry the wrong game's icon

Which executable a game actually ran can't be guessed from its folder — Resident Evil ships three, TEKKEN 8
ships one 196 KB launcher — so Silo reads it out of the launch log's header.

It read the whole log, as strict UTF-8. A game writes its own messages in a Windows codepage, so a byte
that isn't valid UTF-8 shows up in the output sooner or later, and one is enough to make the entire read
come back empty, header and all. What followed wasn't a missing icon but a wrong one: the first executable
in the folder carrying any icon, which for Resident Evil is `CrashReport.exe`.

Only the header is read now — the first lines, which is all it ever needed — and a byte that isn't UTF-8
costs that byte and nothing else.

## Covers stop being read from disk over and over

A manual game's cover was loaded inside the view body, which means not once but on every redraw of the
grid. The grid redraws for anything the library publishes: a launch, a status message, each keystroke in
the search field. Every visible cover was re-read and re-decoded on the main thread each time.

The icon pulled out of a game's `.exe` had been cached from the start for exactly this reason. The cover —
the bigger file of the two — hadn't. Now both are read off the main thread and kept, with a key that still
notices a cover you replace.

---

Silo downloads its own Wine (built from CrossOver's FOSS source in CI) and imports Apple's GPTK from your
`.dmg`. Runs on macOS 15+ on Apple Silicon.

Gatekeeper: the build is ad-hoc signed, so right-click → **Open** on first launch, then allow it in
**System Settings → Privacy & Security** — macOS blocks the first attempt and offers the override there.
If you'd rather use the terminal, move Silo.app to Applications first, then
`xattr -dr com.apple.quarantine /Applications/Silo.app`.
