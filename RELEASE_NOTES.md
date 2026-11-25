# Silo 0.7.9

See how much space each game's shaders take, clear them, and find the caches games left behind when you uninstalled
them. Also: icon tiles like Apple's Games app, and a new license.

No runtime changed in this release: the Wine, DXMT and GPTK you have keep working as they are.

## Manage Caches

Games keep the shaders they compiled on your Mac, and they can take a lot of space: UNCHARTED's took about 10 GB
here. Neither Steam nor Silo removes them when a game is uninstalled.

- **Settings → General → Manage Caches…** lists every game's caches with the space they take, the biggest first,
  and a *Clear…* for each. A filter shows *All*, *Installed* or *Not installed* games: games you uninstalled are found
  by the caches they left behind.
- **In a game's settings**, *Shader cache* (at the end) shows the same for that game, one row per cache:
  - Metal's, one for launches from Silo and one for launches from Steam for macOS, with a warning when one is full;
  - D3DMetal's translation of the game's shaders, the biggest one;
  - Silo's pipeline cache, if you turn it on (below).

Clearing frees the space, and the next launch compiles the shaders again, so it loads slower and stutters for a
while. Silo refuses to clear a cache while its game runs. D3DMetal's cache is shared with CrossOver and any other app
that uses GPTK, so clearing it makes them translate the game's shaders again too.

## Silo's pipeline cache (being tested, off by default)

Metal keeps at most about 1.1 GB of shaders per game, and it never throws any away. Once a game's cache is full,
every shader that doesn't fit is compiled again at every launch.

A new switch in a game's *Shader cache* keeps the pipelines Metal had to compile in a cache of Silo's own, and uses
them at the next launch. It only keeps what Metal's cache didn't have, so it costs little while Metal's cache has
room:
- on TEKKEN 8, it kept 560 pipelines (42 MB), and fights ran as smoothly as without it;
- with Metal's cache unable to help, the intro played without stutter, and the game's compute pipelines were ready
  in 3 ms instead of 83.

It works in games started from Steam for macOS with GPTK. Try it on a game whose Metal cache shows *Full*. It is
[MacGameFix](https://github.com/MathiasKowoll/MacGameFix)'s pipeline cache, by Mathias Kowoll, adapted for Silo.

## Changed

- **Silo is now licensed under the GPL-3.0-or-later**, instead of the LGPL-2.1-or-later. The code that comes from
  upstream is carried under the GPL, as the LGPL allows; [NOTICE](NOTICE) has the details. Wine keeps its own license.
- **The library's icon tiles look like Apple's Games app.** Every icon has the same size, and the *Play* button is
  always in the same place, whatever the length of the title. The ⋯ menu moved next to *Play*, so long titles are
  no longer cut short.

## Fixed

- **A game you only start from Steam for macOS shows its own icon in the library.** Marvel's Spider-Man 2 showed
  Steam's artwork cropped to a square.
- **God of War and Batman: Arkham Knight (non-Steam) no longer show a cache for Steam for macOS**, which they never
  use.

## Known issues

- **UNCHARTED with Steam Input on:** while a button hint is on screen, the DualSense touchpad opens the game's
  settings instead of the journal. Press **J** on the keyboard, or press the touchpad again once the hint is gone.
