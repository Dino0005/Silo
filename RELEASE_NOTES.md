# Silo 0.7.5

Your Windows games, played from Steam for Mac. Plus the release notes inside Silo, and Silo's own identifier.

## Wine: reinstall once

Steam for macOS needs the rebuilt runtime `wine-cx-26.3.0`, published under the same name. Remove Wine in
*Settings → Wine* and install it again. Games started from Silo keep running as before with the old copy.

## Steam for macOS

Windows games can now be played from Valve's Steam for Mac, with Silo as the compatibility layer, the way Proton
works on Linux. It's optional: Silo's own library and its Windows Steam bottle stay as they are.

To turn it on, install Steam for Mac, open it once to sign in, then go to *Settings → Steam for macOS*. Silo then:

- installs **Steam (Silo)** in your Applications folder. Open Steam from there, and keep it in the Dock instead of
  Steam's own icon. macOS asks to let *Steam (Silo)* control the Mac: switch it on in *Privacy & Security →
  Accessibility* (*Device Control and Data Access* on macOS 27), otherwise the DualSense and other pads don't work through Steam Input;
- becomes Steam's compatibility tool **Silo** for every Windows game, so *Install* and *Play* work for them. Each game
  runs in its own app, with its name and icon in the Dock and Game Mode;
- protects your installed Windows games. Steam for Mac would otherwise take them for broken and delete them; a small
  background guard checks again every time Steam quits;
- adds *Mac* and *Windows* filters to Steam's library.

Steam Cloud, the Steam overlay (Metal 4 games included), Steam Input with its Xbox virtual pad and Steam's *Stop*
button work. Games appear in macOS's Games app, and the desktop shortcuts Steam makes for them get the game's icon and
open Steam (Silo) when Steam is closed. While Steam for Mac is running, Silo never starts its Windows Steam client.

The bridge between a Windows game and Steam for Mac, `lsteamclient` and a stand-in `steam.exe`, is built from Valve's
Proton sources (BSD) together with Silo's Wine.

### Known issue: DualSense lights

A DualSense switched on while Steam is already open can lose its lights: macOS's own controller service sets them at
the same moment as Steam, and macOS often wins. Switch the pad on before opening Steam (Silo), or click Steam in the
Dock first.

## Release notes inside Silo

*Settings → General → Updates* has a *What's New…* button. With an update waiting it shows the new version's notes
before you update; otherwise those of the version you have.

## Silo has its own identifier

Silo and everything it creates move from `com.mikael.silo` to `io.github.dino0005.silo`. At the first start Silo
keeps your preferences and replaces what the earlier version left behind; game apps follow at their next launch.
Because macOS sees a new app, it asks again for any permission Silo had, and *Steam (Silo)* asks once more for
Accessibility. Desktop shortcuts made with *Create Shortcut* keep working.
