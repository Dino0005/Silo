# Silo 0.7.7

Set up a Windows game from inside Steam for macOS, install it without restarting Steam, and play Marvel's
Spider-Man 2.

## Wine: reinstall once (Spider-Man 2)

The Spider-Man 2 fix below is in the rebuilt runtime `wine-cx-26.3.0`, published under the same name. To get it,
remove Wine in *Settings → Wine* and install it again. Everything else in this release works with the copy you have.

## Silo's settings in Steam

When Silo is a game's compatibility tool, the game's *Compatibility* page in Steam for macOS now has a **Silo**
section. It holds the game's own Silo settings, with the same names as in Silo:
- the graphics backend;
- sync, AVX, the performance HUD, MetalFX, DirectX raytracing and the Metal backend;
- the depth fix and *Disable hidraw*;
- the Media Foundation bottle, when you have one.

These are the same settings Silo shows, not a copy: change one in Steam and Silo shows it, change it in Silo and Steam
does. The game starts with them either way.

Launch options stay where Steam keeps them, on the game's *General* page.

## Installing without restarting Steam

Steam for Mac greys out *Install* for a Windows-only game until the game has a compatibility tool. Silo now assigns
its own tool to every Windows-only game in your library that has none, including one you buy while Steam is open.
*Install* then works as usual, with Steam's own dialog and your choice of library. A tool you picked yourself is
left alone.

This replaces *Install with Silo*, which needed a Steam restart.

## Fixed

- **Marvel's Spider-Man 2 no longer stays on a black window** (needs the Wine reinstall). Each time a thread of the
  game first used the desktop, Wine asked the game for its Dock icon again. On the render thread that request came
  from inside D3DMetal, and Wine got stuck in an endless error loop. Wine now sets the icon once per game. Under
  Metal 4 the game then flashes white, so set its *Metal backend* to **Metal 3**, in Silo or on the Compatibility page.
  Some characters still appear in a T-pose or without a head: that is a D3DMetal limit, and a fix is planned.
- **A game bought while Steam is open is recognized right away.** Before, it was missing from the *Windows* filter,
  and its Compatibility page said it had no Windows version, until Steam was restarted.
- **The Sync setting now applies to games started from Steam for macOS.** Before, Silo always used msync for them.
- **Uninstalling a game from Steam for macOS removes what Silo made for it**:
  - the game's app, which gives it its name and icon in the Dock and the Games app;
  - its `compatdata` folder, which holds only Silo's links to your saves.

  Your saves stay in the bottle and in Steam Cloud. Nothing is removed while a Steam library's disk is unplugged.
- **Settings → Steam for macOS says when Wine has to be reinstalled.** Before, a game that needed the newer runtime
  simply didn't open.
