# Silo 0.7.1

God of War's controller fixed on DXMT, a Wine that no longer leaks memory, and non-Steam games with Sync off
starting again.

## Wine: reinstall once

The two Wine fixes below are in the rebuilt runtime `wine-cx-26.3.0`, published under the same name. To get it,
remove Wine in *Settings → Wine* and install it again. With the old copy, games keep running as before.

## God of War: the controller no longer dies when you change DLSS on DXMT

Changing the DLSS profile in the game's menu made the selector run through the profiles by itself, and the
DualSense stopped responding until you pressed a key. The game waits for the controller on a thread of its own,
and with Silo's default sync (MSync) that thread sometimes missed being woken up, so the game kept the last button
it had seen. A fix by Gauthier Piarrette (Highball) makes Wine let a woken thread run first, as Windows does.
Tested on God of War with DXMT and DLSS: three launches, 10–15 profile changes each, no loop.

## Wine no longer grows until memory runs out

In games that wait on several things at once in a tight loop, Wine's server kept a little memory for every wait
that ended early, and grew without limit over a long session. Also a fix by Gauthier Piarrette (Highball).

## Non-Steam games with Sync off or ESync start again

A non-Steam game set to Sync *Off* or *ESync* in its settings didn't start: Silo prepared the game's icon with
MSync just before, and Wine turned the game away. Silo now prepares it with the game's own setting.
