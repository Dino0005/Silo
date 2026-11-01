# Silo 0.7.2

Surround sound without crackling, the AVX2 setting finally reaching games, and Steam games on a second drive
starting the way Steam starts them.

## Wine: reinstall once

The two Wine fixes below are in the rebuilt runtime `wine-cx-26.3.0`, published under the same name. To get them,
remove Wine in *Settings → Wine* and install it again. With the old copy, games keep running as before.

## Surround games no longer crackle on a stereo Mac

A game that plays 7.1 sound, such as UNCHARTED: Legacy of Thieves Collection, crackled on the Mac's speakers and on
AirPods, because Wine had to fold eight channels into two. Silo's Wine now carries upstream Wine's newest work on the
Mac audio driver, which mixes the extra channels down with Apple's own spatial mixer. In UNCHARTED, set the audio
output mode to *Traditional* or *Spatial*: the default, *Automatic (Traditional)*, still crackles.

## The AVX2 setting now reaches your games

A game's *AVX2* option tells Rosetta to offer AVX and AVX2 to the game, but since games run in their own app (for
their Dock icon), that app started without it, and games saw a processor without AVX at all. Games that need AVX2
refused to start or took a slower path. Silo now starts the game's app with the setting.

## Steam games on a second drive start like they do from Steam

For a game installed in another Steam library, Silo couldn't find Steam's launch settings and guessed the
executable instead, often the wrong one. It now reads them from the Steam installation, so these games start with
the same executable and arguments Steam uses.

## Games started by a launcher stay open

When a game's own launcher started the real game and quit, Silo took the game for a leftover and closed it a few
seconds later. That no longer happens, and when such a game quits, its Dock icon goes away as it should.

## Also

- A small fix in Wine's media playback (GStreamer), found by the Nectarine project.
- Games no longer hang with a transparent window when Silo was opened from Xcode's terminal.

## Known issues

- UNCHARTED crashes when you quit it from its own menu, or switch between its two games there. This is a bug in
  Apple's D3DMetal and happens in CrossOver too. Saves are not affected. Quit from Steam instead, and pick the game
  with *Executable* in its settings (`u4.exe` or `tll.exe`). If the game offers safe mode at the next start, answer
  *No*.
- The *Sync* setting has no effect on Steam games, which always use MSync.
