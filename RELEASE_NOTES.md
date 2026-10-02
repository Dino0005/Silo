# Silo 0.6.5

Silo now has a Wine of its own that's as good as CrossOver's for the games it runs — and downloads it.

## Silo's own Wine, built from CrossOver's source

Until now the better Wine was the one imported from an installed CrossOver: Silo's own build lacked the media
stack that plays in-game videos. `wine-cx-26.3.0`, what *Install the latest Wine* downloads now, closes that gap.
It's compiled from CrossOver's published source and carries CrossOver's own GStreamer, plus the decoders for the
VC-1 and WMV formats that games like Devil May Cry 5 use for their story videos. DXMT is built the same way, to
match it.

Both come from this fork's releases. Tested on Devil May Cry 5, TEKKEN 8, SoulCalibur VI, Marvel's Spider-Man
Remastered and Fatal Fury: City of the Wolves.

## Imported CrossOver Wine plays those videos too

CrossOver ships its GStreamer without those decoders. *Import Wine from CrossOver* now adds them for you: it
downloads the matching package from this fork's releases, checks it, and copies it in. Nothing of CrossOver's is
overwritten.

## DXMT games that crashed at start

Fatal Fury, and other Unreal Engine games running on DXMT, could stop with a "Fatal error!" right at start. The
copy of the runtime DXMT runs in had picked up D3DMetal's Direct3D 12 module, and these games look for Direct3D
12 even when they don't use it. The copy now gets Wine's own module back.

If a DXMT game still crashes like that, remove the Wine runtime in *Settings → Wine* and install it again once:
a runtime set up before 0.6.5 has no copy of Wine's own module to put back.

## Fewer crashes on exit, fewer surprises with Steam

- TEKKEN 8 and SoulCalibur VI no longer crash when you quit them.
- A game started while Steam is still signing in now waits for it, instead of starting without Steam.
- Steam's window no longer reloads after you close a game.

## The Steam button says what it's doing

Clicking Steam in the toolbar turns its icon into a spinner until Steam is ready, and the status bar tells you
it's starting — or that it's already open, in which case its window comes to the front.
