# Silo 0.5.6

Fixes for controls that described themselves badly, and the last of the untranslated text.

## Running something in a game's bottle

A manual game's settings had **Run Installer in this bottle…**, and the file picker asked for "a setup .exe
or .msi". It does more than that: it runs anything in the game's own bottle and waits for the window to
close. A GOG language selector, a configuration tool, a redistributable — all of them work, and none of
them is an installer.

It's now **Run a Program in this bottle…**, the picker mentions configuration tools too, and the same
action sits in the tile's ••• menu where you'd reach for it without opening settings first. The bottle is
untouched: same prefix, same executable, nothing new created. The status line at the end says **Run
finished** rather than claiming an installer completed.

The *other* Run Installer — the one on the add-game screen, which creates a bottle and then scans it for
what got installed — keeps its name. There it really is installing.

## Two controls that lied under DXMT

**Metal backend** sets `D3DM_MTL4`, a D3DMetal option. Under DXMT it does nothing, and a visible control
that does nothing offers a choice that isn't there. It now appears only when the graphics choice isn't
DXMT — Automatic still shows it, since that resolves to GPTK for most games.

The **DXMT/Direct3D 12 warning** suggests the `-d3d11` launch option among its ways out, but stayed on
screen for anyone who had already added it — recommending a remedy already taken. It now checks the launch
options first.

## Italian, the last of it

The file-picker messages and the **Choose** button were still English, sitting next to the **Annulla**
macOS supplies itself. `chooseExecutable` and `chooseDirectory` take those as plain `String`s, and a plain
string never consults the strings table.

Found by searching for every visible text passed that way rather than fixing the one that got reported —
which is how the previous four rounds of this went. The onboarding steps and the runtime sections were
already fine (they use `LocalizedStringKey`), and nothing else is left.

---

Silo downloads its own Wine (built from CrossOver's FOSS source in CI) and imports Apple's GPTK from your
`.dmg`. Runs on macOS 15+ on Apple Silicon.

Gatekeeper: the build is ad-hoc signed, so right-click → **Open** on first launch, then allow it in
**System Settings → Privacy & Security** — macOS blocks the first attempt and offers the override there.
If you'd rather use the terminal, move Silo.app to Applications first, then
`xattr -dr com.apple.quarantine /Applications/Silo.app`.
