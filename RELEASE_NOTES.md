# Silo 0.7.3

A reworked Library: a filter, one alphabetical list, three layouts to choose from, and the status line on glass.

## Filter the Library

A new filter button in the toolbar shows *All*, *Steam* or *Non-Steam* games. Its icon fills in while a filter is
on, so a shorter list never looks like games went missing, and the count under the title counts what is shown.
Silo remembers your choice.

## One alphabetical list

Steam games used to come first and non-Steam games after them. Now all your games share one list, sorted by name.

## Three layouts

The same menu picks how games are shown:

- **Classic**, the default: the card you know, now with the game's whole cover. The old card cut the cover to a
  thin band, losing its top and bottom, and some titles with it.
- **Icons**: one row per game, like Apple's Games app, with the game's own app icon and a Play button. A game you
  haven't started from Silo yet shows its cover in the icon's place until its first launch.
- **Portrait**: Steam's tall library covers filling the card, with the title and Play on a glass panel at the
  bottom. Silo uses the covers Steam has already downloaded and fetches the sharper version once. Non-Steam games
  tied to a Steam app get theirs too.

A long title now shows in full when you hover over its card.

## The status line on glass

Messages like *Starting Steam…* now float over the bottom of the Library on Liquid Glass, so your covers show
through while the text stays easy to read. On macOS 15 it uses a blurred background instead.

## Also

- Silo builds with Xcode and the Command Line Tools 27.2 (from upstream). Nothing changes in the app.

## Known issues

- UNCHARTED crashes when you quit it from its own menu, or switch between its two games there. This is a bug in
  Apple's D3DMetal and happens in CrossOver too. Saves are not affected. Quit from Steam instead, and pick the game
  with *Executable* in its settings (`u4.exe` or `tll.exe`). If the game offers safe mode at the next start, answer
  *No*.
- The *Sync* setting has no effect on Steam games, which always use MSync.
