# Changelog

This fork's history. It starts at 0.5.0, the first release built on top of
[mikaelhug/Silo](https://github.com/mikaelhug/Silo); anything earlier belongs to upstream.

Upstream commits are integrated selectively — each one judged on its own, several deliberately left out
(DXVK is irrelevant to a library with no DirectX 9 titles). Where a port diverges from upstream's version,
the commit message says why.

## 0.6.4

### Added
- **Silo installs Rosetta itself.** When it's missing, the library and onboarding offer to install it with
  Apple's own `softwareupdate`, and *Set up* installs it first — instead of a notice sending the user to
  Terminal. A launch the kernel refuses for its CPU type now says Rosetta is missing rather than
  "Bad CPU type in executable". Ported from upstream (`83bc83b`, `55978c8`); the detection stays the fork's
  own, the running `oahd` daemon, measured across a macOS upgrade.

### Fixed
- **Desktop shortcuts carry the game's icon again, shaped like the host's.** Since the alt-loader launch the
  log records `start /wait /unix <exe>`, and the shortcut read the wrapper as part of the path, so every game
  fell back to its Steam cover. The icon also goes into the bundle now (`AppIcon.icns`), where macOS gives it
  the system's rounded shape; a Finder custom icon was drawn square.

### Changed
- **The release is built with Xcode 27 and the macOS 27 SDK**, the same SDK as local builds — it was still
  compiled on the macOS 26 image. GitHub's `xcode-27` image is still in preview; the SDK is pinned in
  `versions.env`.

## 0.6.3

### Added
- **Games show their own icon in Mission Control and Stage Manager.** On macOS 27 those two read the icon
  from the *bundle* of the process that owns a window, and a Wine process has none — so every game came up
  as a blank sheet, even though the Dock tile was right. Silo now builds a small `.app` per game carrying
  the game's name and the icon extracted from its executable, and hands the game's process to it through
  the alt-loader socket Wine's own `ntdll` already speaks (`CX_ALT_LOADER_SOCKET`). The host is ours, written
  from the protocol in Wine's source; no CodeWeavers binary is shipped or copied. A kill switch exists:
  `SILO_DISABLE_ALTLOADER=1`.
- **One Dock tile per game, and it closes when the game does.** A game's leftover Wine processes (the
  default desktop's `explorer.exe`, a crash handler) kept its tile — and a "running in the background"
  notice — alive long after it quit. Silo now closes them a few seconds after a game ends, leaving Steam and
  Wine's own services untouched and never acting while another game runs in the same bottle. *Close
  Leftover Game Processes* in the app menu does the same by hand.
- **The last five launches of each game keep their log** (`<game>.log`, `<game>.1.log` … `<game>.4.log`).
  Only the latest one used to survive, so a launch that worked couldn't be compared with one that didn't.

### Fixed
- **Every Steam game's detail sheet was empty.** Steam's store API now answers under a different id than the
  one asked for — for every game in the library — so the parser found nothing: no description, no requirements,
  no seasonal header. The entry is now matched on the `steam_appid` inside it.
- **Unreal Engine launchers took the game's place.** TEKKEN 8 and FATAL FURY start a small launcher that
  starts the real game (`…/Binaries/Win64/*-Win64-Shipping.exe`); the launcher was the one handed the
  identity, so the game ran anonymously beside a second, windowless tile. The real executable is now the
  one that gets it.
- **The alt-loader whitelist grew launch after launch.** A registry import merges, so every exe ever
  launched stayed listed — which is how TEKKEN 8's launcher kept taking the host after the fix above. The
  key is now deleted and rewritten on each launch.
- **Resident Evil Requiem had no icon.** Its executable is protected and its section names are scrambled; the
  icon resources sit in a section called `.rdata`, and the extractor looked for `.rsrc` by name. It now
  follows the executable's resource directory, as Windows does.
- **After a force-quit, a game could start before Steam.** A killed Steam leaves its `ActiveProcess` pid in
  the bottle's registry, and the readiness check read that stale pid as "Steam is up". It is cleared before
  Steam starts on a bottle that isn't running.
- **Silo could freeze while a game was logging heavily.** The graphics-fallback watcher re-scanned the game's
  log on the main thread for every single write; a game logging continuously queued scans faster than they
  ran. The scan now runs off the main thread, at most every 250 ms, and still catches a line written last.

### Changed
- **The app build fails if the alt-loader host is missing or wrong** (not x86_64, or without the reserved
  memory segment Wine needs) instead of warning and shipping without it — a feature that switches itself off
  silently is worse than a build that stops.

### Known issues
- **Some GPTK games can hang at their first dialog or window change** (seen with Marvel's Spider-Man
  Remastered, TEKKEN 8 and Resident Evil Requiem on macOS 27): the game's own thread holds Core Animation's
  transaction lock while waiting on Wine, and the main thread waits on that lock. It is intermittent, and it
  has hung a game process that was not the icon host, so the host is not the cause. If it happens, force-quit the game;
  if the next launch hangs as well, restart the Mac.

## 0.6.2

### Fixed
- **The window was drawn as an old app.** Silo's toolbar came up as loose icons with no shared glass
  background, next to a bordered search field — the appearance macOS gives an app built before Liquid
  Glass. Nothing in the toolbar code was wrong: it was never consulted. The binary's `LC_BUILD_VERSION`
  read `sdk 15.0`, because SwiftPM writes the deployment target into *both* of its fields, and that `sdk`
  field is what AppKit reads to decide between the current design and the compatibility appearance. So an
  app compiled against the macOS 27 SDK declared itself built against the 15. macOS 26 restyled old-SDK
  apps regardless; 27 doesn't, which is why the look changed with no code change behind it. The link step
  now records the real SDK, and the build **fails** if that field ever comes out wrong again — the symptom
  is invisible in a diff.
- **A shortcut could take the wrong game's icon.** The executable that actually ran is read from the launch
  log's header, but the whole file was read as strict UTF-8 — and a game writes its own messages in a
  Windows codepage, so a byte that isn't valid UTF-8 turns up in the output sooner or later. One of them
  made the entire read return nothing, header included, and the icon fell back to guessing: the first
  executable in the game's folder carrying one, which for Resident Evil is `CrashReport.exe`. Only the
  header is read now, and a byte that isn't UTF-8 costs that byte.
- **A game's cover was re-read from disk on every redraw.** It was loaded inside the view body, so the
  grid re-read and re-decoded every visible cover on the main thread for anything the library published —
  a keystroke in the search field included. The `.exe` icon had been cached for exactly this reason; the
  cover, the larger file of the two, hadn't. Both are now loaded off the main thread and cached, keyed so
  that replacing a cover still reloads it.

## 0.6.1

### Added
- **A choice of where shortcuts are created** — Desktop as before, or `~/Applications/Silo/`, where macOS
  files them as games and lists them with native ones. *Settings → General → Shortcuts*; the folder is
  created on demand, and the menu item drops "Desktop" from its name since it no longer names the only
  destination.
- **A missing Rosetta is reported at startup.** Silo's Wine is Intel software, so without translation
  nothing launches — and the failure surfaced as "requires Steam… Bad CPU type in executable", which
  blames the wrong thing and suggests no remedy. The check is Rosetta's `oahd` daemon running; the files
  under `/usr/libexec/rosetta/` are all present even when Rosetta isn't, so they prove nothing. Skipped on
  Intel Macs. macOS's own install prompt can't be raised from an app — Apple's developer support says
  there's no API — because it fires on a LaunchServices open, not on spawning a process.

## 0.6.0

### Added
- **A shortcut icon of your own.** A PNG at `Covers/<Steam app ID>_icon.png` — or, for a non-Steam game,
  named after its cover file the same way — is used ahead of everything else, verbatim: no crop, no mask,
  transparency intact. Leave the margin yourself (artwork over ~82% of the canvas). In `Covers/` rather
  than `Artwork/`, which is a cache Silo may empty.

### Changed
- **Shortcut icons take macOS's rounded-square shape** instead of filling their tile, which read as
  foreign next to the system's own. Rectangular sources are cropped to their centre rather than squashed —
  header art is 460×215, and stretching it distorted the artwork. Applied in the one place every icon
  passes through, so none escapes it.

## 0.5.9

### Fixed
- **`PEIcon` never extracted an icon.** A PE's resource tree is three directories deep (type → name →
  language) and the parser walked four, asking for a sub-directory of entries that address data — nil for
  every executable. Manual games without cover art showed the generic controller instead of their own
  icon. The tests missed it because their synthetic executable carried the same extra level; a new test
  runs against a real game `.exe` (`SILO_TEST_EXE`, skipped when unset).
- **A controller was drawn under the game's icon.** `GameArtworkPlaceholder` draws that glyph itself, so
  the tile showed both at once — invisible while icons never appeared.
- **The biggest icon was chosen by byte size.** A PNG-stored 256×256 is lighter than an uncompressed
  128×128 (25,714 vs 67,646 bytes on one game), so the heaviest entry was the smaller image. Now chosen by
  pixels, with bytes breaking ties.
- **The test suite broke CrossOver.** It created `.wine-<uid>` in the real `TMPDIR` with default
  permissions; Wine requires 0700, and CrossOver — sharing that directory — then failed to lock and
  aborted at launch.

### Changed
- **A Steam game's shortcut carries the game's icon** rather than the header art squashed into a square.
  The executable comes from the launch log (which names the one that ran), then from the game folder, then
  falls back to the cover — read from the `Artwork/` cache before the network, since the cover URL is
  guessed from the app ID and 404s for some titles.

## 0.5.8

### Fixed
- **A game could start before Steam was ready.** The readiness failsafe counted elapsed time, so an update
  in progress ran past it and the launch went ahead against a client that wasn't there — measured at
  exactly 25 s from the click. It now counts *idle* time: the countdown restarts whenever Steam touches
  its own files, and only a genuinely quiet client expires it. Activity is read from `package/` (created
  files, as a self-update produces) and from the log files (rewrites, as a slow sign-in produces) — the
  first pass used directory timestamps alone and missed the second case entirely.
- **The watch on `user.reg` never fired.** Wine replaces the registry file rather than rewriting it, so a
  kqueue watch held a vnode the name no longer pointed at. Readiness was only ever ended by the failsafe —
  measured: pid present at 00:06:35, launch at 00:07:10. Readiness is now also checked in the polling
  loop, and the gap is down to a second or two.

### Added
- **An available update is announced at startup** — in the library's status line, plus a mark on the
  Settings button that stays until you update. The check already ran; its result was only visible in
  Settings.

## 0.5.7

### Added
- **Run Program…** on a non-Steam game's card, in the toolbar slot the Steam card uses for *Store*. It was
  already in the settings sheet and the tile menu; the card is what a click on the tile opens.

### Fixed
- **`DYLD_LIBRARY_PATH` is stripped from the environment wine processes get.** Silo deliberately keeps
  `/usr/local/lib` out of `DYLD_FALLBACK_LIBRARY_PATH` — Homebrew's gtk3 and gtk4 both loading once killed
  `winegstreamer` with "Class … is implemented in both" — but dyld reads `DYLD_LIBRARY_PATH` ahead of the
  system paths, so an inherited one overrode that protection entirely. Silo never sets it, so removing it
  costs nothing. Unlikely from a Finder launch, possible from a terminal.

## 0.5.6

### Changed
- **"Run Installer in this bottle…" is now "Run a Program in this bottle…"**, and appears in the tile's
  ••• menu as well. It always ran anything in the game's existing bottle — verified with a GOG language
  selector: same prefix, same executable, nothing new created — but its name and the picker's wording
  both suggested installers only. The completion status now reads "Run finished". The add-game screen's
  *Run Installer* keeps its name; there it really does install.
- **The Metal backend picker is hidden when the graphics choice is DXMT.** It sets `D3DM_MTL4`, a
  D3DMetal option that does nothing there. Automatic still shows it, since it resolves to GPTK for most
  games.

### Fixed
- **The DXMT/D3D12 warning no longer appears when `-d3d11` is already among the launch options** — it was
  recommending a remedy the user had already applied.
- **File-picker messages and the Choose button weren't translated.** `chooseExecutable` and
  `chooseDirectory` take them as plain `String`s, which never reach the strings table. All five messages
  and the button are localised; a search for every visible text passed that way confirms none is left.

## 0.5.5

### Fixed
- **The startup sweep removed CrossOver's leftover directories too.** `server-*` directories belong to
  whichever prefix made them, and 0.5.4's sweep judged them only by whether their lock was free. Measured
  with both apps installed: seven in `/tmp`, six of them CrossOver's, all gone after opening Silo. Silo
  now computes the names its own bottles would produce — from each prefix's device and inode — and
  ignores everything else. The leftover of a deleted bottle now stays, since without the prefix its name
  can't be derived.
- **The Media Foundation bottle wasn't in the list of bottles.** A game running there was invisible to
  both *Stop All Bottle Processes* and the quit prompt.

## 0.5.4

### Added
- **Silo → Stop All Bottle Processes**, for when a crash or a force-quit leaves something running and the
  only remedy was a terminal. Acts immediately — it's explicit, and chosen on purpose.
- **Quitting with something still running asks what to do**, defaulting to leaving it running: a game
  outliving Silo is deliberate, and the case it protects (quitting to free memory mid-game) is real. The
  prompt only appears when something is actually running.
- Both stop bottles with `wineserver -k` rather than killing processes, so the session ends the way it
  would on a normal shutdown instead of being cut off mid-write.

### Fixed
- **Leftover `server-*` directories are cleared at startup.** A wineserver that dies badly leaves one in
  `/tmp` and nothing removes it; they no longer block launches but they accumulate and make it impossible
  to tell, by looking, what's really running. A directory whose lock nobody holds is removed; one whose
  lock is held is left alone, whoever owns it. Startup only — sweeping at quit would pull the socket from
  under a game Silo deliberately let outlive it.
- The sweep waits a minute before touching anything, closing a race the tests surfaced: between creating
  its directory and taking its lock, a starting server's lock reads as free.

## 0.5.3

### Fixed
- **Tile artwork is cached on disk**, in `Artwork/` by app ID. The tile used to guess its image URL from
  the app ID and fetch it every time, so the library came up blank with no network — images are evicted
  from URLSession's cache long before JSON is. The stored file draws first and is refreshed behind it, at
  most once a day, and a failed refresh leaves the existing image alone.
- **Games whose `header.jpg` doesn't exist now get artwork.** The guessed address 404s for some apps
  (seen on 3764200) while their store page has an image; when it fails, Silo asks the API for the real
  `header_image` — one request, only for those games, and the result is stored.
- The Steam card falls back to the cached file when the network is gone. Its description and metadata
  still require a connection.
- **Settings-pane status messages were never translated.** Wine, GPTK, DXMT, Media Foundation and Backend
  answered in English whenever the message carried a name — "Removed wine cx 26.3.0.", "Installed …" —
  because an interpolated string can't match a fixed catalogue key. Twenty-two now resolve. Four were
  written across two lines and escaped the first pass, which searched for a single spelling.
- Corrected the 0.5.2 notes: the subtitle read "the games Steam doesn't know about", which is the reverse
  of how the game card works — it exists precisely because Steam does know them.

## 0.5.2

### Added
- **A game card for non-Steam games.** Point a manual game at the matching Steam app ID (Settings → Game
  card) and its tile opens a card with hero art, description, developer, genres and release date instead
  of the settings sheet. No Store button — the copy in play wasn't bought there — and the destructive
  action is Remove rather than Uninstall, which is what it actually does. With no association the tile
  behaves exactly as before, and removing one restores that.
- When a manual game has no cover, the association downloads Steam's artwork into `Covers/`, so the tile
  draws without a network. A chosen cover is never replaced, and removing the card keeps it.

### Fixed
- **Status messages carrying a game's name were never translated.** "Launched God of War.", "Added …",
  "Removed …" and twenty-two others interpolate a name, so the runtime string could never match a fixed
  catalogue key — the same defect fixed for error messages earlier. One of them was also split across a
  `+`, which would have put half the sentence in the key.
- Reworded the bottle-switch message: it told you to close the game running in the other bottle, when
  what's usually running there is Steam alone.

## 0.5.1

### Fixed
- **Silo installed one GPTK and ran another.** On a CrossOver-derived runtime the overlay wrote to `lib/`,
  but CrossOver's wine loads D3DMetal from `lib64/apple_gptk` — left untouched, so the runtime kept
  executing the GPTK CrossOver shipped. Measured: GPTK 4.0 beta 2 selected, Tekken 8's HUD reporting
  "Game Porting Toolkit 3.0", `lib/external/D3DMetal` at 7,578,032 bytes against 5,263,744 in
  `lib64/apple_gptk/external`. This is what made the "AMD graphics driver" warning appear, the Metal 3 /
  Metal 4 selector inert, and the GPTK choice in Settings ineffective. The overlay now covers that tree
  too, with its own idempotency check, running before the `lib/` early-return so an already-overlaid
  runtime is repaired instead of skipped.
- **DXMT no longer leaves GPTK's NVIDIA shims resolvable.** `nvapi64`/`nvngx` stay in the runtime tree
  after a GPTK overlay, so under DXMT — which has no D3DMetal behind them — a game could half-bind an
  NVIDIA adapter that isn't there. They're now explicitly disabled for that backend.

### Added
- GPTK's NVIDIA shims are seeded into the game prefix, so they resolve by name on a runtime that doesn't
  ship them (a wine built from source). A no-op on a CrossOver-derived runtime, which carries them already.

The last two are ports of upstream's `aec535a`, itself credited to this fork for the three controls it
re-implements.

### Note
With GPTK 4 genuinely in play, DLSS is unavailable — a GPTK 4 limitation, not a regression here. It had
been working only because GPTK 3 was still the one running. Selecting GPTK 3 restores it.

## 0.5.0

Media Foundation video playback in a second bottle, saves shared between the two, and a setup that tells
the truth about what it did.

### Added
- **Media Foundation support.** Windows' real MF DLLs (user-supplied, from a licensed install) applied to
  a separate `SteamBottleMF` bottle cloned from the Steam one — separate because the configuration that
  fixes Soulcalibur VI stops DMC5 and Mortal Kombat 1 from starting. Per-game toggle, with the Steam
  client switched to match.
- **Shared save folders** between the two bottles: a picker at toggle time, symlinks into the canonical
  bottle, and removal when a folder is unticked. Identical copies are linked silently; divergent ones are
  flagged and never merged.
- **Cover art for non-Steam games**, copied into `Covers/` so an image from an external drive survives
  that drive being unplugged.
- **Metal 3 / Metal 4 selector** for GPTK's D3D12 path (ported from upstream).
- Backend badge on Steam games' tiles, and a direct shortcut to Wine's Game Controllers panel.
- Italian + English localization across the whole UI, error messages included.
- **Import Wine and DXMT from an installed CrossOver**, from the app: offered during onboarding, and
  available afterwards from Settings → Wine and → DXMT (e.g. after a CrossOver update). DXMT is installed
  as a runtime of its own, since the copy inside CrossOver's Wine tree isn't where detection looks.

### Fixed
- **Fullscreen on GPTK.** Steam's Wine virtual desktop was hardcoded to 1440×900, capping every game
  regardless of the resolution it asked for. It's now sized to the screen's native resolution.
- **GPU vendor identity** for DLSS→MetalFX: `nvngx-on-metalfx` renamed to `nvngx`, plus the builtin
  override.
- **`d3dcompiler_47` was never installed** — the extraction command exited 0 without writing a file.
  Replaced with a native CAB reader (ported from upstream).
- **Half-provisioned bottles reported as success.** Failed components are now named; Core Fonts counts as
  satisfied only when all eleven land, not when the second one does.
- **An interrupted `wineboot` looked like a booted prefix**, making every later setup build on a half-
  booted bottle. Recorded only once it completes.
- **A deleted runtime left the readiness gates green**, because the persisted path was never cleared.
- **Crash-leftover extraction directories** were listed and selectable as installed runtimes.
- **Release search didn't paginate**, so a runtime tag would eventually sink under the app's own releases
  and onboarding would report nothing published.
- **A missing `.sha256` sidecar threw away a completed download** on the first transient failure; it now
  gets one retry, while a 404 stays conclusive.
- **Wrong-`.dmg` GPTK imports** were published and reported as successful while `installed()` found
  nothing.
- The default DLL override set is versioned by content, so a change reaches bottles already set up.
- Guided setup adopts an installed runtime instead of downloading a second one.
- "Open Steam" no longer starts a second client when one is already running in the other bottle.
- A manual game on an unplugged drive is hidden rather than offering a Play button that can only fail.
- MSync isolation for non-Steam bottles; external-drive Steam library discovery; `CX_ROOT`,
  `CX_APPLEGPTK_LIBD3DSHARED_PATH` and GStreamer environment for CrossOver-derived runtimes (which
  unblocked Tekken 8 launching at all); two DXMT detection bugs.
- **The app crashed on opening the library on any Mac but the one that built it.** SwiftPM's generated
  `Bundle.module` accessor resolves the resource bundle beside the .app and then at the absolute build
  path of whoever compiled — neither exists in a shipped app, and it traps rather than returning nil. The
  Steam toolbar icon is loaded by path now, and `build-app.sh` also copies SiloKit's resources flat into
  `Contents/Resources` where `Bundle.main` finds them.
- **A crashed bottle stayed "busy" forever.** Liveness was `fileExists` on the wineserver socket, but the
  files in `/tmp` outlive the process — so after a `kill -9`, a crash or an incomplete shutdown every
  launch was silently refused. It's now `fcntl(F_GETLK)` on the server's lock: who holds it, asked without
  taking it.
- **Setup left a Steam client running.** The shutdown terminated only the tracked pid, but the updater
  re-execs a client Silo didn't spawn; two `steam.exe` and a `wineserver` survived a clean onboarding.
- Developer ID signing.

### Changed
- Error types conform to `LocalizedError`, so a first run's failures read as sentences rather than
  `The operation couldn't be completed. (SiloKit.… error 4.)`.
- Steam readiness failsafe tuned to 25 s against a measured cold start.
- `updateRepo` points at this fork; `wineRepo` stays upstream.
