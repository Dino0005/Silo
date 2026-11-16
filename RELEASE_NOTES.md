# Silo 0.7.4

FATAL FURY's movies without Microsoft's Media Foundation, controller and Wine fixes, Windows Steam surviving its own
updates, and a General settings page that reads like System Settings.

## Wine: reinstall once

The Wine fixes below are in the rebuilt runtime `wine-cx-26.3.0`, published under the same name. To get them,
remove Wine in *Settings → Wine* and install it again. With the old copy, games keep running as before.

## FATAL FURY plays its movies without Media Foundation

FATAL FURY: City of the Wolves skipped every movie unless it ran in the Media Foundation bottle. Wine's own H.264
decoder now offers the frame format the game asks for and turns down a Direct3D device that can't hold it, so
Unreal Engine 5's video player falls back to its software path and the movies play. You can switch *Media
Foundation* off for the game. Built on a fix from Obelisk's Wine (voile-wine, by Zagrios). SOULCALIBUR VI still
needs the Media Foundation bottle.

## Controllers

Two fixes from Proton's Wine, through Obelisk's Wine:

- A pad that is already plugged in when a game starts now reaches games that use Windows.Gaming.Input, with its
  axes in Windows' order.
- XInput keeps a controller working when you unplug it and plug it back in, and reports the same capabilities as
  Windows does.

## Three small Wine fixes

Also through Obelisk's Wine, two of them from Proton: a program that waits on its own process gets the answer
Windows gives, `GetAsyncKeyState()` no longer asks the Wine server for every key a game polls, and the memory heap
reuses its block groups instead of mapping new ones.

## Windows Steam after its own updates

When Windows Steam installs a client update, it restarts by itself, outside Silo. Its new web helper replaced the
one Silo prepares, so Steam came back as a black window until you quit it and opened it again from Silo. While a
Steam that Silo started is running, Silo now notices that restart and starts Steam again the right way; you see a
black window for a few seconds, then Steam. If you closed Silo in the meantime, opening Steam from Silo fixes it as
before.

A web helper file Silo can't read is now left alone instead of being taken for Steam's own (from upstream).

## Settings → General

Every row has a title and a short description on the left and a short button on the right, like System Settings.
The bottles' location explains what it holds and how to move it, external disks included. The Control Panel buttons
in General and in Media Foundation line up in columns of equal width.

## Also

- A game's app now declares Game Mode support outright (`LSSupportsGameMode`), as Apple recommends. Game Mode
  already turned on through the app's games category, so nothing changes in practice.
- The Library screenshot shows again in the README and on the site.

## Known issues

- UNCHARTED crashes when you quit it from its own menu, or switch between its two games there. This is a bug in
  Apple's D3DMetal and happens in CrossOver too. Saves are not affected. Quit from Steam instead, and pick the game
  with *Executable* in its settings (`u4.exe` or `tll.exe`). If the game offers safe mode at the next start, answer
  *No*.
- The *Sync* setting has no effect on Steam games, which always use MSync.
