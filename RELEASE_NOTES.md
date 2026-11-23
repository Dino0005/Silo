# Silo 0.7.8

Marvel's Spider-Man 2 without the T-pose, UNCHARTED that quits cleanly, and game sound that follows your Mac's
output.

## Reinstall once: Wine and DXMT

Two runtimes were rebuilt and published under the same names. To get them:
- **Wine** (`wine-cx-26.3.0`, for the sound fixes below): remove Wine in *Settings → Wine* and install it again.
- **DXMT** (`dxmt-v0.72-cx26.3.0`, for the frame latency fix below): remove DXMT in *Settings → DXMT* and install it
  again.

Everything else in this release works with the copies you have.

## Marvel's Spider-Man 2: no more T-pose

On M1–M4 Macs, characters stuck in a T-pose, missing heads and a broken symbiote all came from one D3DMetal limit.
Silo now applies [macprotips' SpiderMan2Fix](https://github.com/macprotips/SpiderMan2Fix) by itself, from Silo's
library and from Steam for macOS alike:
- before each launch, Silo puts the fix in the game's folder and rebuilds its four shaders from your own copy of the
  game, so no game data ships with Silo;
- the first time, it downloads Microsoft's shader tools (6 MB) from Silo's releases;
- after a game update, it rebuilds the shaders by itself.

It is on by default, as *Spider-Man 2 fix* in the game's settings and on its *Compatibility* page in Steam. Turned
off, the game's folder goes back to how the game shipped it. Keep the game's *Metal backend* on **Metal 3**: under
Metal 4 it flashes white.

## UNCHARTED: no more crash when you quit

UNCHARTED: Legacy of Thieves Collection crashed every time you quit from its menu, and then asked to start in safe
mode. The game releases some of its textures one time too many. Silo now puts a small `d3d12.dll` of its own in the
game's folder, which keeps each texture alive a moment longer, so the extra release does no harm.

It is on by default, as *Uncharted fix* in the game's settings and on its *Compatibility* page in Steam. GPTK only.

## Sound follows your Mac's output (needs the Wine reinstall)

A game's sound used to stay on the device that was active when the game started. Taking your AirPods out left it on
the speakers, and putting them back in the case left the game silent until you restarted it. Now the sound moves
with your Mac's output, as in any Mac app. A game set to a specific device in its own options stays on that device.

The same Wine also fixes the crackle in UNCHARTED's default *Automatic (Traditional)* sound mode.

Both fixes come from Cam Steinberg's [mavrik-engine](https://github.com/camsteinberg/mavrik-engine).

## Changed

- **The depth fix is now God of War's only.** On other games it could draw things through walls, so it no longer
  shows up for every game. It appears in God of War's settings, for the Steam and the GOG version alike, and it is on
  by default there. A game that had it switched on now runs without it.

## Fixed

- **DXMT games that reset their frame latency run much faster** (needs the DXMT reinstall). Some Direct3D 11 games
  ask for the default frame latency in a way DXMT misread, so each frame waited for the previous one to finish on the
  GPU. In mavrik-engine's measurement, Civilization VI went from 38 to 97 fps. Games that don't make that request
  run as before. This fix also comes from mavrik-engine.
- **After a Silo update, Steam for macOS uses the new version right away.** Before, the part of Silo that runs
  alongside Steam kept the old version until you logged out, so a new setting could be missing from a game's
  *Compatibility* page.

## Known issues

- **UNCHARTED with Steam Input on:** while a button hint is on screen, the DualSense touchpad opens the game's
  settings instead of the journal. Press **J** on the keyboard, or press the touchpad again once the hint is gone.
