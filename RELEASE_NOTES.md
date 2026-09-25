# Silo 0.6.3

Your games finally look like themselves outside the Dock.

## Game icons in Mission Control and Stage Manager

On macOS 27, a game launched through Wine showed its icon in the Dock and a blank sheet everywhere else.
The Dock uses the icon a running app sets for itself; Mission Control and Stage Manager use the icon of the
*bundle* the window's process lives in — and a Wine process doesn't live in one.

So now it does. For each game Silo builds a small app carrying the game's name and the icon taken from its
executable, and Wine hands the game's process over to it at launch, through the alt-loader socket its own
`ntdll` already implements. The window then belongs to an app with a real identity, and every part of
macOS draws the right icon.

The host that receives the process is Silo's own, written from the protocol in Wine's open source. Nothing
from CodeWeavers is shipped or copied. If a game ever misbehaves with it, `SILO_DISABLE_ALTLOADER=1` turns
the whole thing off.

Getting there meant handling what real games do:

- **Unreal Engine launchers.** TEKKEN 8 and FATAL FURY start a small launcher that starts the real game.
  The icon now goes to the game, not to the launcher — one tile instead of two.
- **Protected executables.** Resident Evil Requiem scrambles its section names, so its icon was never found.
  Silo now locates icons the way Windows does.

## One tile, and it goes away

When a game quit, some of Wine's processes stayed behind and kept its Dock tile alive — sometimes with a
"running in the background" notice. Silo now closes them a few seconds after the game ends. Steam and Wine's
own services are never touched, and nothing is closed while another game is running in the same bottle.
*Close Leftover Game Processes*, in the Silo menu, does the same by hand.

## Game pages are complete again

Every Steam game's detail page had gone empty: no description, no requirements, no seasonal artwork. Steam
now answers its store API under a different id than the one requested, and Silo was looking for the wrong
one. Fixed.

## Smaller fixes

- After a force-quit, a game could start before Steam was ready. The stale state Steam leaves behind is now
  cleared first.
- Silo could stop responding while a game was writing a lot to its log. The watcher that reads it no longer
  runs on the main thread.
- Each game now keeps the logs of its last five launches, so a run that worked can be compared with one
  that didn't.

## Known issue

Some games using Apple's Game Porting Toolkit — seen with Marvel's Spider-Man Remastered, TEKKEN 8 and
Resident Evil Requiem — can occasionally hang at their first dialog or window change on macOS 27. The
game's own thread ends up holding a system lock that the main thread needs, inside Wine. It's intermittent,
and it isn't caused by the new icon host. If it happens, force-quit the game; if the next launch hangs too,
restart the Mac.

The icon host runs under Rosetta, like the rest of Silo's Wine.
