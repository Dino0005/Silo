# Silo 0.5.8

Games no longer start before Steam is ready.

## What was going wrong

Silo waits for Steam's real signal — the `ActiveProcess` pid Steam writes into the bottle's registry, the
same one `SteamAPI_Init` reads. The 25 seconds are a failsafe against a signal that never comes, not the
normal wait.

Two things were wrong with that, and the second was hidden by the first.

**The failsafe counted elapsed time.** With an update running, Steam isn't ready inside 25 seconds, so the
failsafe expired and — by design it lets the launch through rather than refusing it — the game started
against a client that wasn't there. Measured: exactly 25 seconds from the click, with Steam still
updating.

**The file watch never fired.** Wine doesn't rewrite `user.reg` in place; it writes a temporary file and
replaces the original. A kqueue watch armed on the original is left holding a file the name no longer
points at, so the signal arriving changed nothing. Measured: pid present at 00:06:35, game launched at
00:07:10 — 35 seconds during which the answer was sitting in the file.

## What changed

The failsafe now counts **idle** time: as long as Steam is doing something the countdown restarts, and
only a client that has gone quiet for 25 seconds is declared stuck.

Working out what "doing something" means took two passes. Directory timestamps move when a file is
created, not when an existing one is rewritten — good enough for a self-update, which lands fresh archives
in `package/`, and useless for a slow sign-in, which rewrites logs it already has. So Silo watches the log
files as well: `logs/` is written continuously from the first moment to the last and goes quiet exactly
when sign-in completes.

And readiness is now checked directly, not left to the watch. The pid is noticed within a second of
appearing, however Wine decides to write the file.

## Updates announce themselves

Silo already checked for a new version at startup, but only said so in **Settings → General**, which you'd
have to open on purpose. Now the library's status line mentions it when the app opens, and a mark stays on
the Settings button until you update — the line to notice, the mark to remember. No dialog: that would
interrupt every launch until you gave in, which is the fastest way to make a notice invisible.

---

Silo downloads its own Wine (built from CrossOver's FOSS source in CI) and imports Apple's GPTK from your
`.dmg`. Runs on macOS 15+ on Apple Silicon.

Gatekeeper: the build is ad-hoc signed, so right-click → **Open** on first launch, then allow it in
**System Settings → Privacy & Security** — macOS blocks the first attempt and offers the override there.
If you'd rather use the terminal, move Silo.app to Applications first, then
`xattr -dr com.apple.quarantine /Applications/Silo.app`.
