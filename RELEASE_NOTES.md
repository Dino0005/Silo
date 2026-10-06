# Silo 0.6.7

DLSS now works in games that ask for it through NVIDIA Streamline.

## DLSS in RESIDENT EVIL requiem, Spider-Man and others

Some games don't talk to DLSS directly: they go through NVIDIA's Streamline, which first checks the graphics
driver. In Silo that check failed, so these games offered FSR only — RESIDENT EVIL requiem and Marvel's
Spider-Man Remastered among them. The cause was a file Silo itself put in the bottle; it now sets the bottle up
the way CrossOver does, and Streamline finds the driver it expects.

Games that use DLSS directly, like TEKKEN 8 and God of War, keep working as before. Nothing to do on your side:
each bottle is repaired the next time you launch a game with the Game Porting Toolkit. Tested with Silo's own
Wine and with a Wine imported from CrossOver.
