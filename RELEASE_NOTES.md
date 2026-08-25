# Silo 0.5.4

Housekeeping for what gets left behind.

## Leftover wineservers are cleared at startup

A `wineserver` that dies badly — a crash, a force-quit, a shutdown that didn't finish — leaves its
`server-*` directory in `/tmp` with the socket and lock still inside, and nothing ever removes it. Since
0.5.1 those leftovers no longer block a launch, but they pile up, and anyone opening `/tmp` to work out
what's actually running has to tell them from the real thing.

Silo now clears them when it starts: a directory whose lock nobody holds has nothing alive in it to
protect. One whose lock **is** held is left alone, even when it belongs to another prefix or to CrossOver.

Startup only, never on the way out — Silo deliberately lets a game outlive it, and sweeping at quit would
pull the socket from under one still playing.

There's a one-minute grace period, which the test suite made necessary by finding a real race: between a
server creating its directory and taking its lock there's a moment where the lock reads as free, and
sweeping then would delete the directory out from under a bottle that was starting up.

## Stopping what's running, on purpose

**Silo → Stop All Bottle Processes** ends everything running in Silo's bottles. It's there for after
something goes wrong — a crash, a force-quit — when a stray process used to mean opening a terminal. No
confirmation: it says what it does, and it's chosen deliberately.

**Quitting with something still running** now asks. The default is **Quit and Leave Running**, because a
game surviving Silo is a deliberate choice (quitting Silo to free memory mid-game is a real thing to want),
and nobody should lose a session to a stray return key. If you're done, one click closes everything.

The prompt only appears when something actually is running, so an ordinary quit is unchanged.

Both use `wineserver -k` rather than killing processes: it's Wine's own mechanism, so the session ends the
way it would on a normal shutdown. It doesn't clear `/tmp` — the startup sweep handles that on the next
launch.

---

Silo downloads its own Wine (built from CrossOver's FOSS source in CI) and imports Apple's GPTK from your
`.dmg`. Runs on macOS 15+ on Apple Silicon.

Gatekeeper: the build is ad-hoc signed, so right-click → **Open** on first launch, then allow it in
**System Settings → Privacy & Security** — macOS blocks the first attempt and offers the override there.
If you'd rather use the terminal, move Silo.app to Applications first, then
`xattr -dr com.apple.quarantine /Applications/Silo.app`.
