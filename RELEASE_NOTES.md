# Silo 0.6.9

A per-game fix for God of War's white specks, ready for GPTK 4.0 beta 3, and Steam starting again after its
latest update.

## Depth fix for God of War (and similar games)

God of War (2018) shows small white specks on characters, with GPTK and with DXMT. A game's settings now have a
*Rendering* section with a **Depth fix** switch that removes them. It works with GPTK and with DXMT, for Steam and
non-Steam games, DirectX 11 only. Leave it off for other games: it is meant for the few that draw their scene
this particular way, and on others it can show things through walls. Turning it off puts everything back as it
was; your game's folder is never touched.

Tested on God of War with GPTK (FSR and DLSS) and with DXMT.

## DXMT: reinstall once

The DXMT runtime `dxmt-v0.72-cx26.3.0` was rebuilt with two fixes for those specks, under the same name. To get
it, remove DXMT in *Settings → DXMT* and install it again. Under DXMT God of War's lighting is still darker than
with GPTK — that one is still open.

## Steam stuck at startup after a Steam update

After Steam updated itself, Steam could stay without a window and never log in, while Silo's status bar said it
was open. Silo was keeping an old copy of a Steam component instead of the new one the update installed. This is
fixed, and future Steam updates are handled correctly.

If your Steam is already stuck like this, quit it from Silo's menu, then make Steam reinstall its client once:
in the Steam bottle (`~/Library/Application Support/Silo/SteamBottle/drive_c/Program Files (x86)/Steam/package`)
rename `steam_client_win64.manifest` and `steam_client_win64.installed`, then start Steam from Silo. It downloads
its client again; if the window then stays black, quit Steam from Silo and start it once more.

## GPTK 4.0 beta 3

Silo works with Apple's new GPTK 4.0 beta 3. It adds a module Wine also ships, and Silo now keeps Wine's own copy
so DXMT games aren't affected. With beta 3 the Steam overlay (Shift+Tab) and Steam Input work on their own — Apple
fixed what 0.6.8 had to work around for beta 2. Tested with TEKKEN 8 (DLSS, HDR) and SoulCalibur VI. The first
launch after switching GPTK can freeze once while shaders are rebuilt; quit and launch again.

## Also in this release

- **Play in macOS's Games app** now starts a Silo game. A game picks this up the next time you launch it from
  Silo; that first launch may open in Stage Manager instead of full screen while macOS checks the updated game
  bundle.
- **Non-Steam games no longer leave their icon in the Dock** after you quit them.
