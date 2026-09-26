# Silo 0.6.4

A small release: desktop shortcuts look right again, and Silo can install Rosetta for you.

## Shortcuts carry the game's own icon

Since 0.6.3, a shortcut made with *Create Shortcut* came out with the game's Steam cover instead of its
icon. Silo reads which executable a game ran from its launch log, and the new launch path — the one that
hands the game to its icon host — writes that line differently; the shortcut took part of it for the path
and found no program there.

The icon now also sits inside the shortcut the way it sits in the game's host app, so macOS draws it with
the same rounded shape you see in the Dock. Before, it was stamped on as a Finder custom icon, which macOS
shows exactly as it is: a Windows icon stayed square. Shortcuts made with 0.6.3 keep their old icon — create
them again to get the new one.

## Rosetta, installed from Silo

Silo's Wine is Intel software, so it needs Rosetta — and a fresh macOS install, or a major upgrade, can
leave a Mac without it. Silo already noticed that at startup and told you to run a command in Terminal. Now
it offers to install Rosetta itself, using Apple's own installer, and *Set up* does it first on a new Mac.
No password is needed.

If Rosetta goes missing while Silo is open, a game that can't start now says so, instead of reporting a
"Bad CPU type in executable".

## Built with the macOS 27 SDK

The published app is now compiled against the same SDK as the builds it's tested with.
