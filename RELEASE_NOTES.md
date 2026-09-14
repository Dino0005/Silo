# Silo 0.6.1

## Shortcuts can live in Applications

They still land on the Desktop by default. **Settings → General → Shortcuts** can send them to
`~/Applications/Silo/` instead, where macOS files them as games and lists them beside your native ones —
which is the only reason the option exists. The folder is created on demand.

The menu item is now just **Create Shortcut**: with two destinations, naming one of them in the label
would be wrong half the time.

## A missing Rosetta is explained, not just failed

macOS 27 arrived here without Rosetta, and the Wine Silo imports from CrossOver is Intel software, so
nothing could launch. What the status line said was:

> *…requires Steam, which failed to start: The operation couldn't be completed. Bad CPU type in
> executable.*

It blames Steam for something that isn't Steam, and "bad CPU type" tells nobody what to do. Silo now
checks at startup and says what's wrong and which command fixes it.

It can't raise the dialog CrossOver shows — that one belongs to macOS, and Apple's developer support says
there's no API for it. It fires when an Intel *application* is opened through LaunchServices; spawning a
process directly goes to the kernel and the system stays out of the way, which is exactly how `wineserver`
is started here.

The test is Rosetta's `oahd` daemon running. Measured on the same machine either side of installing it:
the files under `/usr/libexec/rosetta/` were all present *with Rosetta absent*, so their presence proves
nothing — the daemon is what differs. On an Intel Mac the check is skipped entirely.

---

Silo downloads its own Wine (built from CrossOver's FOSS source in CI) and imports Apple's GPTK from your
`.dmg`. Runs on macOS 15+ on Apple Silicon.

Gatekeeper: the build is ad-hoc signed, so right-click → **Open** on first launch, then allow it in
**System Settings → Privacy & Security** — macOS blocks the first attempt and offers the override there.
If you'd rather use the terminal, move Silo.app to Applications first, then
`xattr -dr com.apple.quarantine /Applications/Silo.app`.
