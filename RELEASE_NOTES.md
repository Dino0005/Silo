# Silo 0.6.8

Steam Input and the Steam overlay work again with the Game Porting Toolkit 4.

## Steam Input and Shift+Tab with GPTK 4.0 beta 2

With GPTK 4, Steam couldn't attach its overlay to any game. Shift+Tab did nothing, and since Steam Input relies
on the overlay, Steam never applied a game's controller configuration — a DualSense in SoulCalibur VI, for
example, ended up with scrambled buttons. GPTK 3 wasn't affected.

Silo now adjusts its own copy of one GPTK 4 file when it installs the toolkit, so the overlay can attach as it
does with GPTK 3. The fix comes from [WineForge](https://github.com/Alien4042x/WineForge) by Radim Veselý. Only
GPTK 4.0 beta 2 is changed, and the toolkit you imported is left untouched.

Nothing to do on your side: each Wine is fixed the next time you launch a game with GPTK 4. Tested with Silo's
own Wine and with a Wine imported from CrossOver — SoulCalibur VI with Steam Input, and TEKKEN 8, Spider-Man
and RESIDENT EVIL requiem with DLSS.

The first launch of a game after switching to GPTK 4 can take longer, or stay on a black screen; if it does,
quit and launch it again.
