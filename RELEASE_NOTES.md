# Silo 0.7.6

Choose the Windows version of a game that also has a Mac one, keep your compiled shaders after the identifier change,
and online play for games that set IPv4 options on IPv6 sockets.

## Wine: reinstall once (online play)

The network fix below is in the rebuilt runtime `wine-cx-26.3.0`, published under the same name. To get it, remove
Wine in *Settings → Wine* and install it again. Everything else in this release works with the copy you have.

## A Compatibility page in Steam for macOS

Every game's *Properties* in Steam for Mac now have a *Compatibility* page, as on Linux, in Steam's own words: choose
**Silo** (or another installed compatibility tool) or **Default**.

For a game that has both a Mac and a Windows version, Steam installs the Mac one. Choose Silo there and Steam installs
and runs the **Windows** version instead, through Silo, with the game's settings from Silo's library; choose Default to
go back to the Mac version. Switching replaces the installed version. Tried on Rise of the Tomb Raider: Windows version
downloaded, played through Silo, Steam Cloud saves uploaded, still installed after restarting Steam.

Windows-only games keep Silo, and the page of a Mac-only game shows the choice disabled.

## Fixed

- **Games keep their compiled shaders.** macOS keeps a game's shader cache under the game's identifier, so after
  0.7.5 every game compiled its shaders again from scratch: stutters and long loads the first time through. Silo now
  moves each game's old cache to the new name, taking no extra disk space, and removes the old folders. A game that
  is running at the time is handled at its next start.
- **Online play with IPv6 game sockets** (needs the Wine reinstall). Some games open one network socket for both IPv4
  and IPv6 and set options on it that macOS refuses there, then give up: Forza Horizon 6 never finds a session that
  way. Silo's Wine now applies the matching IPv6 option instead.
- **Only one guard.** After the identifier change, the Steam for macOS guard of the earlier version could keep running
  next to the new one. Silo now stops it at every start.
