# Silo 0.6.6

Steam now looks like an app of its own on your Mac.

## Steam's own name and icon

Steam's window used to belong to a nameless Wine process: a Dock tile called "wine", and on macOS 27 no icon at
all, or a blank sheet, in Mission Control and Stage Manager. Silo now gives Steam's window to a small app named
**Steam**, with Steam's icon — the same way your games already get theirs. It works with Silo's own Wine and with
a Wine imported from CrossOver, in both the normal and the Media Foundation bottle.

Sometimes a second, blank "wine" tile still appears next to it: that's Steam's background process, which macOS
occasionally promotes on its own. It happens with CrossOver too.

## Steam no longer jumps in front of your game

When you start a game and Steam isn't running yet, Steam now opens behind it and the game comes to the front.
The Steam button in the toolbar still brings Steam forward.

## Reinstall Silo's Wine once

`wine-cx-26.3.0` has been rebuilt and republished. The first build came out unsigned, and that is what left Steam
without an icon. To get the new one, close Steam, remove `wine-cx-26.3.0` in *Settings → Wine* (and its DXMT copy
`wine-cx-26.3.0-dxmt`, if listed), then install it again. If you use the Media Foundation bottle, recreate it
afterwards, as after any runtime change.

## Smaller things

- While Steam starts, the Steam button plays Steam's own loading animation, read from your Steam install. The
  Steam logo in the toolbar is a little larger.
- A new app icon, made for Liquid Glass.
- Two Steam settings that Steam no longer reads have been removed. Steam starts and looks exactly as before.
