# Silo 0.7.0

DLSS for DirectX 11 games on DXMT, God of War's lighting fixed on DXMT, and no screen saver while you play.

## DXMT: reinstall once

Both DXMT changes below need the rebuilt runtime `dxmt-v0.72-cx26.3.0`, published under the same name. To get
it, remove DXMT in *Settings → DXMT* and install it again. With the old copy, games keep running as before.

## DLSS on DXMT

With *MetalFX upscaling* on in a game's settings, a DXMT game that ships DLSS now offers it, and Silo runs it on
MetalFX's temporal upscaler — what D3DMetal already does under GPTK. Silo checks the game's folder for NVIDIA's
DLSS file and turns this on only for those games, which then see an NVIDIA graphics card. A DXMT game without DLSS
keeps what *MetalFX upscaling* did there before: a sharper upscale of the final image.

Tested on God of War with DLSS Quality: the image is comparable to D3DMetal's, and smooth once shaders are built.
FATAL FURY: City of the Wolves, which has no DLSS, keeps the upscale of the final image.

## God of War no longer dark on DXMT with FSR 2

With AMD FSR 2 on, God of War was much darker on DXMT than with FSR off or on GPTK, and darker the lower the FSR
mode. The game sets its exposure from a brightness measurement it makes on the GPU, and with FSR on it writes past
the end of one of the buffers it uses. Windows ignores that; DXMT read unrelated data instead, so the exposure came
out far too low. DXMT now behaves as Windows does for every game, and compiles God of War's shaders without fast
math. Tested with FSR Ultra Performance and Quality, and without FSR at 80 % render scale.

## No screen saver while a game runs

Playing with a controller alone, macOS saw no activity and could start the screen saver or turn the display off
during a long session. A game started from Silo now keeps the display awake for as long as it runs — even with
Silo closed, and for games started from the Games app — and lets go the moment it ends.
