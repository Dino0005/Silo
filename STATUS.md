# STATUS.md — Silo live ledger

> Updated every iteration. `CLAUDE.md` is the contract; this is the state.

## Now
- **🖼️ Wine windows show a generic icon in Mission Control / Stage Manager on macOS 27 — diagnosed on
  device, and the route CrossOver uses is now identified: an `--enable-alt-loader` bundled host app that
  OWNS the macOS window (2026-09-17/18, `main`; investigation only, no code changed).** User report: on
  macOS 26 a Silo-launched Steam/game window carried its icon in the Dock *and* in Stage Manager/Mission
  Control; on 27 the Dock is still right but those two surfaces draw a blank/generic icon. Measured, not
  inferred — throwaway probes under `~/Library/Application Support/Silo/_IconTest` and `/tmp/siloprobe`,
  both since removed (real runtime, bottle and repo untouched).
  - ⚠️ **This entry supersedes the first version of itself (commit `fb0e0b6`), which called the `.app`
    wrapper "structurally impossible". That was too strong and is retracted** — see "How CrossOver does it"
    below. What IS closed is putting the *wine loader* inside a bundle; the window-owning process never has
    to be the loader at all.
  - **Mechanism (confirmed).** The Dock tile icon is set at **runtime** by `winemac.drv`, which converts the
    window's `HICON` and calls `-[NSApp setApplicationIconImage:]` (verified: `setApplicationIconImage:`,
    `applicationIconImage`, `dockTile`, `_NSImageNameApplicationIcon` in `lib/wine/x86_64-unix/winemac.so`).
    That icon lives only in the process — the runtime tree contains **no `Info.plist` at all**, so Wine
    processes have no bundle and no LaunchServices identity. macOS 27 resolves the Mission Control /
    Stage Manager badge from the **bundle** icon instead of that runtime image; macOS 26 still honoured the
    runtime image. Silo's own launch measures exactly the bug: `bundleIdentifier = nil`, icon `==` the
    generic "exec" icon.
  - **Proof by paired control processes.** Two minimal AppKit binaries launched side by side: (A) no bundle +
    `setApplicationIconImage` (red icon) → Dock tile **red**, Mission Control **generic**; (B) inside a
    `.app` with an `.icns`, no runtime icon → correct icon in **both**. User confirmed both on screen.
  - **Reusable oracle:** `NSRunningApplication(processIdentifier:).icon` tracks what Mission Control draws
    (generic for A, real for B). Future checks of this need no human looking at the screen.
  - **Why putting the LOADER in a bundle cannot work (the real reason `DockAppBundle` failed; the
    2026-07-13 note was misattributed).** Silo spawns `bin/wine64` (symlink → `bin/wineloader`), but the
    process that owns the
    window is a **third file wine chooses itself**: `<root>/lib/wine/x86_64-unix/wine`. `WINELOADER` — which
    `ntdll.so` does read — is **ignored** there (measured: the process stays on the canonical path). Moving
    that file or its directory into a bundle breaks wine in cascade, because the loader `realpath`s itself
    and derives everything relative to the resolved path. Four failures, each measured in turn:
    `dlopen(<loaderdir>/ntdll.so)` → "no such file"; the Windows module dir derived from its own dir's
    **name** (`x86_64-unix` → `x86_64-windows`), so a dir renamed `MacOS` yields
    `failed to load <MacOS>/ntdll.dll  c0000135`; three fatal `read_nls_file failed` for
    `<loaderdir>/../../share/wine/nls`; and `could not exec wineserver`. `Contents/MacOS` can't be named
    `x86_64-unix`, so symlinks can't paper over it. **Do not re-propose this.**
  - **Two ways to give a bundle-less process a full bundle identity — both measured working, neither
    reaches Wine.** (1) `exec` in-place from a LaunchServices-launched `.app`: the PID keeps
    `bundleIdentifier` + icon even after its image is replaced by a bundle-less binary (works with a
    shell-script stub too). (2) The **`CFProcessPath`** env var: a bundle-less binary spawned completely
    normally reports the `bundleIdentifier`/`bundleURL`/icon of the `.app` it points at, with no
    LaunchServices involvement. Against real Wine both fail, and the reason is the fork: Wine's
    window-owning process is a fresh child (`PPID 1`, reparented), and LS identity does **not** cross
    `fork+exec` (verified: a bundled host that spawns a child → child `bundleIdentifier = nil`). With
    `CFProcessPath` (and `__CFBundleIdentifier`) in the launch env the notepad window process still reports
    `nil`, even though `CFProcessPath` **is** propagated into the Windows environment (proved with
    `wine cmd /c set`) — so it survives the Wine boundary but CoreFoundation in that process doesn't act on
    it. Root cause still open; that process's unix env is unreadable on macOS (`ps eww` empty,
    `start /unix` absent from this build). `WINELOADERNOEXEC=1`, to suppress the re-exec, stops Wine
    starting at all.
  - **How CrossOver does it — measured live on its running Steam (the user's macOS-27 screenshot showed
    Steam WITH its icon in Stage Manager and only the game without).** `cxmenu` generates a **resident
    Cocoa `.app` per bottle application** — `~/Applications/CrossOver/Steam/Steam (<bottle>).app`, executable
    `Menu Helper`, `LSBackgroundOnly = false`, a MainMenu nib, and `CrossOverHelper.icns` holding the
    **extracted Windows icon** (confirmed: that file *is* the Steam logo, matching the badge in the
    screenshot). It links only Cocoa/Foundation/AppKit/CoreFoundation/CoreServices — no Wine. Live process
    tree: `Menu Helper` (pid 99108) stays alive with child
    `winewrapper.exe **--enable-alt-loader** …`, while `steam.exe`/`explorer.exe`/`steamwebhelper.exe` are
    ordinary bundle-less Wine processes measuring `bundleIdentifier = nil` + generic icon **exactly like
    Silo's**. The decisive measurement is `CGWindowListCopyWindowInfo`: the on-screen window titled "Steam"
    is owned by **pid 99108, the bundled `Menu Helper`** — and *no* on-screen window belongs to any Wine pid
    (`steam.exe` does hold 5 windows, all untitled and none on screen). So CrossOver's icon is right
    because **a properly bundled app owns the macOS window**, not because its Wine processes have an
    identity. Corollary: this also explains CrossOver's correct Dock tile name and its native menu bar. And
    the earlier "CrossOver has the same limitation on 27" claim in this entry was **wrong** — it only looks
    that way for an app with no `cxmenu` launcher (the game, started from inside Steam).
  - **Correction ×2 (2026-09-19). The alt-loader machinery is NOT in the FOSS source — but it IS in a
    CrossOver-imported runtime, and that import is a supported feature, not a dev hack.**
    - Downloaded and checked `crossover-sources-26.3.0.tar.gz`, the drop `build-wine.sh` compiles:
      **zero** `CX_ALT_LOADER_SOCKET`/`send_to_cx_loader` in `dlls/ntdll/unix/loader.c`, no `winewrapper`
      among its 50,394 files, exactly ONE CrossOver hook in that file (`CX_APPLEGPTK_LIBD3DSHARED_PATH`).
      ⚠️ **But the conclusion drawn from that was WRONG (corrected 2026-09-20).** Only `loader.c` had been
      grepped. Searching the **whole** tarball finds the alt loader alive and well in
      `dlls/ntdll/unix/process.c`: `send_to_cx_loader()` (line ~296) reads `CX_ALT_LOADER_SOCKET`, connects
      to that `sockaddr_un`, hands over the process params **and file descriptors** (wineserver socket,
      stdin, stdout) via `sendmsg`/`SCM_RIGHTS`, reads back a `uint32_t`, and is gated per-exe by
      `HKCU\Software\CrossOver\SuppressAltLoader` plus a whitelist key. Consequences, all in our favour:
      the protocol is **open, readable C — not reverse-engineering**; it is compiled into BOTH runtime
      kinds; and a host **we** write needs no CodeWeavers binary, so unlike the `Menu Helper` route it is
      actually shippable. Only `winewrapper` is missing from the source, and the ntdll path above does not
      appear to need it (it is called straight from process creation, line ~862).
    - But it was ALSO wrong to call the CrossOver-derived runtime a local-testing artefact (user,
      2026-09-19): `CrossOverWineImporter` is a shipped feature — Settings → Wine → "Import Wine from
      CrossOver <ver>", offered whenever CrossOver is installed, the Swift port of
      `install-local-crossover-wine.sh` precisely "so it works from the shipped app". It exists because
      **CrossOver's Wine is better in practice** (GStreamer with its plugin dir, which
      `bundle-wine-dylibs.sh` deliberately can't bundle; plus `lib64/apple_gptk`), and the user — who holds
      a CrossOver licence — reports the from-source build has real defects and limitations. Constraint #8
      governs the build base, not what the user imports; CLAUDE.md now says so explicitly.
    - **Consequence: the two runtime kinds need two different answers, and today's patch serves the one the
      user does NOT run.** A CrossOver-imported runtime is prebuilt, so it ignores `SILO_LOADER_LINK_DIR`.
      For it, the route is the alt loader it already carries — cost is reverse-engineering undocumented
      binary IPC with fd passing (`sockaddr_un`, `sendmsg`/`recvmsg`/`socketpair`, `send_to_cx_loader` in
      `ntdll.so`; `winewrapper.exe --enable-alt-loader` reads `CX_BOTTLE`/`CX_ROOT`). A cheaper untested
      alternative: generate a bundle carrying a copy of the user's own licensed `Menu Helper` plus the
      plist keys it reads (`CrossOverHelperCommand`, `CXHelperAppBottleName`, `CXHelperAppBottleTag`) —
      risk being that it expects a real CrossOver bottle, which Silo's prefixes are not.
  - **✅ HANDSHAKE PROVEN WITH OUR OWN HOST (2026-09-20) — this is now the main route.** Wrote a ~60-line
    C receiver straight from the FOSS source (no CodeWeavers binary anywhere), pointed
    `CX_ALT_LOADER_SOCKET` at it, and launched the CrossOver-imported runtime normally. It received:
    `request_type = 0x52c17355` (**exactly** `REQUEST_LOAD_WINE`), **1878 bytes** of payload, **4 file
    descriptors**, and Wine accepted our `uint32_t` reply. So Silo can talk this protocol itself.
    - **The wire format**, read off `dlls/ntdll/unix/process.c` (`send_to_cx_loader`, ~line 296) — client
      is Wine, server is us, `AF_UNIX`/`SOCK_STREAM`:
      1. `uint32_t` request type = `REQUEST_LOAD_WINE` = `0x52c17355` (enum at line 93)
      2. length-prefixed working directory (`write_length_prefixed_buffer`)
      3. the environment (`write_env`, line 236 — takes the PE env + `winedebug`)
      4. `uint64_t` total length of `argv[1..]`, then each argument NUL-terminated
      5. `sendmsg` of a 1-byte payload carrying **SCM_RIGHTS**: stdin, stdout, stderr, the **wineserver
         socket**, and optionally `WINE_WAIT_CHILD_PIPE` (4 fds measured, 5 when that env var is set)
      6. `shutdown(SHUT_WR)`, then the client blocks reading a `uint32_t` response
    - **Gates, and why nothing had to be configured:** `HKCU\Software\CrossOver\UseAltLoader` (whitelist by
      exe base name) and `…\SuppressAltLoader` (blacklist). When neither key exists — as in a Silo prefix —
      `has_key_value` reports "no key" and the send proceeds. There is also a hardcoded skip for Rockstar's
      `Launcher.exe`. `CX_ALT_LOADER_SOCKET` is `unsetenv`'d after being read, so it does not leak to
      children.
    - **What is proven vs. what is not.** Proven: the connection, the request type, the payload and the fd
      passing, with a host of ours. **Not yet:** actually *hosting* the process — the receiver must load
      Wine in-process and run the program on those descriptors, and the meaning of the `uint32_t` reply is
      still unread. That is the real work, and it is ordinary implementation against readable source.
    - **Why this looked like it supersedes the other routes:** it needs no Wine patch (so it serves the
      **CrossOver-imported** runtime the user actually runs), no `Menu Helper` (so it clears the licence
      boundary and could ship), and no turning Silo prefixes into CrossOver bottles. **But see the next
      bullet before relying on that: owning the window is not, by itself, enough.**
  - **✅✅ RESOLVED (2026-09-20, user-confirmed on screen): a bundle of OURS owns the window AND supplies
    the Stage Manager icon.** The blank sheet below was an artefact — `cxmenu` **deletes** foreign bundles
    from `~/Applications/CrossOver/Steam/`, and ours had been removed mid-test, so LaunchServices had no
    icon left to read. Repeating the test with the bundle at `~/Applications/SiloIconTest.app` (outside
    CrossOver's managed folder), unique `CFBundleIdentifier`, Silo's `.icns` in place of
    `CrossOverHelper.icns`: the bundle survives the run, the on-screen "Steam" window is owned by
    **pid 6729 / `SiloIconTest` / `com.mikael.silo.icontest2`**, and its icon dumps as **Silo's own icon**.
    The user then confirmed by eye: *"in Stage Manager c'è Steam con l'icona di Silo"*.
    - **So the full chain is proven end to end**: our bundle → owns the Wine app's macOS window → carries
      our icon into Stage Manager / Mission Control. Combined with the alt-loader handshake above (also
      ours, no CodeWeavers binary), the route is viable for the **CrossOver-imported runtime**, with no
      Wine patch and no Silo prefix turning into a CrossOver bottle.
    - **Three lessons to keep:** (1) never place a generated bundle under `~/Applications/CrossOver/` — it
      gets deleted; (2) the icon probe must compare against the **document** generic too, not only
      `.unixExecutable` — the first version reported "SPECIFICA" for what was plainly a blank sheet;
      (3) **tear down in order: terminate → VERIFY the processes are gone → only then delete the bundle
      and its LaunchServices registration.** Doing it the other way round left `SiloIconTest` showing as
      "in esecuzione in background" in the Dock with its bundle already deleted (a ghost tile, cleared by
      `killall Dock`), and the "cleanup verified" claim that accompanied it was worthless: the `pkill` and
      the `pgrep` check ran in the same command, so nothing had actually been confirmed.
    - **New loose end (user, same run):** the Dock showed *Steam's* icon under the name **"wine"**, i.e. a
      SECOND tile belonging to the Wine process itself, alongside our host app's. CrossOver evidently
      suppresses one of the two; how, is unknown. Cosmetic, but it needs answering before this ships.
    - **✅ ANSWERED (2026-09-21): the receiver doesn't *host* the Wine process — it BECOMES it, in
      process, via `dlopen`.** Measured with `lsof` on a live `Menu Helper` (pid 9918) while it owned
      Steam's window: it has mapped `lib/wine/x86_64-unix/`**`ntdll.so`**, **`winemac.so`** (hence the
      window is its own), `win32u.so`, `winecoreaudio.so`, `bcrypt/crypt32/secur32/ws2_32/…`, the
      `x86_64-windows/*.dll` set, an `ntdll.so.aot` (Rosetta AOT cache) and **137** handles under the
      wineserver's `/tmp/.wine-501/server-…` directory. That is a Wine process in every respect, inside a
      Cocoa app bundle. It never `exec`s — which is exactly why its `executableURL` stays `Menu Helper`
      and why the bundle's identity and icon survive.
      - **So the contract our host must fulfil**, and it is just *the wine loader's job done inside an
        app bundle*: be LaunchServices-launched (for the identity) → listen on `CX_ALT_LOADER_SOCKET` →
        on `REQUEST_LOAD_WINE` apply the received cwd/env/argv and put the 4 received fds in place →
        `dlopen` the runtime's `lib/wine/<arch>-unix/ntdll.so` → resolve and call **`__wine_main`**
        (confirmed exported: `nm -gU` shows `T ___wine_main`). `bin/wineloader`'s own strings show the
        stock loader doing precisely this (`__wine_main`, "wine: __wine_main function not found in
        ntdll.so"), and **its source IS in the FOSS drop** (`loader/main.c`) — so the call convention can
        be read, not guessed.
      - ⚠️ **Constraint: the host's architecture must match the RUNTIME's, which today is x86_64.**
        `Menu Helper` is `Mach-O 64-bit executable x86_64`, same as `bin/wineloader`, because it has to
        `dlopen` x86_64 `.so` modules. A plain arm64 Swift app cannot, so today the host can't simply be
        a target inside Silo's arm64 app.
      - **Rosetta horizon — this constraint is temporary and NOT a new dependency (user, 2026-09-21).**
        Apple keeps Rosetta as a general Intel-app facility through macOS 27 and largely retires it in
        **macOS 28 (autumn 2027, ~1 year out)**, keeping a subset aimed at old unmaintained games on
        Intel frameworks. Whether Wine falls inside that exception is **not clear**, and the wording
        promises nothing. The sharp distinction: what Apple stops maintaining is the whole macOS
        **x86_64 user space**, while the low-level translator might survive — and Wine needs exactly
        that user space. **Verified here:** `lib/wine/x86_64-unix/winemac.so` is x86_64 and links
        AppKit, Carbon, CoreVideo, Foundation, IOKit, Metal, OpenGL, QuartzCore. So it is not the
        translator alone that matters.
        - Consequence: **the mechanism survives, the x86_64 constraint does not — and it dies together
          with everything else, not on its own.** All of Silo's Wine is x86_64 today, so the host adds
          **no new Rosetta dependency**: it shares the one already there.
        - When Wine goes ARM64 (announced for CrossOver 27) the host follows, and it gets *simpler*: the
          very constraint that keeps it out of Silo's arm64 target disappears, and it could live inside
          the app itself.
        - **None of the work is wasted:** `dlopen` of `ntdll.so` + the `__wine_main` call hold for any
          architecture. Only the compilation target changes.
        - **Design consequence for when it gets built:** author it for **both architectures from the
          start** (fat, or two slices), and pick the slice that matches the **runtime in use**, not the
          host OS — rather than an x86_64-only binary that has to be rewritten within a year.
      - **✅ FULL HOST SPEC (2026-09-21) — `loader/main.c` read; every piece verified. The hard part is
        NOT the socket, it's the address-space reservation.** The stock loader's `main()` is only this:
        `init_reserved_areas()` → `apple_override_bundle_name()` → `dlopen` ntdll.so → `dlsym` →
        `__wine_main(argc, argv)` (never returns). So the host is:
        1. **Linked with two zerofill segments — mandatory, and impossible to do at runtime.** On
           `__APPLE__ && __x86_64__ && !HAVE_WINE_PRELOADER` the loader declares
           `WINE_RESERVE` (vmaddr `0x1000`, vmsize `0x1fffff000` ≈ 8 GB) and `WINE_TOP_DOWN`
           (vmaddr `0x7ff000000000`, vmsize `0x1ff0000`) via `.zerofill` sections, because — quoting the
           source — that is *"the only way to prevent system frameworks from using them, including
           allocations before main() runs"*. **Verified that this is achievable in a Cocoa app:**
           `Menu Helper` carries both segments at byte-identical addresses and sizes to Wine's own child
           loader. That, not the IPC, is why the host can't just be an ordinary app.
        2. An app bundle, LaunchServices-launched (that's what supplies identity + icon).
        3. `init_reserved_areas()`: `mmap(PROT_NONE, MAP_FIXED|MAP_NORESERVE|MAP_PRIVATE|MAP_ANON)` over
           those two ranges.
        4. Listen on `CX_ALT_LOADER_SOCKET`; on `REQUEST_LOAD_WINE` take cwd/env/argv + the 4 fds.
        5. `dlopen("<runtime>/lib/wine/<arch>-unix/ntdll.so", RTLD_NOW)`, `dlsym("__wine_main")`, call it
           as `void (*)(int, char **)`. We can pass an absolute path — `try_dlopen`'s self-relative
           derivation is only for the stock loader's own layout.
        - **Bonus, and it closes an old loose end:** `apple_override_bundle_name` ("CrossOver Hack 13438")
          rewrites `CFBundleName` **inside the `__TEXT,__info_plist` section embedded in the loader
          binary**, taking the new value from **`WINEPRELOADERAPPNAME`** (then `unsetenv`s it). Verified:
          `lib/wine/x86_64-unix/wine` HAS such an embedded plist, `bin/wineloader` does NOT. Per the
          source comment this controls *"the title of the application menu"* — the menu bar — **not** the
          Dock tile and **not** the icon. So it explains why setting `WINEPRELOADERAPPNAME` by hand did
          nothing visible in the 2026-09-19 tests, and it is not the icon lever.
        - **Note for the dual-arch plan:** the reservation block is guarded by `__x86_64__`. ARM64 Wine
          will reserve differently (or use the preloader), so that part does NOT port verbatim — it is
          the one piece of the host that is genuinely architecture-specific.
      - **MINIMAL HOST BUILT AND RUN (2026-09-21). It runs Wine; it does NOT own the window — and that
        failure pins down what the socket is actually for.** A ~50-line C host, in an `.app` with Silo's
        icns, reserving the areas and calling `dlopen`+`__wine_main` directly (socket skipped on purpose,
        the handshake being already proven): **Notepad's window did open**, so the
        `dlopen`/`__wine_main` half of the spec is real. But the window belongs to a **child**
        (`notepad.exe`, exe `wine`, `bundleIdentifier = nil`) while our host stays alive owning nothing.
        Same when launched through LaunchServices, so it is not an identity-inheritance problem.
        - **Why:** `__wine_main` in a *fresh* process stands up a new Wine process tree and spawns the
          exe as a separate process. Calling it plainly can therefore never make the caller *be* the
          Windows process.
        - **So the socket is load-bearing after all, and now we know for what:** the message carries the
          **wineserver socket fd**, i.e. a process slot the wineserver has *already* created. The host
          must adopt it — almost certainly by placing that fd and exporting **`WINESERVERSOCKET`**
          (present in `ntdll.so` as `WINESERVERSOCKET=%u`) plus the received cwd/env/argv — and only then
          call `__wine_main`. That is what makes it *become* the process instead of parenting one.
        - **Link flags, discovered the hard way** (three failed links, worth keeping): the zerofill
          sections alone are not enough — the linker puts them wherever it likes. Needed:
          `-Wl,-no_pie -Wl,-pagezero_size,0x1000 -Wl,-image_base,0x200000000`
          `-Wl,-segaddr,WINE_RESERVE,0x1000 -Wl,-segaddr,WINE_TOP_DOWN,0x7ff000000000`.
          `__TEXT` must sit at `0x200000000`, immediately above the 8 GB reserve — copied from
          `Menu Helper`'s own layout. Getting it wrong fails loudly and usefully:
          `err:virtual:virtual_alloc_first_teb wine: failed to map the shared user data: c0000017`.
      - **FULL HOST WRITTEN AND RUN (2026-09-23). It receives the RIGHT process and reaches
        `__wine_main` — then dies. The adoption needs more than `WINESERVERSOCKET`.**
        - **The wire format is now fully known and implemented.** Last unread piece read from
          `process.c`: every length prefix is a **`uint64`**; `write_env` (line ~236) sends one blob of
          NUL-terminated `KEY=VALUE` strings, in order **`environ` → PE promotions → explicit
          `WINEDEBUG`**, later definitions winning; argv is the same shape (`argv[1..]`). Our host parses
          all of it correctly — measured `cwd=0 env=1844 argv=40` bytes and 4 fds on a real launch.
        - **The whitelist gate works, and it is how you target the right process.**
          `CX_ALT_LOADER_SOCKET` is consumed by the **first** process creation, which on a cold prefix is
          `wineboot.exe --init` — so the first runs adopted wineboot instead of the app. Writing
          `HKCU\Software\CrossOver\UseAltLoader` with a value **named after the exe's base name**
          (`"notepad"="1"`) fixed it: the next run delivered `argv[1] = C:\windows\system32\notepad.exe`.
          (The hardcoded SID in the source, `S-1-5-21-0-0-0-1000`, **does** match a Silo prefix — checked
          in `user.reg`, so that is not an obstacle.)
        - **Where it stops:** with the right process in hand the host applies cwd/env, `dup2`s
          stdin/out/err, exports `WINESERVERSOCKET=<fd>` and calls `__wine_main` — and the process then
          **dies without ever owning a window** (log ends at the call, no "returned" line; the surviving
          `notepad.exe` pid is a different, LaunchServices-unregistered child with 0 windows). So handing
          over the server socket via that env var is **not sufficient** to adopt an already-created
          process slot.
        - **`server_init_process` read (2026-09-23) — two of the three open questions close, and
          `WINESERVERSOCKET` turns out to be exactly right.** In `dlls/ntdll/unix/server.c`:
          `fd_socket = atoi(getenv("WINESERVERSOCKET"))`, then `fcntl(F_SETFD, FD_CLOEXEC)`, then
          `unsetenv`. So:
          1. **No fixed descriptor number** — any fd works, our approach was correct.
          2. **`WINE_WAIT_CHILD_PIPE` is NOT mandatory** — it's consulted only `if (child_pipe)` and is a
             CrossOver hack (bug 3853) for `explorer.exe`; absent, nothing happens.
          3. The meaning of the `uint32_t` reply is still unread (it's a few lines past where the sender
             was read).
          Right after taking the socket, ntdll does `data->request_fd = wine_server_receive_fd(&version)`
          — it expects the **first thread request fd** to arrive on that socket — and on Apple it also
          calls `send_server_task_port()`. A bad socket is reported via
          `fatal_perror("Bad server socket %d")`.
        - 🔍 **Why the failure looked silent — a diagnostic mistake of mine, not a property of the
          mechanism.** The host `dup2`s the received fd\[2\] onto its own stderr **before** calling
          `__wine_main`, so anything Wine printed (including that `fatal_perror`) went to the **launcher's**
          log, not the host's. And I grepped that launcher log only for `err:|fail|could not`, which
          `wine: Bad server socket N: …` does not match. **So the run may well have told us exactly what
          was wrong and I filtered it out.**
        - **✅ THE ERROR IS NOW CAPTURED (2026-09-23), and fixing the diagnostics was all it took.** Host
          rebuilt with stderr kept on **our own** log instead of the adopted fd, then the whitelisted
          notepad case re-run. The host does everything right — `LOAD_WINE`, `cwd=0 env=1926 argv=32`,
          `fd ricevuti: 4 -> 6 7 8 9`, `WINESERVERSOCKET=9`,
          `argv[1]=C:\windows\system32\notepad.exe` — and then Wine says:
          ```
          wine client error:0: version mismatch 44/1809.
          Your wineserver binary was not upgraded correctly, …
          Or maybe the wrong wineserver is still running?
          ```
          `1809` is `SERVER_PROTOCOL_VERSION`; `44` is what got read as the version.
        - **The message's own hint is ruled out by measurement.** The running wineserver *is* Silo's
          (`…/Runtimes/wine-crossover-26.3/…`), and Silo's `ntdll.so` and CrossOver.app's are the same
          build (both 608032 bytes). So it is not a stale or foreign server: the bytes read off the
          adopted socket are simply **not the handshake** `server_init_process` expects there.
        - **Both reads done (2026-09-23), plus two more measurements. The mismatch is NOT explained yet,
          but the search space is much smaller.**
          - `wine_server_receive_fd` (server.c:988) is a plain `recvmsg` on `fd_socket` reading
            **4 bytes** into `handle` — at init that is the protocol version — plus one fd via
            `SCM_RIGHTS`. So `44` is literally the first 4 bytes that arrived there.
          - The sender's `socketfd` IS the right socket: `spawn_process(params, socketfd, …)` passes the
            same descriptor to `send_to_cx_loader` that the forked child would have inherited.
          - **Found a genuinely missing piece of the handover:** `exec_wineloader` (loader.c:709) exports
            **two** variables, not one — `WINESERVERSOCKET=%u` *and*
            `WINEPRELOADRESERVE=<start>-<end>` (from `pe_info->base`/`map_size`). Added it to the host
            (`0-0`, the value `exec_wineloader` itself uses for fakedlls, since `pe_info` is not in the
            alt-loader message). **Re-tested: the mismatch is unchanged** — so it was a real gap in the
            handover but not the cause. Note `pe_info` is passed *to* `send_to_cx_loader` yet does not
            appear in the bytes it writes; worth re-checking whether it is sent somewhere we skipped.
          - **New measurement, and the most useful one:** a `MSG_PEEK` on the wineserver fd just before
            `__wine_main` **blocks** — so at handover time the socket is **empty**, nothing queued. The
            `44` therefore arrives *later*, from the server, rather than being stale garbage left in the
            buffer. (The probe is now `MSG_PEEK|MSG_DONTWAIT` in-tree so it cannot hang a future run —
            the blocking version wedged the host and that run produced no verdict.)
        - **✅ SYMPTOM RE-DIAGNOSED (2026-09-23): the server sends NOTHING, and `44` was a red herring.**
          Looping non-blocking peek on the adopted socket: **nothing arrives for 2000 ms**
          (`PEEK: nulla per 2000 ms`). And with those 2 s of delay in front of `__wine_main` the
          `version mismatch 44/1809` **stops appearing at all** — the host simply sits waiting. So the
          `44` was an artefact of calling `__wine_main` immediately (a race reading an empty/transient
          socket), not the server disagreeing about a version. **Treat the earlier "version mismatch"
          framing as wrong**: the real symptom is **silence** on the wineserver socket.
        - **So the open question changes shape:** what makes the wineserver write the
          version + first thread request fd to a process's socket? In the fork path the parent has
          already issued the `new_process` request and the server prepares that socket; for us it never
          speaks. Either the server does not consider this socket ready, or something the client must do
          first is missing.
        - **Server side located (2026-09-23) — the chain is one link from being closed.** The version is
          not sent on connection: it is sent **as part of thread creation**.
          `server/thread.c:518`, inside `create_thread(fd, process, sd)`, `if (fd == -1)` →
          `pipe(request_pipe)` → `send_client_fd( process, request_pipe[1], SERVER_PROTOCOL_VERSION )`.
          So the 4 bytes ntdll reads as the version travel together with the request pipe fd.
          - **The only caller passing `-1` is the master-socket accept path** —
            `server/request.c:566`, in `master_socket_poll_event`: on `accept()` it does
            `create_process(client, NULL, …)` (note `parent = NULL`) then `create_thread(-1, process, NULL)`.
            That is the `server_connect()` route, for a process starting from scratch.
          - The `new_process` route (`server/process.c:1482`) does `create_process(socket_fd, parent, …)`
            and **does not** call `create_thread(-1, …)` at that point.
          - **Link closed (2026-09-23), and the answer is surprising.** `create_process()`
            (`server/process.c:809`) only parks the socket — `process->msg_fd = create_anonymous_fd(…, fd, …)`
            — and creates **no** thread. And across the whole server there are exactly **three**
            `create_thread` sites: the definition (`thread.c:505`), the master-socket accept
            (`request.c:566`, `-1` → **sends the version**), and the `new_thread` request
            (`thread.c:1700`, called with a **real** `request_fd` → `fd != -1` → **sends nothing**).
            Combined with `SERVER_PROTOCOL_VERSION` appearing in exactly one place, that means:
            **the version is only ever sent to a process that connected on the master socket itself.**
          - ⚠️ **RETRACTED the same day: "only master-socket connections get the version" is WRONG.** The
            sanity check that broke it: forked children plainly do work, so the conclusion had to be
            incomplete. It is — the **parent** creates the child's first thread, from
            `dlls/ntdll/unix/process.c:1360`:
            ```c
            SERVER_START_REQ( new_thread )
                req->process    = process_handle;  /* the NEW process */
                req->request_fd = -1;              /* ← minus one */
            …
            /* create the child process */
            spawn_process( params, socketfd[0], … );   /* only AFTER */
            ```
            `request_fd == -1` is exactly the branch that reaches `create_thread(-1, …)` and therefore
            `send_client_fd(process, pipe, SERVER_PROTOCOL_VERSION)` — on the **new** process's socket,
            and **before** `spawn_process`, hence before `send_to_cx_loader` is ever called.
          - **So the version should already be queued on the fd we are handed — and our `MSG_PEEK` said
            it wasn't. THAT is the real anomaly**, and it is a much better-shaped question than any of the
            previous ones: not "what are we failing to set up", but "why is a message the server has
            already sent not visible on this descriptor in our process".
            - **First candidate closed (2026-09-23): we DO get the right end, and the ordering is in our
              favour.** `dlls/ntdll/unix/process.c`: `socketpair(…, socketfd)` (1293);
              `setsockopt(socketfd[0], SO_PASSCRED, …)` (1305) marks **`[0]` as the child's end**;
              `req->socket_fd = socketfd[1]` (1319) hands `[1]` to the server, which the parent then
              closes (1338); `new_thread` with `request_fd = -1` (1360) makes the server send the version
              **on that socket**; and only afterwards `spawn_process(params, socketfd[0], …)` (1379) —
              i.e. `send_to_cx_loader` receives the child's end, which is exactly the fd we adopt. So the
              version is queued on our descriptor *before* we are even called.
            - ⚠️ **Which makes the "socket is empty" measurement itself suspect — probably another
              diagnostic error, like the stderr one.** On Darwin `MSG_PEEK` is unreliable for messages
              carrying ancillary data (`SCM_RIGHTS`): the peek can report nothing while a control message
              is queued. Our probe may have been **blind, not the socket silent** — which would also
              explain why the earlier immediate call *did* read something (`44`, the first 4 bytes of a
              message the peek could not see).
            - **Measured with `SO_NREAD` (2026-09-23): `0 byte per 2000 ms`.** So the Darwin-`MSG_PEEK`
              excuse was **wrong** and the earlier "socket is empty" reading was right after all. Two
              independent non-destructive probes now agree.
            - **And `send_client_fd` (`server/request.c:457`) is immediate** — a plain
              `sendmsg(get_unix_fd(process->msg_fd), …)` carrying the handle as 4 bytes of payload plus
              the fd via `SCM_RIGHTS`, with no deferral and no queueing of its own.
            - ⚠️ **So two established facts now contradict each other:** the server writes the version
              before `spawn_process` is even called, and the descriptor we adopt reports nothing on it.
              One of the assumptions in between must be false, and **neither of my probes can settle it**:
              on Darwin I have not established that `SO_NREAD` or `MSG_PEEK` account for a record whose
              only real content is ancillary data, so "reports 0" and "is empty" may not be the same
              statement. I have now built a conclusion on a non-destructive probe twice; that stops here.
            - **✅ SETTLED (2026-09-23): the socket really is empty.** The destructive experiment — a real
              blocking `recvmsg` on `fds[3]` with `SO_RCVTIMEO = 3 s` — returned
              `errno 35 (EAGAIN)`. All **three** probes now agree (`MSG_PEEK`, `SO_NREAD`, real
              `recvmsg`), so the Darwin-blindness excuse is dead and the earlier "socket is empty"
              reading stands.
            - **Therefore one of the upstream assumptions is false, and it is no longer about our host.**
              The server demonstrably writes the version before `spawn_process` (hence before the alt
              loader), and yet nothing is readable on the descriptor we are handed. Either that fd is not
              the child's end of that socketpair, or the write did not happen for *this* process.
            - **✅ DESCRIPTOR IDENTIFIED (2026-09-23) — the plumbing is correct, so the write is what's
              missing.** Probe over all four received fds:
              ```
              fd 6,7,8: SO_TYPE=-1, getsockname/getpeername error   → not sockets (stdin/stdout/stderr)
              fd 9:     SO_TYPE=1 (SOCK_STREAM), anonymous, LOCAL_PEERPID = 25468
              pid 25468 = …/Runtimes/wine-crossover-26.3/lib/wine/… (the wineserver)
              ```
              So `fds[3]` **is** an anonymous socketpair whose peer is the **wineserver** — exactly the
              child's end of the pair, as the source said. Every assumption about the plumbing now checks
              out, which leaves only one conclusion: **for this process the server never wrote the
              version.**
            - **🎉 SOLVED (2026-09-23). The bug was our reply value, and asking the server is what found
              it.** Started the wineserver by hand with `-f -d1` and read its trace:
              ```
              new_process( … socket_fd=15 … ) = 0 { pid=00d4, handle=0064 }
              new_thread( process=0064, …, request_fd=-1, … )
              *fd* 0711 -> 196          ← 0x711 = 1809 = SERVER_PROTOCOL_VERSION, so it WAS sent
              new_thread() = 0 { tid=00d8 }
              00d8: *fd* 5 <- 196       ← and some process received it — not ours
              ```
              The version was sent all along; **a different process consumed it**. Reading what the sender
              does with our reply explains why: `process.c:513` → `ret = (response == RESPONSE_SUCCESS)`,
              and the enum at line 92 (*"must match definitions in Mac app code (WineLoader.m)"*) makes
              `RESPONSE_SUCCESS = REQUEST_LOAD_WINE + 1 = 0x52c17356`. **We were replying `0`**, so Wine
              concluded the alt loader had refused, fell back to `fork()`, and the forked child ate the
              handshake and became notepad. That single wrong constant produced every symptom chased for
              four sessions: the "empty" socket, the phantom `44`, the stray child, the silent fallback.
            - **✅ END-TO-END RESULT with the correct reply:**
              ```
              finestra: pid 25874 [SiloWineHost] "(senza nome) - Blocco Note"
              proprietario: SiloWineHost  bundleID=com.mikael.silo.winehost.test
              icona: PROPRIA
              ```
              One process, no forked child: **our own host became the Windows process, owns the macOS
              window, and carries our bundle identity and icon** — with no CodeWeavers binary anywhere.
              **User-confirmed on screen the same day: "in Stage Manager la finestra del Blocco Note ha
              l'icona di Silo".** That closes the original question of 2026-09-17 end to end.
              The route is proven viable on the CrossOver-imported runtime, with no Wine patch and no
              Silo prefix turned into a CrossOver bottle.
            - **Method note worth keeping:** four sessions of guessing on the client side were undone by
              one `wineserver -d1`. The instrumented server said in one trace what no amount of reading
              the sender could.
            - **✅ The double Dock tile is gone — fixed as a side effect.** Measured during a successful
              adoption: of all `.regular` applications only **one** belongs to us,
              `pid 26310 SiloWineHost / com.mikael.silo.winehost.test`. The second "wine" tile existed
              because the fallback `fork()` created a separate Wine process that registered its own; with
              one process there is one tile. Nothing left to do here.
            - **✅ The launch log survives, and this pins down what production must do.** `lsof` on the
              adopted host:
              ```
              fd 0 → /dev/null
              fd 1 → /private/tmp/dock/launcher.log   ← the file Silo's spawnDetached gave the launcher
              fd 2 → sock.log                          ← MY override, a prototype artefact
              ```
              The fds handed over by the launcher are the ones Silo already controls, so the game's output
              **does** reach Silo's log through them. ⚠️ **Requirement for the production host: adopt
              `fds[2]` as stderr too** (`dup2(fds[2], 2)`), which the prototype deliberately does not do
              so that Wine's own errors land in its debug log. Wine writes `err:`/`warn:` to **stderr**,
              so without that `GraphicsFallback` — the silent-wined3d guardrail — would go blind. That was
              the supervision risk flagged on 2026-09-19 and it is now precisely bounded.
            - **✅ `stopBottleProcesses` and the leftover sweep VERIFIED on device (2026-09-23), not just
              argued.** With an adopted host live (pid 26555) in Silo's SteamBottle:
              - before: the prefix's server dir `/tmp/.wine-501/server-100000f-687daa0` held
                **`lock` + `socket`** → `WineServerProbe.isLive` reads **live**, correctly.
              - running exactly what *Stop all bottle processes* does — `wineserver -k` with that
                `WINEPREFIX` — **terminated the adopted host** (pid gone, window gone). So the menu
                command does control the host: it is a Wine process in that prefix and the server kills
                it like any other.
              - after `-k` the dir holds **only `lock`** (the socket is gone) → the probe now reads
                **dead**, which is precisely the state `sweepLeftovers` is built to remove, and matches
                the case already documented in `WineServerProbe` ("only a leftover lock and nobody
                home").
              So both the kill path and the sweep's precondition behave correctly with the alt-loader
              host. (These had previously only been *reasoned* from the code — the user asked whether
              they were actually verified, and they were not; now they are.)
            - `SteamReadiness` still rests on reasoning only: it reads the `ActiveProcess` pid from
              `user.reg`, which is parentage-independent, but it has **not** been exercised with an
              adopted host — that needs a real in-prefix Steam, not notepad.
            - **✅ Whitelist mechanism written (2026-09-23): `Launch/AltLoaderWhitelist.swift`,
              +10 tests, 620 green, build clean.** Pure builders for the registry import, applied the way
              `SteamBottle.applyWineDefaults` already does it — one `wine regedit /S` instead of
              `reg add`, which hung repeatedly by hand.
              - `exeName(for:)` mirrors the sender's matching: last path component, cut at the final dot,
                handling **Windows** backslash paths (that is the form `argv[1]` carries) and keeping a
                leading dot for a name that is only an extension.
              - `enableReg(exeNames:)` whitelists exactly those names; `disableReg()` **deletes the key**
                (`[-HKEY…]`).
              - ⚠️ The distinction is load-bearing and tested: an existing-but-**empty** `UseAltLoader`
                matches nothing and would exclude *every* exe from the alt loader — exactly the state a
                half-finished `reg delete` left behind during the experiments. `enableReg(exeNames: [])`
                is therefore NOT a way to disable, and a test pins that.
              - Not wired into a launch path yet: it is the piece the production host will need.
            - **✅ Host productionised up to the launch wiring (2026-09-23; 629 tests green, build clean,
              `dist/Silo.app` assembles).** Four pieces:
              1. **`host.c` is production-correct on stderr:** it now does `dup2(fds[2], 2)` like the
                 other two descriptors, because Wine writes `err:`/`warn:` there and `GraphicsFallback`
                 parses exactly those — diverting it would blind the silent-wined3d guardrail.
                 `SILO_HOST_DEBUG_LOG=1` restores the old behaviour (stderr into the host's own log) for
                 diagnostics only; without it the host writes no per-launch file at all.
              2. **`GameHostBundle.write(into:hostBinary:iconICO:)`** installs the host as
                 `Contents/MacOS/SiloGameHost` (the name `CFBundleExecutable` declares), 0755, replacing
                 an older copy — safe while a previous launch runs, since that process keeps its inode.
                 `hostBinary: nil` still leaves the directory empty, which is what the
                 `SILO_LOADER_LINK_DIR` patch route wants, so one bundle serves both routes.
              3. **`AltLoaderHost`** (`Silo.swift`) locates the helper: `Contents/Helpers/SiloWineHost`
                 inside the running `.app`, with a `SILO_ALTLOADER_HOST` override for dev builds. Returns
                 **nil** when absent (the normal `swift run` case) — callers must read that as "launch the
                 old way", since the icon is cosmetic and must never block a game.
              4. **`build-app.sh`** builds the host and copies it into `Contents/Helpers/`, before the
                 ad-hoc signing so it is covered by it. Deliberately **best-effort**: a host that fails to
                 build prints a warning and the app still ships. Verified: the assembled bundle carries a
                 16 KB `Mach-O x86_64` executable (the 8 GB `WINE_RESERVE` is zerofill, so it costs no
                 file size).
              It is NOT a SwiftPM target on purpose: the fixed segment addresses and the runtime-matching
              architecture can't be expressed there (see `host.c`'s header).
            - **✅ `AltLoaderSession` written (2026-09-23; 641 tests green, build clean).** One launch's
              setup, in one place: write the per-game bundle with host + PE icon, import
              `AltLoaderWhitelist.enableReg` for that exe's base name, start the bundle through
              **`/usr/bin/open`** (LaunchServices — launching the executable directly does not work,
              measured on CrossOver's own helper), and return the socket to publish. `cleanup` deletes the
              whitelist key, and is called on the failure path too.
              - **Always-on with one global escape hatch**, per the decision of 2026-09-23:
                `SILO_DISABLE_ALTLOADER=1`. Deliberately no per-game setting — a toggle would ask the user
                to understand a Wine internal to get an icon. A per-game opt-out is worth adding only if a
                real game demands it.
              - **Every step degrades to the old launch path** (no host, unwritable `HostApps`, failed
                registry import, `open` refusing → `prepare` returns nil). Tested, including that a failed
                `open` still removes the key and that a failed import never launches the host.
            - **✅ `makePlan` publishes `CX_ALT_LOADER_SOCKET`** (`altLoaderSocket:`, default nil), passed
              through by `launchInBottle`/`launchManualGame`. Tested absent-by-default, present when given,
              and that it does **not** drag in `SILO_LOADER_LINK_DIR` or `WINEDLLPATH` — the two icon
              routes stay independent.
            - **✅ Wired into the launch path (2026-09-24; 645 tests green, build clean).** The call lives
              in **`LaunchOrchestrator`**, which owns the `ProcessRunning` (`GameLibraryViewModel` does
              not — that is why it could not live there) and already does the per-launch side work
              (`linkGraphics`, `presenceInstaller.apply`). Shape of it:
              - `AltLoaderSession.Target {gameName, gameID, hostAppsDir}` is the opt-in: both
                `launchInBottle` and `launchManualGame` take `altLoaderTarget:` (default nil = the launch
                that shipped before this feature, byte-identical). The VM passes one from both call sites
                with `paths.hostAppsDir`.
              - `prepareAltLoader` reads the exe's icon (`PEIcon`) itself and returns the socket, which is
                handed to `makePlan` as `altLoaderSocket:`. An explicitly passed socket still wins and
                skips the setup.
              - The session is injectable (`LaunchOrchestrator(… altLoader:)`) and carries its own
                `environment`, so a test can hand over a fake host without mutating the process env.
              - **The whitelist key is deliberately NOT removed after the spawn** — a correction to the
                plan of 2026-09-23, which said "call `cleanup` after the spawn". `spawnDetached` returns as
                soon as the launcher exists, while Wine reads the key *later*, when it creates the Windows
                process: deleting it there would race the hand-over away. Every launch rewrites the key for
                its own exe instead, so a leftover naming the previous game is harmless (that exe simply
                isn't adopted). `cleanup` stays for a deliberate teardown and for `prepare`'s failure path.
              - `loaderLinkDir` (the from-source patch route) and `altLoaderTarget` land on the **same**
                per-game bundle on purpose — two ways in, for two runtime kinds; a CrossOver-imported
                runtime is prebuilt and ignores `SILO_LOADER_LINK_DIR` entirely.
            - **✅ Verified end to end on device, and it took two real fixes (2026-09-24; 652 tests green).**
              The first wired run was measured, not assumed — and it failed, which is the whole value of
              having run it. Silo launched the game the old way while host, socket and whitelist all looked
              correct. Two distinct defects, both now fixed and pinned by tests:
              1. **The socket path was silently truncated.** `sockaddr_un.sun_path` holds 104 bytes on
                 Darwin, and overflowing it does not fail — it **truncates**. The per-user `TMPDIR` (49) +
                 `silo-altloader-` + a manual game's 36-char UUID + `.sock` came to **105**, so the host
                 bound `…0001.so` while Wine connected to `…0001.sock`, got ENOENT and forked. Fixed by a
                 short name (`silo-al-<head>-<FNV-1a hash>.sock`), a hard guard that refuses rather than
                 truncates, and the same refusal in `host.c`. Steam app IDs are short — this bites manual
                 games only, which is exactly why testing on a manual game was worth it.
              2. **`wine64 <exe>` never hands over at all.** With everything else correct Wine still did
                 not connect. Measured by hand, twice, with a listening host: `wine64 <exe>` → no
                 connection; `wine64 start /unix <exe>` → `LOAD_WINE`, 4 fds, `RESPONSE_SUCCESS`,
                 `argv[1]=C:\windows\system32\notepad.exe`, adopted. The reason: the plain form runs the
                 game **in the launcher's own process** (the loader `execve`s itself), so `spawn_process` —
                 the only call site of `send_to_cx_loader` — is never reached. `makePlan` now emits
                 `start /wait /unix <exe>` **only when a hand-over is active**; `/wait` keeps the launcher
                 alive for the game's lifetime, as before, so the log fds stay open.
              - Also added: `prepare` **waits for the host to `bind`** (bounded, 5 s, polling the socket
                file — which comes into existence at `bind`). `open` returns before the host has started,
                and the spawn follows within milliseconds, so the game could otherwise reach `connect()`
                first and fork. A host that never binds times out, cleans the key, and the game launches
                the old way.
              - **The result, measured on the production path** (deep link → `GameLibraryViewModel` →
                `LaunchOrchestrator` → `AltLoaderSession` → host): the window is owned by
                `Silo Host Check (…).app`, `bundleIdentifier = com.mikael.silo.host.<id>`, **non-generic
                icon**, and there is **no separate game process at all** — the host IS the game. Silo's
                per-game log still captures Wine's output through the adopted fds (117 lines, `winemac.drv`
                load traces and all), so `GraphicsFallback` keeps its eyes.
              - **Method notes worth keeping.** (a) A `silo://` deep link is resolved by **LaunchServices**,
                which picked the user's installed `/Applications/Silo.app` — the first "failed" run was the
                *old* build launching the game. Use `open -a "$PWD/dist/Silo.app" "silo://…"` to test the
                build you just made. (b) `ManualGame.bottleID` is separate from `id`, so a throwaway test
                entry can reuse an already-provisioned prefix instead of booting a new one. (c) The host
                launched **directly** (not through `open`) still got its bundle identity and icon on the
                window — so the "must go through LaunchServices" note is narrower than recorded;
                production keeps `open`, which is the proven path, but the constraint isn't identity.
            - **✅ Verified on a real game — God of War (GOG, manual, GPTK), 2026-09-24.** The window is
              owned by the host: `owner=God of War`, `bundleIdentifier=com.mikael.silo.host.<uuid>`,
              `God of War.app`, **non-generic icon**, no separate game process, `d3d11`/`dxgi` builtin (so
              GPTK is in play, not wined3d), and the Dock tile reads *God of War*. Confirmed on screen for
              the notepad case on all three surfaces (Stage Manager, Mission Control, Dock).
              **Three more defects surfaced, all found by running it and all fixed:**
              1. **The Dock labels a tile with the bundle's file name**, ahead of `CFBundleDisplayName` —
                 so `Silo Host Check (BEEF0000-…).app` produced a tile reading the id too. The bundle is
                 now `HostApps/<id>/<name>.app`: the id disambiguates one level up, the tile reads the
                 game's name alone.
              2. **`open -a` activates a running instance instead of starting a new one.** With the
                 previous game's host still alive, the next launch bound nothing, and the game fell back
                 (or worse — see 3). Now `open -n -a`.
              3. **A stale socket file made the readiness wait lie, and that one HUNG the game.** The host
                 can never clean up after itself — it *becomes* the game and never returns — so the socket
                 outlives it. The next launch found the file, believed a host was ready, and the game
                 connected to a socket nobody was accepting on and sat there waiting for the reply.
                 `prepare` now unlinks the socket before starting the host, so the wait measures *this*
                 run. Pinned by a test.
              - **And the hand-over does not carry a working directory.** `send_to_cx_loader` sends
                `cwd_len = 0` even when the creating process sets one (measured with `start /d`, which
                Wine does support). The host is started by LaunchServices, so it inherits `/`, and Wine
                derives the game's Windows cwd from the unix cwd — a game looking for data beside its exe
                would start in `Z:\`. Silo now publishes `SILO_HOST_CWD` and the host `chdir`s there
                before `__wine_main`. Measured: cwd went from `/` to the game's folder, and the game got
                measurably further (87 MB → 236 MB resident).
            - ✅ **CORRECTION (user, on screen, 2026-09-24 evening): God of War DOES start, and the icon is
              there in Stage Manager and Mission Control.** My earlier note in this slot said the game
              "does not currently start on this box" — that was wrong, and the mistake was the *test*, not
              the game. The window opens **windowed and waits to be activated**: the user clicked it, it
              went fullscreen, and the game's first-run setup began. Every launch after that goes
              fullscreen on its own. So the state I measured twice — window titled *God of War*, ~240 MB,
              ~0.4 % CPU, D3DMetal's thread parked — is a game waiting for focus, not a hang. A headless
              run cannot supply that click, which is exactly why the control comparison read "identical":
              **both** runs were waiting, with and without the hand-over. The control still does its job
              (it rules the hand-over out of any difference), and Sony's `crs-handler.exe` is just the
              game's companion process, not evidence of a crash.
              - **Method lesson:** "no progress + low CPU + a window on screen" is not evidence of a hang
                when nothing has focused the window. Before concluding, either click it or say plainly that
                the observation is only valid up to activation.
              - Open, minor, and worth watching rather than fixing blind: Silo is the frontmost app at
                launch, and `open -n -a` activates the host *before* Wine has a window (seconds earlier),
                so the game's window can come up unfocused. It self-resolved here after the first run —
                whether a host-side activation is warranted should be decided on more than one game.
            - **Teardown lesson, sharpened (the user caught two leftover Dock icons, 2026-09-24).** Killing
              the game and `start.exe` is not "cleaned up": the launch leaves `explorer.exe /desktop` and,
              for God of War, the game's own `crs-handler.exe` — *those* were the two tiles — plus the
              bottle's orphaned `services.exe`/`plugplay.exe`/`svchost.exe`/`rpcss.exe` once the wineserver
              is gone. **Verify with a broad filter (`ps -eo pid,command | grep "\.exe"`), never a list of
              expected names**, and cross-check with `NSWorkspace.runningApplications` — a bare `wine`
              process is invisible to a `winedevice|wineserver` grep but very visible in the Dock. Also
              note `wineserver -k` is a no-op against processes whose server already died (crash orphans):
              it starts a fresh server, kills nothing, and reports success.
            - **A clue for the God of War problem, worth keeping:** the run spawned Sony's
              `crs-handler.exe` (the game's crash reporter) ~13 s after launch, which points at a **crash**
              being swallowed rather than a hang. Present on the adopted run; the control run was killed
              before that could be compared, so it is a lead, not a finding.
            - ✅ **A STEAM GAME WORKS — Marvel's Spider-Man Remastered, appID 1817070 (user, on screen,
              2026-09-24 16:02).** The two Steam checklist items are substantially answered:
              - **The game's window carries its icon in Stage Manager**, and the launch was the wired
                production path with the hand-over live (`CX_ALT_LOADER_SOCKET=…silo-al-1817070-….sock`,
                `args: start /wait /unix …/Spider-Man.exe`).
              - **`SteamReadiness` still sees the client** — not by inspection but by construction:
                `play` refuses to launch a Steam game unless `SteamClientSession.ensureRunning()` returns
                true, and the game launched. The client came up first, then the game.
              - **The Steam client itself shows the generic icon, and that is correct, not a gap.** The
                whitelist names only the game's exe, so `steam.exe` is never adopted — adopting the client
                would put the *game's* icon on the *client's* window.
              - **The `explorer` worry does not apply to the game.** The `explorer /desktop=Silo,3456x2234`
                process in the tree belongs to the **client's** launch (`SteamClientSession` runs it in a
                virtual desktop); the game is launched directly, so the window-owner is the game's own
                adopted process. That closes the structural question this checklist item was really about.
            - ✅ **DIAGNOSED: the Dock tile that outlives a game is kept alive by the game's own leftover
              Wine children, not by the host (measured 2026-09-24).** Sequence, all measured on a live
              Spider-Man session:
              1. While playing: pid 45671 is the adopted host — `com.mikael.silo.host.1817070`, 166 % CPU,
                 709 MB, owner of the game's window.
              2. After the user quits the game: **45671 does not exist** (not even a zombie), and no process
                 carries our bundle id — yet the tile is still in the Dock, and `lsappinfo` still lists the
                 app as `type="Foreground"` with `pid = 45671` and a **coalition**.
              3. The bottle still had `explorer.exe /desktop` (pid 45677) from that launch. **Killing it
                 made the `lsappinfo` entry vanish immediately** (1 → 0).
              So the app's ASN — and therefore the Dock tile — lives as long as *any* member of the launch's
              coalition lives. Wine's per-desktop `explorer.exe` (and a game's own helpers, e.g. Sony's
              `crs-handler.exe`) outlive the game by design; in a shared Steam bottle they stay while the
              client keeps the wineserver up.
              - **Not a regression, and not the host's doing:** the same leftovers existed before this
                work — they simply showed up as anonymous `wine` tiles. What the alt loader changed is that
                a leftover now wears the game's name and icon, which *reads* as "the game is still
                running".
                (**Correction, user 2026-09-24:** the earlier "two God of War icons" do NOT corroborate
                this — those were leftovers of a test run I had failed to close, not of a normally-quit
                game. The Spider-Man measurement above is the only clean evidence, and it stands on its
                own.)
              - **The variability is explained too, by a 2 s-resolution trace of a fourth run (user asked
                the right question: the tile vanished by itself that time, so a mechanism that only fires
                sometimes was not yet an explanation).** Sampling `lsappinfo` + the launch's processes
                every 2 s gave: `19:44:27` host 47255 adopted, ASN=1 → `19:45:19` **host dead, ASN still
                1**, with Sony's `crs-handler.exe` (47291) still alive → `19:45:21` **handler exits, ASN
                drops to 0** in the same sample. So the ASN tracks the coalition *exactly*, with no stale
                registration and no delay: the tile outlived the game by two seconds because one child
                outlived it by two seconds. **What varies is which leftover survives and for how long** —
                a crash handler goes in seconds, Wine's per-desktop `explorer.exe /desktop` can stay for
                as long as the wineserver does. Nothing here is Silo's or the host's defect: the tile is
                macOS reporting, accurately, that a process from that launch is still running.
              - **The cold-bottle case, measured end to end (5th and 6th runs).** With Steam closed, the
                game's launch is what creates Wine's **default-desktop owner**, `explorer.exe /desktop`,
                and that one outlives the game: `lsappinfo` showed the app as
                `(exited-with-subordinates)` with `coalition: 22257 { 49718 … }`, pid 49718 being exactly
                that explorer, alive for minutes. Then, quitting Steam: `19:58:41` client shutting down,
                explorer alive, ASN=1 → `19:58:54` client gone, **explorer gone, ASN=0 in the same
                sample** → `19:58:58` bottle services gone. So in both directions the registration tracks
                the coalition with no staleness; the tile's lifetime is exactly the lifetime of the
                launch's longest-lived process.
                (Method note: my first tracer reported `explorer_desktop` as always empty — the filter
                anchored `/desktop$` while `ps` prints a trailing space. A blind column is worse than no
                column, because it reads as evidence of absence.)
              - **Verdict: known behaviour, not a defect to fix.** Wine holds the desktop owner until the
                bottle's wineserver stops, and macOS honestly reports it under the app that process
                belongs to. The two ways to make the tile go sooner are both worse: Silo creating the
                desktop owner itself would move the tile onto a permanent anonymous `wine` process, and
                running the game inside the client's virtual desktop would hand the window back to
                `explorer` and lose the icon — i.e. the whole feature. The levers that do work are the
                ones a user already has: quit Steam, or *Stop all bottle processes*.
              - **The tile does NOT clear itself after a minute.** `host.c`'s 60 s bound applies only to a
                host that never receives a connection; a host that *was* used has become the game and is
                outside that path entirely. The tile lasts as long as the launch's leftovers do — i.e.
                until Steam quits (shared bottle) or the bottle is stopped.
              - **Not worth fixing by reaping**, and this is a deliberate call: killing a launch's leftovers
                would mean Silo owning a game's lifecycle, which Phase 4 rules out — and in the shared Steam
                bottle those processes belong to the co-resident client too. The existing user-facing lever
                already clears it: *Stop all bottle processes*. Documented rather than engineered.
              - The `host.c` bounded wait (60 s) and single-use socket added for this symptom stay: they fix
                a *different*, real hole (a host nobody ever connected to would linger forever), verified in
                isolation.
            - 🧊 **Spider-Man freezes the Mac when leaving fullscreen — NOT Silo, NOT the hand-over
              (bisected on device, 2026-09-24 evening).** Symptom: fullscreen game, Cmd+Tab / Cmd+Q dead,
              only Cmd+Opt+Esc works; Force Quit lists the game as *"non risponde"*; black screen.
              - **Bisect:** reproduced on the **last-good build `2221a9c`** (built in a separate worktree,
                its own host verified byte-for-byte in the game bundle) → the latest commits are not the
                cause. Reproduced again with **`SILO_DISABLE_ALTLOADER=1`** (log: no
                `CX_ALT_LOADER_SOCKET`, plain `wine64 <exe>`, no host process) → the hand-over is not the
                cause either. **Nothing was reverted**, on that evidence.
              - **The sample (`sample`, while hung) is an AppKit/QuartzCore deadlock:** main thread in
                `NS_setFlushesWithDisplayLink` → `_os_unfair_lock_lock_slow`; a user-interactive queue
                thread in `_NSWindowTransformAnimation setCurrentProgress:` → `CASpringAnimation mass` →
                unfair lock; `CA::Fence::Observer` in `CAAnimation dealloc` → unfair lock. No Silo code and
                no Wine frame among the lock holders — the **window fullscreen-transition animation**
                deadlocks inside Apple's frameworks on macOS 27, triggered by Wine's fullscreen window.
              - **Third bisect point, the decisive one (user's idea):** the installed
                `/Applications/Silo.app` — 0.6.2 build `202609212207`, from **before any of the alt-loader
                work** (no host in the bundle, zero `CX_ALT_LOADER_SOCKET` strings in the binary, launch log
                `wine64 <exe>` with no hand-over) — **freezes identically**. Its sample shows the same three
                threads on the same unfair locks (`CASpringAnimation mass` inside
                `_NSWindowTransformAnimation setCurrentProgress:` on a user-interactive queue). So this has
                existed since at least 2026-09-21 and is independent of every change made since; it had
                simply never been triggered, because leaving a fullscreen game with Cmd+Tab was never tried.
              - **Next, if pursued:** (a) the same game in CrossOver, to confirm it is Wine-on-macOS-27 and
                not specific to anything of ours; (b) winemac's `HKCU\Software\Wine\Mac Driver`
                `CaptureDisplaysForFullscreen` option, which takes a different fullscreen path — a candidate
                workaround to *test*, not a fix to assume.
              - Side-finding to fix separately: after a force-quit, Steam's `ActiveProcess` pid in
                `user.reg` stays non-zero, and `SteamClientSession.awaitSteamReady` reads it as "ready" the
                instant the freshly launched client makes the wineserver live — so the game started before
                Steam (observed 21:03). Fix: zero the pid before starting Steam on a dead bottle.
            - 🚧 **`LaunchLeftovers` — the engine for "close this launch's remains, keep Steam" (user's
              decision, 2026-09-24; 669 tests green).** A **pull**, never a watch: it asks a bottle what is
              alive right now, so it does not need to observe a game's lifecycle (Phase 4 stands).
              - **Attribution is the wineserver directory** (`WineServerProbe.serverDirectory`, added for
                this): every process attached to a prefix holds files there, and a Windows command line
                names no prefix. A prefix with no live server yields an empty census — nothing is offered,
                nothing can be killed by mistake.
              - **The census splits games from leftovers.** Wine's plumbing (`services`, `winedevice`,
                `plugplay`, `svchost`, `rpcss`, `start`) and the whole Steam tree (including the client's
                `explorer.exe /desktop=Silo,…`) are excluded by design — the client's virtual desktop
                shares the *image name* with the leftover desktop owner, so the match is on `/desktop=`.
              - **The test caught a defect that would have killed running games:** an *adopted* game
                reports the **host binary** as its command line, not its exe (measured: the window-owning
                Spider-Man process showed `…/HostApps/1817070/….app/Contents/MacOS/SiloGameHost`). The
                classifier now recognises that first and unconditionally, so a playing game can never read
                as a leftover even if the caller passes no library at all. Pinned by two tests.
              - **Per-bottle, not per-game, and that is measured rather than lazy:** the leftover that
                holds the tile is Wine's desktop owner, whose command line ties it to no particular launch.
                The honest unit is "this prefix has leftovers and no game running" (`isOnlyLeftovers`).
              - **✅ Wired (672 tests green).** `AppEnvironment.refreshLaunchLeftovers()` censuses every
                bottle and publishes `launchLeftoverCount`; `closeLaunchLeftovers()` re-censuses and stops
                (SIGTERM only — Wine's loader handles it, and escalating on a whim risks cutting a write).
                The refresh is a **pull on `scenePhase == .active`**, next to the existing library refresh:
                coming back to Silo *from* a game is exactly when the answer changes. The menu entry
                (*Close Leftover Game Processes*, under the app menu beside *Stop All Bottle Processes*)
                exists **only while `launchLeftoverCount > 0`**, which is the conditional visibility the
                user asked for. Aggregation rule, pinned by tests: a bottle with a game running
                contributes **zero**, so the action can never sit one click away from killing a game.
                `NSRunningApplication` is deliberately NOT the signal — measured, it does not list an app
                in `(exited-with-subordinates)` state while `lsappinfo` does, so the condition is computed
                from processes, one step upstream of the tile.
              - **The `lsof` form was verified on device, and the first check was mine being wrong.** A
                unix-socket experiment suggested `+D` could not see socket holders, which would have made
                every census empty; measured against a live prefix, `lsof -t +D <serverDir>` returns all
                ten of a booted bottle's processes — they hold the server's **regular** `tmpmap-*` files
                there, not the socket. The original form was correct; the socket test was testing the wrong
                file type.
            - 🐞 **Silo hung at 98 % CPU during the God of War tests — fixed, and it was NOT the alt
              loader (2026-09-24).** The user reported the app frozen; `sample` put the main thread inside
              `GraphicsFallback.classify` → `range(of:options:.caseInsensitive)`.
              **Mechanism:** `GraphicsFallbackMonitor` arms a kqueue `FileWatch` that fires on **every**
              write, on a **concurrent** queue, and each event enqueued `Task { @MainActor in check(tail) }`
              — a 64 KB tail scanned case-insensitively (Unicode folding per character) **on the main
              actor**. A game logging through wine's trace channels writes constantly (God of War: a 42 MB
              log), so the main actor accumulated an unbounded queue of scans. It could not even stop
              itself: `autoStop`'s `stop()` needs the same starved main actor. GPTK has no engagement
              signature, so the watch never tore down early either.
              **Fix:** read *and* classify inside the watch closure (off the main actor — only a verdict
              crosses over), coalesced to one check per 250 ms.
              - The coalescing **schedules a trailing check rather than dropping events**. My first attempt
                dropped them, and a new test caught it immediately: the last write is then lost forever, so
                a game that logs its fallback line and goes quiet would never be noticed. Both properties
                are now pinned — main-actor responsiveness under 3 000 writes, and detection after a burst.
              - **Pre-existing, not a regression of this work**, but worth knowing it is much louder
                locally: `Silo.wineDebug` is `+loaddll` in dev builds and `-all,+winediag` in shipped ones
                (`SILO_QUIET_WINE`), so a shipped app writes a fraction of that volume. The unbounded
                enqueue was a defect regardless of volume.
            - 🚧 **DO NOT PUSH YET (user, 2026-09-24).** There are **23 commits** ahead of `origin/main`
              (last pushed: `be33e6e`) and they stay local until the whole on-device checklist is green.
              The gate is deliberate: the alt loader is always-on for every launch, so it gets pushed once,
              proven, not in instalments. **The checklist:**
              1. ✅ **Batman Arkham Knight** — done: icon on the startup window and the Dock tile, and its
                 first window took focus by itself (see the entry above).
              2. ✅ **The Steam client** — done: it starts and the readiness gate passes with the
                 hand-over live (see the Spider-Man entry above).
              3. ✅ **A Steam game** — done: Spider-Man Remastered, icon in Stage Manager.
              4. ✅ **The lingering Dock tile** — diagnosed and explained above: the game's leftover Wine
                 children keep the app's ASN alive. Cleared by *Stop all bottle processes*.
            - **▶️ NEXT:** (1) optional — a second running game (Batman Arkham Knight) to see whether the
              unfocused first window is general or was God of War's first-run setup;
              (2) a **Steam** game — still unanswered: which process owns the window there (`explorer`
              runs the virtual desktop, so the exe to whitelist may not be the game's), and whether
              `SteamReadiness` still sees the client when the host is the one adopted. No Steam game is
              installed in the shared bottle yet.
              Dual-arch stays future work, tied to ARM64 Wine.
            - *(historical)* The plan below — asking the server — is what solved it. `send_client_fd` prints
              `"%04x: *fd* %04x -> %d"` whenever the **server's** `debug_level` is on. So: start the
              wineserver by hand with `wineserver -d1` (or `-f -d1` in the foreground), capture its
              stderr, then run the whole alt-loader case. If the trace shows the version being sent for
              our process, the message exists and something eats it; if it never appears, the parent's
              `new_thread(request_fd = -1)` did not happen on this path — and then the question is which
              path the launcher actually took to create notepad, since `spawn_process` is the only
              `send_to_cx_loader` call site but may not be the only way a process gets created.
            - Also worth noting from this run: with the 2 s delay, `__wine_main` produced **no** error at
              all — the host stayed alive and a separate `notepad.exe` child appeared, i.e. Wine quietly
              fell back to starting a fresh process tree. That is consistent with the handshake failing
              and ntdll taking the `server_connect()` route instead.
          - ~~**Consequence — the current host design is probably wrong at the root, not incomplete.**~~
            *(Superseded by the retraction above; kept for the reasoning trail.)* A
            `new_process`-created socket is never going to receive a version, so a host that reuses it and
            then runs the *stock* `server_init_process` path (which unconditionally waits for one) can
            only hang. The silence we measured is the correct behaviour of the server, not a missing
            setting. Two hypotheses to test next, in order:
            1. the adopted process is meant to reach `__wine_main` in a mode that does **not** expect the
               version — i.e. the alt loader wants a different entry point or an extra env flag that
               makes ntdll skip the handshake (look for what distinguishes the two cases in
               `server_init_process`, and for any CrossOver-only flag around it);
            2. or the host should **not** reuse the passed socket for the handshake at all, and the fd is
               there for a later stage.
            Only after that does the `uint32_t` reply semantics matter.
        - ⚠️ Note on method: this stayed unexplained for two sessions because I kept reading the **client**
          side and guessing (`WINESERVERSOCKET`, then `WINEPRELOADRESERVE`, then a "version mismatch" that
          turned out to be a race artefact). The server side answered more in three greps than those
          guesses did in two runs. When a handshake fails, read **both** ends before testing.
        - **The prototype now lives in-tree at `Scripts/altloader-host/`** (`host.c` + `build.sh`, with
          the wire format and the mandatory link flags documented in the header) so it survives teardown
          — the previous one was lost in `/tmp` and had to be retyped. Not part of the app build; the
          compiled `host` is gitignored.
        - Reusable knowledge from the session: the link flags (above), and that **the test needs a warm
          prefix plus the whitelist**, or the host silently adopts `wineboot` and the run tells you
          nothing.
        - Teardown done in the right order this time (terminate → verify → remove), including deleting
          the `UseAltLoader` key from the user's prefix — verified `0` occurrences left in `user.reg`.
      - After the adoption works: the double Dock tile, then re-check `SteamReadiness` /
        `WineServerProbe` / `stopBottleProcesses` / the launch log (the log first — `GraphicsFallback`
        reads the child's output and the host would own those fds).
  - **⚠️ Superseded — kept for the reasoning trail. OWNERSHIP ≠ ICON (2026-09-20).** The user reported
    that during the `Menu Helper` control run Stage Manager still showed the generic icon, not the one in
    the Dock. They were right and the write-up above over-claimed: that run measured **window ownership
    only** (`CGWindowListCopyWindowInfo`); the icon of the owning process was never probed, and
    "ownership ⇒ correct icon" was an inference, not a measurement.
    - Re-run properly: a copied launcher with a **unique `CFBundleIdentifier`** and Silo's own `.icns`
      swapped in for `CrossOverHelper.icns`, re-registered with `lsregister -f`, launched via `open -a`.
      Result: the on-screen "Steam" window IS owned by our bundle (`pid 6248`, `SiloIconTest`, our bundle
      id) — **and its icon is the generic blank document**, not the icns we planted.
    - So **a bundle we control can own the window and still show the blank sheet.** Some further
      condition governs the icon, and it is not isolated yet.
    - **Code signing is NOT the discriminator** (the obvious first guess, checked and discarded): the
      ORIGINAL CrossOver launcher fails `codesign -v` too (`code has no resources but signature indicates
      they must be present`) and yet shows the Steam icon correctly in Stage Manager.
    - Still unexplained, and the first thing to chase next: why the freshly-built `BUNDLE-ICON` probe of
      2026-09-17 DID show its icns in Mission Control (user-confirmed) while this copied launcher does
      not. Candidates: the LaunchServices icon cache for a brand-new bundle id, the `.icns` not being
      resolvable under the name `CrossOverHelper`, or something CrossOver's menu machinery does — it
      **deleted our copied bundle** mid-test, which is itself a clue that it manages that folder.
    - **Consequence for the plan:** the alt-loader host would give us ownership, which is necessary but
      now demonstrably **not sufficient**. Do not treat the icon as solved by that route until this is
      pinned down.
  - **▶️ DECIDED (user, 2026-09-19) — pick this up here.**
    1. **NEXT TASK: run the `Menu Helper` experiment on the CrossOver-imported runtime.** Generate a bundle
       carrying a copy of the user's own licensed `Menu Helper` + the plist keys it reads
       (`CrossOverHelperCommand`, `CXHelperAppBottleName`, `CXHelperAppBottleTag`), launch a Wine target
       through it, and check with `CGWindowListCopyWindowInfo` whether the on-screen window ends up owned by
       that bundle (as it does for CrossOver's own Steam) instead of by the Wine process. The oracle for the
       icon is `NSRunningApplication(processIdentifier:).icon` — no need to look at the screen. Do NOT build
       Wine for this; it is explicitly not needed.
       - **RUN 2026-09-19 — ✅ MECHANISM PROVEN with OUR OWN bundle; ❌ not yet against a Silo prefix.**
         - **✅ The decisive result.** A **copy** of `Steam (Resident Evil Requiem).app` (as `ZZControl.app`,
           kept beside the originals, otherwise untouched), launched with `open -a`, started Steam — and
           `CGWindowListCopyWindowInfo` put the on-screen window *"Accedi a Steam"* on **pid 18726, the
           `Menu Helper` of OUR copied bundle**, while `steam.exe` ran separately as pid 18750. So a bundle
           **we** generate really can own the macOS window of a Wine app. That is the mechanism the whole
           route depends on, and it is no longer a hypothesis.
         - **The launch method is load-bearing, and it wasted two earlier attempts.** Running
           `Contents/MacOS/Menu Helper` **directly** launches nothing (the helper process starts and sits
           there). It must go through **LaunchServices** (`open -a`) — the bundle declares
           `CFBundleDocumentTypes` + `NSMainNibFile`, so it expects to be opened as an app. Every failure
           before this was that, not the prefix.
         - **❌ Against a Silo prefix it does not launch, and CrossOver says why.** With
           `CXHelperAppBottleName` pointed at Silo's SteamBottle (exposed as a symlink
           `…/CrossOver/Bottles/SiloSteamBottle`), nothing starts. Asking the underlying tool directly —
           `cxstart --bottle SiloSteamBottle <Steam.lnk>` — prints the cause:
           **`'cxbottle.conf' is not readable`**. Exactly the risk this entry predicted: the route wants a
           real CrossOver bottle, and Silo's prefixes are not.
         - **Partial progress on that.** Copying a real bottle's `cxbottle.conf` into an **APFS clone** of
           Silo's bottle cleared that specific error (`cxstart` stopped failing fast and ran until killed),
           but still nothing launched and no window appeared. Cause beyond that point unknown — **this is
           where the next session starts.**
         - **Note for the next run:** the answer may not be worth much even if it works, because of the
           licence boundary below — a Silo prefix would have to become, in effect, a CrossOver bottle
           (`cxbottle.conf` and all), which is a deep coupling to a product we cannot ship against.
           Weigh that before spending more on it; the *mechanism* question is already answered.
         - Cleanup verified: both probe bundles removed and unregistered, symlink gone from
           `CrossOver/Bottles`, clone deleted, and Silo's real SteamBottle never touched (no
           `cxbottle.conf` in it, no top-level file changed).
       - 🚧 **LICENCE BOUNDARY — write this down before the experiment succeeds, not after (user,
         2026-09-19).** Copying `Menu Helper` is legitimate *for the user, on the user's machine, under
         the user's licence*. It can **never become a shipped feature**: it is CodeWeavers' proprietary
         binary, and Silo may neither ship it nor generate bundles containing it for other users (see
         constraint #7, now explicit about this). So the experiment is valid **only as proof of the
         mechanism**. If it succeeds, the release path is a **host written by us speaking the same
         protocol — or nothing**. Do not let a successful experiment quietly turn into a feature.
       - **What a successful experiment would still have to answer — supervision (user, 2026-09-19).**
         Through `Menu Helper` the game/Steam process is no longer born of Silo, and four things depend on
         how it is born. Checked against the code:
         - `SteamReadiness` — reads the `ActiveProcess` pid out of the prefix's `user.reg` (+ a kqueue
           watch on that file). Registry-based, parentage-independent → **should hold**.
         - `WineServerProbe` — looks for `socket` **and** `lock` in the per-user temp dir keyed by the
           prefix's `(st_dev, st_ino)`. Prefix-identity-based → **should hold**.
         - `stopBottleProcesses` + the startup `sweepLeftovers` — these are **prefix-driven, not
           parentage-driven** (`allBottlePrefixes()` → `wineserver -k` with that `WINEPREFIX`), so a
           different parent is harmless. What WOULD break them is the game landing in a prefix Silo
           doesn't know: `Menu Helper` reads `CX_BOTTLE`/`CX_ROOT`, and if it insists on a real CrossOver
           bottle (`cxbottle.conf`), Silo's prefixes are not one. **That, precisely, is the risk to test.**
         - **The launch log** — `spawnDetached` captures the child's stdout/stderr, and an intermediary
           could send it elsewhere. Two consumers, and they do NOT fare the same: `GraphicsFallback`
           parses the **child's output**, so it would go blind (losing the silent-wined3d guardrail);
           `ShortcutFinalize.loggedExecutable` parses the `args  :` line of the **header Silo itself
           writes** before spawning, so the shortcut icon survives regardless.
    2. **The from-source runtime is NOT the current path.** `0001-loader-bundle-link-dir.patch` stays, kept
       **for completeness**, and its CI build is not scheduled. Making from-source equivalent to CrossOver's
       Wine — fixing its defects and limitations, **the GStreamer one in particular** — is acknowledged
       future work that needs its own effort.
    3. **Constraint #8 is upstream's, and this repo is a fork.** The user evaluates the alternatives and,
       holding a paid CrossOver licence, treats CrossOver's Wine as the FIRST alternative to consider.
       CLAUDE.md #8 now carries that framing; read it before invoking #8 against anything.
  - **✅ What the FOSS source DOES give us, and what was built on it (2026-09-19; `swift build` clean, 610
    tests green; the Wine half is NOT built or verified yet).** `winemac.drv` is in the source (42 files),
    and so is the whole naming mechanism, marked `CW HACK 22144 ... which will show up as the icon name in
    the Dock`: `create_tempdir()` picks `$TMPDIR/winetemp-<ino>-<size>-<mtime_s>-<mtime_ns>/`, mkdirs it and
    **symlinks `ntdll.so` into it**; `create_preloader_link()` hard-links the loader there under the exe's
    name; `replace_wineloader_path_with_link()` execs that path — gated on literally `if
    (getenv("WINEDLLPATH"))`, which is exactly the trigger measured empirically the day before. That
    `ntdll.so` symlink is the key insight: `init_paths()` `realpath`s it, recovering the true
    `dll_dir`/`bin_dir`/`data_dir`, which is why all four relative-path dependencies that broke the
    hand-made attempts resolve fine here.
    - **`Scripts/patches/0001-loader-bundle-link-dir.patch`** — lets the caller choose that directory via
      `SILO_LOADER_LINK_DIR`, and fires the mechanism on that var as well as `WINEDLLPATH` (so Silo never
      sets `WINEDLLPATH`, per the 2026-09-17 decision). Unset = byte-identical upstream; an unwritable
      directory makes `create_preloader_link` return NULL and the loader path is left alone, so it degrades
      to upstream rather than failing a launch. Verified to apply cleanly to `26.3.0` and to leave the
      function brace-balanced; applied by **both** `build-wine.sh` and `build-wine.yml` (required to apply).
    - **`GameHostBundle`** (`Launch/GameHostBundle.swift`) — the per-game host `.app`: pure `infoPlist()`,
      path shaping that can't escape its directory, ICO→ICNS conversion via ImageIO (largest `.ico`
      representation redrawn letterboxed into 16…512 squares, since `.icns` only takes squares), and a
      `write` that refreshes **in place** (a relaunch must not yank loader hard links out from under a
      running process) and refuses a destination that isn't ours. `AppPaths.hostAppsDir` (`HostApps/`, under
      `supportDir` so it survives an unplugged bottles drive). Icon comes from the existing `PEIcon`.
    - **Wiring:** `makePlan` gains `loaderLinkDir` → `SILO_LOADER_LINK_DIR` (default nil = no change);
      `launchInBottle`/`launchManualGame` pass it through; `GameLibraryViewModel.hostLoaderLinkDir` builds
      the bundle off the main actor, **best-effort** — any failure returns nil and the launch proceeds
      exactly as before, because a cosmetic icon must never block a game.
    - **Key measurement that makes one bundle enough:** an executable inside a bundle reports that bundle's
      `bundleIdentifier`, icon and `CFBundleName` **even when its file name ≠ `CFBundleExecutable`**. So the
      game exe, `explorer.exe` and `steamwebhelper.exe` all read as the game. (That is also why the
      bundle's `CFBundleExecutable` names a file that is never written.)
  - **NEXT — the open question, answerable only by a build:** does the renamed loader find `ntdll.so` with
    no `WINEDLLPATH` set? The upstream comment claims `WINEDLLPATH` is needed for exactly that, but
    `create_tempdir` itself plants the `ntdll.so` symlink the loader searches as `<its own dir>/ntdll.so`,
    so the precondition looks stale. If it turns out not to be, the follow-up is one line: `setenv`
    `WINEDLLPATH` from `dll_dir` *inside* `create_tempdir`, keeping Silo's launch env clean either way.
    This box has Command Line Tools only, so the build is CI (`build-wine.yml`) → install the runtime →
    probe with `NSRunningApplication` (the oracle above) → confirm in Mission Control.
  - **Also pending:** constraint #8 now has a documented `Scripts/patches/` carve-out, flagged in CLAUDE.md
    as **not yet ratified** by the user. Don't add a second patch before that decision.
  - **Side finding, NOT adopted (user decision, 2026-09-17: "non toccare `WINEDLLPATH` adesso").** Setting
    `WINEDLLPATH=<root>/lib` makes wine hardlink its loader into
    `$TMPDIR/winetemp-<inode>-<size>-<mtime>-0/<exe name>` and exec that, so the process is named
    **`notepad.exe`** instead of `wine` — CrossOver's own mechanism (its leftover `winetemp-…` dir on this
    box holds `explorer.exe`/`services.exe`/… as hardlinks to one inode). Being per-exec it would also cover
    Steam's window-owning children (`explorer` + `steamwebhelper`) — the exact thing `DockAppBundle` couldn't
    reach. **But it does NOT fix the icon** (measured on the real runtime: still the generic "exec" icon),
    and it changes module search on the GPTK/DXMT-critical path, which `makePlan` deliberately keeps free of
    `WINEDLLPATH`. Parked as a name-only lead needing its own validation. (`WINEPRELOADERAPPNAME` exists in
    `ntdll.so` but had no measurable effect.)
  - **Fallback idea if the alt-loader route is ever rejected:** patch the loader in our own from-source
    CrossOver-FOSS Wine build (constraint #8 puts that build in our hands) so it honours an external
    `WINELOADER` for child execs. Strictly worse than the alt-loader path (which needs no Wine patch at
    all), so it is the second choice, not the first.
  - Corrected along the way: `bin/wine` in this runtime is a **Perl** script (CrossOver's, with a
    documented `[Wine] BinPath` knob and a per-bottle `$WINEPREFIX/cxbottle.conf`), but Silo bypasses it —
    `backend.wineBinaryPath` is `bin/wine64`. Also: the dev box **has** had CrossOver installed (a leftover
    `winetemp-` dir points into `/Applications/CrossOver.app`), so CLAUDE.md's "CrossOver absent" is stale.

- **🪟 The app declared the wrong SDK, so macOS drew it in the compatibility appearance (2026-09-16,
  `main`; 589 tests green).** Silo's window came up in the pre-Liquid-Glass style on macOS 26/27 — toolbar
  buttons as loose icons with no shared glass capsule, a bordered search field — and the toolbar code was
  blameless: `LC_BUILD_VERSION` read `minos 15.0 / sdk 15.0`, because **SwiftPM writes the deployment target
  into BOTH fields**, and that `sdk` field is what AppKit reads to decide whether an app gets the current
  design. Confirmed on device: `vtool -set-build-version macos 15.0 27.0` on the built binary + a re-sign
  brought the capsule back immediately, with no code change.
  - Fix: new `Scripts/platform-version.sh` (sourced by `build-app.sh` **and** `dev.sh`) passes
    `-Xlinker -platform_version macos <deployment> <SDK>`, with the deployment target read out of
    `Package.swift` so it can't drift and the SDK from `xcrun --show-sdk-version`. `build-app.sh` then
    **verifies** the recorded `sdk` matches, and fails the build otherwise — the symptom is invisible in a
    diff, so a toolchain that stopped honouring the flags would otherwise ship it again.
  - `dev.sh` gets the same flags: it exists for looking at the UI, so the compatibility appearance there is
    worse than useless.
  - Not a macOS 27 regression in SwiftUI: macOS 26 restyled old-SDK apps anyway, 27 doesn't. The
    `ToolbarItem` + `ToolbarSpacer` shape from commit `49cc23f` is the documented one and is now confirmed
    correct on screen; only its causal note was wrong and has been corrected.
  - **The hairline under the toolbar is NOT coming back (user, 2026-09-16).** The new design replaces it
    with the scroll edge effect — the toolbar's glass floats over the content that scrolls under it —
    and that's the accepted look. So no `toolbarBackgroundVisibility(.visible, for: .windowToolbar)`:
    forcing a permanent bar background would fight the system for a line nobody's missing.

- **🎮 Game-controller support: re-enable SDL in the Wine build (integrated from upstream `mikaelhug/Silo`
  commit `888c16e`; also picked up upstream's fresh `wine-cx-26.3.0` / `dxmt-v0.72-cx26.3.0` CI releases).**
  Controllers didn't work because Wine was built `--without-sdl` and `libSDL2` was stripped on install
  (M75→M80) — a real fix for a recurring off-main-thread `NSWindow`/NSAlert abort when `winebus.so` dlopens
  libSDL2. Upstream's investigation (vs their local CrossOver install) found the abort was a property of the
  **generic Homebrew libSDL2**, not SDL: CrossOver bundles **SDL 2.30.12 x86_64**, sets **no** SDL hints, and
  its bottles set **no** winebus registry keys — it relies purely on winebus's compiled-in defaults
  (`Enable SDL=1`, `Map Controllers=1`, `DisableHidraw=0`); `Map Controllers` is what remaps *any* pad to
  XInput ("just works"). Mirroring CrossOver's exact SDL is the evidence-based fix. Changes integrated here:
  - `versions.env`: pinned `SDL_VERSION=2.30.12` (build-input only; not mirrored to `Versions.swift`).
  - `build-wine.sh` + `build-wine.yml`: build the pinned SDL from libsdl-org source (cmake, x86_64), flip
    `--without-sdl` → `--with-sdl` pointed at it; drop the Homebrew `sdl2` dep.
  - `bundle-wine-dylibs.sh`: bundle the built `libSDL2-2.0.0.dylib` into `lib/silo-bundled` (via
    `SILO_SDL_DYLIB`) — winebus dlopens it by leaf name off `DYLD_FALLBACK_LIBRARY_PATH`.
  - `RuntimeManager`: removed `stripBundledSDL` (call + fn + test) so the bundled SDL survives install.
  - No winebus registry work + deliberately no `xinput`/`dinput` DLL overrides — CrossOver relies on Wine's
    builtin defaults + SDL Map Controllers; adding overrides would deviate from that proven template.
  - **This fork's own `wineRepo` still points at upstream (`mikaelhug/Silo`)** — see the update-repo-fork
    fix below — so `Settings → Wine/DXMT → Install latest` already fetches these new upstream releases
    directly; a local rebuild via `Scripts/build-wine.sh` is only needed to build a CUSTOM Wine yourself.
  - **On-device-unverified upstream, controller-verified here (fill in once tested):** confirm no NSWindow
    abort on launch, controller enumeration, and non-Xbox→XInput parity with an actual gamepad plugged in.

- **🔎 Add-via-installer now infers games from the installer's own Start-Menu shortcuts (2026-07-14, `main`;
  417 tests green).** The failure that motivated this: a user ran an installer, then hand-picked a bare `.exe`
  (`Browser.exe`) that needs args + a working dir it couldn't know — blank window. CrossOver "just works"
  because it never asks you to pick an exe: it launches the installer's `.lnk` (`wine --start …`), which
  carries target + `WORKING_DIR` + `ARGUMENTS`. Silo now reads those shortcuts itself (keeps its direct-exec
  launch model + per-game log/backend control, unlike delegating to `wine start`). New pieces:
  - **`ShellLink`** (`PE/ShellLink.swift`) — clean-room MS-SHLLINK parser (target via LinkInfo `LocalBasePath`,
    NAME/WORKING_DIR/ARGUMENTS/ICON from StringData), Foundation-only, bounds-safe → `nil` on junk (mirrors
    `PEIcon`). Fixture = the real `GravityMark 1.89.lnk`.
  - **`BottleShortcuts`** (`Launch/BottleShortcuts.swift`) — scans a bottle's Start-Menu/Desktop for `.lnk`s,
    maps `C:\…` → `drive_c` host paths, filters uninstallers (Uninstall*/msiexec/Inno `unins*`), dedups.
  - **`ManualGame`** decouples identity from bottle: `bottleID` (tolerant-decoded → defaults to `id`) so N
    shortcuts from ONE install share ONE prefix (N library entries, not N installs); `workingDirectory` (URL?)
    honored by `makePlan` (cwd override). Bottle deletion is now **ref-counted** (only when the last entry
    using it is removed). `addManualGame` gained `bottleID`/`workingDirectory`/`customArgs`.
  - **Add sheet**: the installer now runs **blocking** (`LaunchOrchestrator.runInstaller` → `runner.run`, not
    `spawnDetached`; returns `ProcessResult` — an installer is transient setup, like the license-bearing
    component installers). Its exit when the user closes the window is the deterministic "install done" signal:
    Silo auto-scans + pre-selects the discovered shortcuts right then, so the **Add button lights up blue with
    zero extra clicks** (no manual "Find" button, no window-focus/polling heuristics — a small "Rescan"
    fallback covers the rare installer that exits before writing its shortcuts). Adding creates one
    `ManualGame` per pick, all sharing the install bottle. **Installer-path only** — a directly-chosen
    ready-to-run `.exe` is unchanged (no scanning).
  - Fixed a latent bug: the settings-sheet "Run Installer in this bottle" used `game.id` not `game.bottleID`.
  On-device-unverified: the SwiftUI picker end-to-end (parser + discovery are unit-tested against the real
  `.lnk`; the resolved launch = exactly what `run_browser.bat` runs).
- **🧩 Installer picker accepts `.msi` — and the launch path actually runs it (2026-07-14, `main`; 407 tests
  green).** The "Run Installer" pickers (Add-manual-game + manual-game settings) restricted `NSOpenPanel` to
  the `exe` UTType, so `.msi` packages were greyed out. And even a selected `.msi` couldn't run: `makePlan`
  did `wine <path>`, but a `.msi` is data, not a PE — wine can't exec it. Two-part fix: (1) `chooseExecutable`
  gained an `installer:` opt-in that adds the `msi` type to the two installer pickers only (game-target
  pickers stay `.exe`-only — a launch target must be a PE image); (2) `makePlan` routes an `.msi` target
  through the bottle's builtin `msiexec /i`, addressing the package via its `Z:` (unix-root) DOS path (argv,
  no shell → spaces need no quoting). `msiexec.exe`/`msi` are already `=builtin` in `BottleDefaults`, so wine's
  own msiexec handles it. Pure `invocation(for:)`/`dosPath(for:)` helpers, table-tested (msi→msiexec incl.
  DOS-path/spaces/appended-args; exe passthrough, case-insensitive). Surfaced while prepping a GravityMark
  D3D12 GPTK-vs-CrossOver benchmark — GravityMark ships as a `.msi`.
- **🎛️ Manual games now use the Automatic graphics backend too (2026-07-14, `main`; 402 tests green).** Manual
  (non-Steam) games previously took an explicit `GraphicsBackend` (`.gptk`/`.dxmt`, no Automatic) — a
  deliberate asymmetry, now reversed per the user. `ManualGame.backend: GraphicsBackend` → `graphics:
  GraphicsChoice` (default `.auto`), resolved forward by the SAME `BackendChooser.choose` `play` uses (32-bit →
  DXMT, else GPTK). `BottleResolver.manual` now takes the resolved backend explicitly (like `steam(backend:)`);
  `playManual` mirrors `play`'s resolution + 32-bit refusals. The settings sheet + Add sheet use the shared
  `GraphicsChoice` picker (Automatic/GPTK/DXMT); `BackendTag` shows `Auto`/`GPTK`/`DXMT`. **Kept SIMPLE per the
  user: forward Automatic only — manual games do NOT get the reactive learned-DXMT hint** (that machinery stays
  Steam-only; a GPTK failure on an Automatic manual game surfaces the honest "switch to DXMT" message rather
  than auto-rerouting). Tolerant Codable migrates an old explicit `backend` → the matching explicit choice;
  a config with neither key → `.auto`. Bonus UX win: a 32-bit manual game added with the default now routes to
  DXMT automatically instead of the old default-GPTK → refusal. Tests: migration + both Automatic-split paths.
- **🔗 Re-added "Create Desktop Shortcut" — as a deep-link, for BOTH game kinds (2026-07-14, `main`; 399 tests
  green).** The old (removed 2026-07-10) shortcut snapshotted a `LaunchPlan` into a standalone `.app` that
  `exec`'d wine directly — which went stale, needed DXMT prefix pre-seeding (`prepareGraphics`), read "wine"
  in the Dock, and couldn't serve Steam titles (no co-resident client). Rebuilt on a **`silo://` URL scheme**
  instead: a shortcut `.app` just `open`s `silo://play/steam/<appID>` or `silo://play/manual/<uuid>`, so the
  running/relaunched Silo resolves the backend (Automatic/learned-DXMT), prefix, and Steam client **fresh at
  click time** — correct forever, and works for Steam **and** manual games. New: `SiloDeepLink` (pure
  parse/build), `GameShortcut` (builds an `LSUIElement` agent `.app`, per-game bundle id, sanitized filename),
  `AppEnvironment.handleDeepLink`/`route` (+ a pending-link queue for cold-launch before the library loads),
  `SiloApp.onOpenURL`, `CFBundleURLTypes` in `Info.plist.template`, `GameLibraryViewModel.makeShortcut(for:)`
  ×2, and a "Create Desktop Shortcut" menu item on both tiles (best-effort icon: PE icon for manual, Steam
  header art for Steam). No `prepareGraphics`/prefix-seeding needed — the whole class of problems is gone.
  On-device-unverified: the LaunchServices scheme registration + `onOpenURL` delivery (needs the assembled,
  registered `.app`; the plist is `plutil`-clean and the pure logic is unit-tested).
- **🧹 Post-change review sweep (2026-07-13, `main`; 384 tests green).** Two adversarial review agents over the
  session's changes (switcher + Dock removal). Verdict: Dock removal left NO rot; the PE parser and switcher
  state machine are bounds-safe / fail-open / correct. Fixed the one real finding + closed a test gap:
  - **Bug (medium): `GameSettingsViewModel.learnedBackend` misreported a stale hint.** It gated only on
    `graphics == .auto`, not the runtime match `play` applies — so after a GPTK upgrade the sheet showed
    "Automatic is using DXMT" while the game actually re-probed GPTK. Now takes the current `gptkRuntimeName`
    (via `AppEnvironment.makeGameSettings`) and mirrors the launch gate. +test.
  - **Test gap: legacy VA-format delay import.** `PEFixture.withDelayImports` gained a `legacyVAImageBase`
    option; new test covers the `nameField &- imageBaseLow` (grAttrs bit0=0) branch.
  - Tightened the `save()` hint-reset comment (it overclaimed re-probe on an already-Automatic Save).
  - Accepted by design (not changed): the inert stale hint left in `config.json` (ignored everywhere), the
    import-dir-not-gated-on-`numDirs` fail-open path, DXMT engagement precedence, and lingering inert monitors.
- **🗑️ Removed the Dock-tile-naming feature (`DockAppBundle`) (2026-07-13, `main`; 382 tests green).** Steam
  (and games) show a Dock tile named "wine". The Phase-3 `DockAppBundle` `.app`-wrapper (below) never fixed
  that — it named only the windowless launcher process Silo spawns, while Steam's window-owning children (the
  `explorer` virtual desktop + CEF `steamwebhelper`, spawned by wine via `WINELOADER`) stayed "wine". A
  CrossOver-style co-located named-loader retry also failed (wine resolves the loader symlink back to its real
  name "wine"; the winemac driver is byte-identical to CrossOver's, so it's launch-side, but neither the
  wrapper nor the named loader reaches the children). Per the user, not worth the complexity for a cosmetic
  tile — **removed entirely**: deleted `DockAppBundle`(+tests), `Silo.pinWineLoader`, `AppPaths.dockAppsDir`,
  `LaunchOrchestrator.{DockIdentity,launchVia}`, and the `dock:` params; `launchSteam`/`launchInBottle`/
  `launchManualGame` now spawn the wine loader directly. Tests that used `WINELOADER` (set only as a wrapper
  side-effect) as the runtime proxy now assert on the spawn `executable`.
- **🔎 Switcher hardening: positive engagement + delay-load imports + re-probe UX (2026-07-13, `main`; 388
  tests green).** Three follow-ups from the honest post-Part-A review:
  - **#1 Positive engagement (`GraphicsFallback`):** detection was inference-from-absence. Added
    `Status.engaged` + backend-keyed `engagementSignatures` — DXMT logs `DXMT: created Metal device`, so a DXMT
    launch is now POSITIVELY confirmed (engagement wins over a later stray wined3d line; the monitor tears its
    watch down on engagement → no false "DXMT couldn't drive"). GPTK/D3DMetal success is SILENT in winediag
    (no positive line exists), so a healthy GPTK launch stays `.unknown` — documented, not faked. (Exact DXMT
    string to reconfirm on-device.)
  - **#3 Delay-load imports (`WindowsExecutable`):** `importedDLLs` walked only the regular import directory,
    so a title that DELAY-loads `d3d12`/`d3d9` (common) looked import-less and `dxmtMightHelp` fell through to
    its permissive path. Now also walks the delay-load directory (index 13, 32-byte `ImgDelayDescr`, RVA name
    format + legacy-VA fallback), gated on `NumberOfRvaAndSizes`. `PEFixture.withDelayImports` + tests.
  - **#4 Re-probe UX (`GameSettingsSheet`):** a learned-DXMT game shows as "Automatic," so the sheet now
    surfaces "Automatic is using DXMT — GPTK couldn't run this game." + a **Re-probe GPTK** button
    (`GameSettingsViewModel.reprobeGPTK`) that clears the hint immediately (no two-step dance).
  - **#5 resolved by POLICY (user, 2026-07-13):** "GPTK can be considered always faster than DXMT — use it
    unless it doesn't work." So there's no perf-ranking to build; GPTK is the defined-preferred backend and
    DXMT is strictly a fallback (32-bit, or a proven GPTK failure). Made explicit in `BackendChooser`'s doc;
    the switcher already implements it. **#2 skipped (user):** avoiding the wasted first GPTK launch would
    need a per-title compat DB with no 64-bit data to seed it.
  - **Still pending:** Part B on-device signature capture (real DXMT-failure + reconfirm the DXMT-engaged
    string) needs one real game launch through Silo.
- **🧠 Automatic backend switcher: learned-hint split + GPTK re-probe (2026-07-13, `main`; 381 tests green).**
  Part A of the switcher-improvement plan. The reactive GPTK→DXMT downgrade previously overwrote the user's
  `graphics = .auto` with `.dxmt` — permanent, indistinguishable from a manual pin in the settings UI, and a
  GPTK runtime upgrade never re-tried GPTK. It now records a SEPARATE, re-evaluable hint:
  - **`GameConfig.learnedBackend` + `learnedUnderRuntime`** (new, tolerant-decode, `encodeIfPresent`): `.auto`
    survives, the sheet still shows "Automatic." `BackendChooser.choose(_:is32Bit:learned:)` consults the hint
    only for a 64-bit Automatic launch (explicit pin wins; 32-bit → DXMT regardless).
  - **GPTK re-probe:** `play` drops a stale hint when `config.learnedUnderRuntime != backend.gptkRuntimeName`
    (a GPTK upgrade may fix the title), so GPTK is re-tried; `learnDXMT`→`learnBackend` stamps the current
    `gptkRuntimeName` when it learns. Thrash is impossible (a learned game gets `chosen == .dxmt` → not eligible
    to re-learn).
  - **Hint reset:** `GameSettingsViewModel.save` retires the hint only when the user actually changes the
    graphics picker (an unrelated Save keeps it).
  - Full offline state-machine coverage: `BackendChooser`/`GameConfig`/`GameLibraryViewModel`/`ViewModel` tests
    (rewrote `autoReactiveSwitchToDXMT` to assert `.auto` preserved + `learnedBackend == .dxmt`; +7 new cases).
  - **Part B deferred (on-device capture):** real DXMT-specific failure + positive "GPTK engaged" log
    signatures for `GraphicsFallback`. The box has a working bottle + all 3 runtimes but **no per-game log yet**
    (only `steam-bottle.log`, where the Steam client runs wined3d/Vulkan — confirming a game needs its
    `d3d11=builtin` override to make the wined3d signal trustworthy). Capture needs one real game launch.
- **✂️ Setup: dropped the warm-up progress % (2026-07-13, `main`; 373 tests green).** The "Steam is updating
  itself — N%…" counter was parsed out of Steam's own updater log (`Downloading update (X of Y KB)`), but the
  fraction was unreliable and not worth the complexity — removed the whole mechanism. `WarmUpPhase.downloading`
  no longer carries a fraction; `SteamBottle.updateState()` → `isUpdateCommitted() -> Bool` (kept the one
  reliable signal — the `Update complete` marker the warm-up waits on); `SteamBottleViewModel.warmUpFraction`
  gone; both progress bars (onboarding + General settings) are now plain indeterminate. Status reads simply
  "Steam is updating itself…". No behaviour change to the warm-up's completion logic.
- **✍️ Message review — one consistent voice (2026-07-12, `main`; 373 tests green).** Went over every
  user-facing status/error string. Unified the error voice to `"Couldn't <verb>: <detail>"` across all VMs
  (was a mix of that and `"<X> failed:"` — RuntimeVM/GPTKVM/BackendVM/installer now match GameLibrary/relocation;
  the top-level `"Setup failed:"` outcome is the one intentional exception). Shortened the last verbose lines
  (the exFAT-drive warning, the mid-move / drive-not-connected relocation messages) and aligned
  "Bottles drive not connected." everywhere. Progress = `"<Verb>ing …"`, success = terse past tense, prompts =
  short imperative.
- **⏬ Setup: download EVERYTHING at "Set up" in the background; dropped the download cache (2026-07-12, `main`;
  373 tests green).** Rebuilt the setup download flow per the user's spec. Previously only core fonts were
  prefetched, so Source Han Sans (~360 MB) only started downloading when its install step arrived — blocking
  there for minutes while the status misleadingly read "Installing Asian Fonts…".
  - **New `SetupDownloads`** (`Sources/SiloKit/Steam/SetupDownloads.swift`): the moment "Set up" is pressed,
    `SteamBottleViewModel.setUp` calls `bottle.startSetupDownloads()`, which kicks off EVERY component's
    artifacts (core fonts, SHS, d3dcompiler cabs, MSVC redist) concurrently into a fresh temp dir — so the slow
    ones overlap the Steam download + wineboot + the earlier install steps. It skips components already
    installed (a re-run doesn't re-download 360 MB), and SHA-verifies the pinned artifacts (core fonts, cabs).
  - **Download separated from install:** `installCoreFonts`/`installSourceHanSans`/`installD3DCompiler47`/
    `installVCRedist` now `await` their artifact from `SetupDownloads` and install it (staging into `drive_c`
    where Wine needs a `C:\…` path), instead of downloading inline. `provisionComponents` awaits each step's
    download, narrating **`.downloading`** ("Downloading <X>…") when it's still in flight, then **`.installing`**
    — exactly the "show downloading instead of a slow installing" the user asked for.
  - **Cache removed:** deleted the persistent `AppPaths.downloadCacheDir` + `cachedCoreFontExe`/`prefetchCoreFonts`
    (the user found it needlessly complex + prone to stale installers). The temp dir is wiped at the start of
    every run and removed on `cleanup()` — always fresh, never a stale installer.
  - `LockedBox.mutate` added (atomic Set insert). Tests: install methods take a `downloads`; a direct
    `SetupDownloads` test (fetch + SHA-verify + temp cleanup) replaces the old cache test; also fixed a
    pre-existing latent test that did a real 20 s network download (now fully stubbed → suite runs in ~1 s).
    **On-device-unverified** (shares the setup path caveat).
- **✂️ Shortened + homogenised user-facing status messages (2026-07-12, `main`; 373 tests green).** Trimmed the
  verbose, self-explanatory status lines to a consistent house style — progress as `"<Verb>ing …"` ("Creating
  bottle…", "Downloading Steam client…", "Installing Asian Fonts…"), success as a terse past-tense sentence,
  errors as `"Couldn't … ."` / `"… failed: <detail>"`. Setup got the biggest cut (dropped the "one-time, this
  can take a few minutes", the multi-clause ready/paused copy, and the wordy license line — now "Accept the
  <X> license — ⌘-Tab if it's behind Silo."). Also trimmed the library launch-guard / uninstall / 32-bit /
  play-date / retina / "no build published" lines. All substrings the tests pin were preserved (no test copy
  changes). The already-terse per-title graphics-fallback messages were left as-is.
- **🪟 Setup: REMOVED the installer-window focuser; rely on a ⌘-Tab hint instead (2026-07-12, `main`; 373 tests
  green).** Wine setup windows (Core Fonts EULA, MSVC redist, Steam) open BEHIND Silo, and reliably raising them
  proved unachievable from Silo's side: a `Process`-forked Wine app doesn't self-activate, and macOS's
  focus-stealing guard refuses cross-app activation (even the cooperative `NSApp.yieldActivation`). Three
  attempts (launch-notification, poll, KVO on `runningApplications` — all + cooperative activation) didn't work;
  the durable fix would be winemac.drv-side (self-activating the window), a Wine-build change deferred until
  it's worth it. So `InstallerWindowFocuser` (+ its `GuidedInstallFocusing` protocol, the VM's `focuser`/`wineRoot`,
  and the arm/disarm wiring) is **deleted** — not worth the complexity for a ⌘-Tab-able window. The user-guided
  component status now tells the user a license window opened and to press ⌘-Tab / click it in the Dock if it's
  behind Silo (they're looking at Silo when it is, so they see the hint). Net −2 files, simpler setup VM.
- **🔎 Setup logical sweep + fixes before the on-device test (2026-07-12, `main`; `swift build` clean, 375
  tests green).** Two fresh-eyes audits of the whole setup path (`runFullSetup` → `setUp` → `provisionComponents`
  → warm-up) confirmed the happy path is sound; fixed the defects most likely to bite an on-device run:
  - **VC-redist no longer hard-fails on a weird Wine exit code (top on-device risk).** It marked success on
    `{0,3010,1638}` and treated EVERYTHING else — including a non-standard code an actually-completed installer
    can return under Wine — as a fatal `componentCancelled`, halting setup before Steam and re-failing every
    run (the SAME exit-code unreliability that just broke Core Fonts). Now only a real cancel (1602/1223) is
    fatal; any other outcome is best-effort (unmarked, re-prompts, continues to Steam).
  - **Core-fonts license shows on the first AVAILABLE font**, not a hard-coded index 0 — so a failed download of
    andale32 no longer silently skips the license while the rest install. And a DECLINE now installs NO core
    fonts (they share one license) and stops best-effort, instead of installing the rest.
  - **Warm-up settles after setUp's force-quit** before its fresh launch (reuses `warmUpForceQuitSettle`; 0 in
    tests), so the update client doesn't race the wineserver reaping the killed installer procs.
  - **The background font prefetch is cancelled on an early setUp failure** (defer), so it can't outlive setUp
    and race a re-run's prefetch/install on the same cache.
  - Tests +2 (VC-redist unknown-code best-effort; license-on-first-available-font). **Deferred NITs** (noted,
    low-risk): `hasCoreFonts` keys on Arial only (a failed arial32 re-runs the font install each setup — wasteful,
    not broken); d3dcompiler destroy-before-verify on a resume (self-heals); a config-save failure surfacing a
    misleading "Set up Wine first." Still shares the Core Fonts path's on-device-unverified caveat.
- **⚡ Setup: prefetch the core fonts in the background at "Set up" (2026-07-12, `main`; `swift build` clean,
  373 tests green).** Follow-up to the Core Fonts fix — the font installers now download the MOMENT "Set up" is
  pressed, into a persistent `paths.downloadCacheDir` (under `supportDir`, so it works before the prefix exists
  and survives across runs), overlapping the Steam download + wineboot instead of stalling the Core Fonts step.
  New `SteamBottle.prefetchCoreFonts()` (best-effort; no-ops when `hasCoreFonts`) + a shared `cachedCoreFontExe`
  fetch-or-cache primitive that both the prefetch and `installCoreFonts` consume — so each font downloads at
  most once (HTTPS-guarded, SHA-verified). `SteamBottleViewModel.setUp` kicks it off up front and `await`s it
  just before the component phase (warm cache ⇒ no wait there, no double-download) — surfacing a "Downloading
  core fonts…" status there ONLY if the prefetch is still running (a `LockedBox` completion flag), so a warm
  cache skips the flash. The user-guided component
  narration is now the short "Accept the … license in the window that opens…" (the "downloading first" text is
  obsolete now the download is prefetched). Shares the Core Fonts fix's on-device-unverified caveat.
- **🩹 Fix: Core Fonts setup step (regression in 0.3.5) (2026-07-12, `main`; `swift build` clean, 372 tests
  green).** A user hit two problems at the Core Fonts step during a real on-device setup:
  - **Accepting the license was misread as a cancel → setup halted.** The IExpress core-font installers return
    a NON-ZERO exit code even on Accept under Wine (winetricks never runs them for exactly this reason — it
    extracts them), so the exit-code check (`result?.succeeded`) falsely tripped `componentCancelled`. Reworked
    `installCoreFonts`: every font is extracted to Silo's own dir via `/C /T` (reliable under Wine), the FIRST
    runs WITHOUT `/Q` so IExpress shows Microsoft's license once, and accept-vs-decline is read from whether
    the `.ttf` actually extracted — a decline now just skips that font (best-effort), it never fails setup. Core
    Fonts no longer uses `componentCancelled` (VC-redist / Steam still hard-stop on cancel, via their reliable
    MSI/installer exit codes).
  - **Confusing "Accept the license" message** appeared minutes before the window (during the font download).
    The user-guided component narration now says the license window will open shortly and may take a moment to
    download first.
  - **⚠️ On-device-unverified (Wine absent on the dev box):** the logic is unit-tested, but the Wine-specific
    behavior — `/C /T` (no `/Q`) showing the license + extracting the `.ttf` on Accept — needs a real Set up run
    to confirm before shipping a 0.3.6. Worst case it extracts silently (license not shown) but setup still
    completes; it can no longer falsely block.
- **🔐 Supply-chain integrity — third-party downloads now content-pinned (2026-07-12, `main`; `swift build`
  clean + zero warnings, 372 tests green).** Closes the remaining production gate from sweep #2: the artifacts
  Silo downloads and then EXECUTES under Wine are now verified against pinned SHA-256 before they run, so a
  compromised mirror/CDN can no longer feed the prefix malicious code.
  - **Core fonts pinned.** `Silo.coreFontSHA256` pins all 11 self-extracting `.exe`s (winetricks' published
    `load_corefonts` digests, cross-checked here against the live SourceForge **and** pushcx bytes — both
    matched). `SteamBottle.installCoreFonts` verifies each download before executing it; a tampered/corrupt
    mirror falls through to the other mirror, and if neither verifies the font is dropped (never run). The
    pushcx GitHub fallback is now safe to keep (it's winetricks' own primary mirror, and the pin makes the
    source immaterial) — so it stays, for resilience, rather than being removed.
  - **Bugfix found while pinning:** the core-font list had `webdings32`, but the real corefonts filename is
    `webdin32` — `webdings32.exe` 404s on both mirrors, so Webdings never installed. Fixed to `webdin32` (+
    its verified pin).
  - **d3dcompiler cabs pinned.** `Silo.d3dCompiler47{X64,X86}CabSHA256` pin the two MS SDK cabinets (verified
    before `wine expand`s the DLL games load). winetricks doesn't pin these, so the values are SHA-256 of
    Microsoft's own `download.microsoft.com` HTTPS artifacts (immutable GUID-named SDK cabs; stable across
    re-download) — trust-on-first-use from the vendor, strictly stronger than the prior zero verification.
  - **Redirect-safe HTTPS was already covered — by ATS, more strongly than app code could.** Confirmed
    `NSAllowsArbitraryLoads=false` (Info.plist) makes the OS refuse cleartext at EVERY hop, so a redirect to
    `http://` fails the whole request (through SourceForge/`aka.ms` redirectors too). Documented the layering
    in `DownloadGuard` rather than adding a redundant per-hop delegate. The residual (https→attacker-*https*)
    is what the content pins above close.
  - **Design:** digest maps are injected into `SteamBottle` (default = the real `Silo` pins). A missing key =
    "unpinned → don't verify"; a completeness test asserts the production maps cover every font + both cabs,
    so fail-open-on-missing can't bite in production while tests inject `[:]` to run the install flow with stub
    bytes. Tests (+2): a mismatched font digest is dropped + never executed (accept + reject paths); pins are
    complete.
  - **Still deferred (correctly):** the Steam + VC-redist *bootstrappers* auto-rotate versions, so they stay
    HTTPS + official-host (aka.ms / steamstatic) without a content pin; and the self-update codesign/
    notarization check remains a no-op until there's an Apple Developer ID (see BLOCKED). Neither is a
    fixed-artifact pin, so neither is guessed inline.
- **🛡️ Production-hardening sweep #2 — security/integrity/robustness (2026-07-12, `main`; `swift build` clean
  + zero warnings, 370 tests green).** A second, differently-scoped pass (3 parallel audits: security/injection
  surface, download & extraction integrity, untrusted-input & filesystem/concurrency robustness) — the first
  sweep was *logical* consistency; this one targets the production-bar dimensions it didn't. Verdict: the
  parsers/PE-readers/config-store are genuinely well-hardened (depth-capped recursion, bounds-checked every PE
  offset, atomic+backed-up config, no shell/`Process`-argv injection, ATS blocks cleartext); the real defects
  were a filesystem TOCTOU + a couple of resource/robustness gaps, patched:
  - **Bottle-move TOCTOU (data corruption) closed.** `launchInFlight` clears when `spawnDetached` returns —
    *before* wine creates its wineserver socket — so a game launched during a slow cross-volume move was
    invisible to both liveness signals and its prefix got deleted out from under it. `BottleRelocator.move`
    now takes a `sourcesInUse` probe re-checked right before the source rename/delete (the point of no
    return); the coordinator passes `WineServerProbe.isAnyBottleLive`, aborting + rolling back (sources
    intact) with a clear message if a bottle went live mid-move.
  - **GraphicsFallbackMonitor kqueue-fd leak bounded.** A healthy launch (the common case) never fired the
    fallback signature, so its `FileWatch` stayed armed for the whole session — one leaked fd per launch. The
    monitor now auto-releases the watch after a bounded `observationWindow` (120s; the backend engages within
    seconds), self-cancelling on fire/stop.
  - **`libraryfolders.vdf` read is now size-capped** like the appmanifest read already was (a hostile/corrupt
    multi-MB VDF is no longer slurped into memory); `maxManifestBytes` became an injectable `DiscoveryEngine`
    param.
  - Tests (+3): relocator aborts + rolls back on a mid-move live bottle (both cross-volume and rename paths);
    oversized VDF skipped; fallback monitor releases its watch after the window.
  - **⚠️ REMAINING production gate — supply-chain integrity (deferred, needs external inputs):** Silo
    checksum-verifies the two artifacts it *publishes* (Wine/DXMT runtime, app self-update) but the four
    third-party artifacts it downloads and *executes under Wine* — Steam installer, VC++ redist, MS core-font
    `.exe`s, d3dcompiler CABs — are HTTPS-only, **not** integrity-verified; a compromised mirror/CDN → code
    execution in the prefix (sharpest edge: the core-fonts fallback pulls `.exe`s from a *personal* GitHub
    repo, `pushcx/corefonts`, in `Silo.swift`). Also: `DownloadGuard.requireHTTPS` checks only the initial
    URL, not redirect hops (ATS blocks http→ downgrades but not http**s**→attacker-host); a user-overridden
    runtime repo skips the digest when no sidecar `.sha256`; and the self-update does no codesign/notarization
    check before replacing the running app (a no-op until there's a Developer ID — see BLOCKED). Fix track:
    pin SHA-256 for the fixed-version artifacts (corefonts/d3dcompiler/SHS — the Steam/vcredist bootstrappers
    auto-rotate, so those stay HTTPS+official-host), drop the personal-repo fallback, re-apply `requireHTTPS`
    per redirect hop, and add the codesign check when signing lands. **This is the real "before production"
    item; needs trustworthy published hashes, so it's a dedicated follow-up, not guessed inline.**
- **🧭 Production-readiness architecture sweep — inconsistencies patched (2026-07-12, `main`; `swift build`
  clean + zero warnings, 367 tests green).** A logical sweep (4 parallel audits: concurrency/protocol
  boundaries, single-source-of-truth routing, dead-code/stale-refs, big-file logic) found the core
  architecture sound (no `@unchecked`, no stray `Foundation.Process`, entitlements sandbox-free, both
  launch paths route through `BottleResolver`). Fixed the real inconsistencies it surfaced:
  - **Steam readiness now cross-checks liveness.** `SteamClientSession.isRunning` ANDed the reg
    `ActiveProcess` pid with `WineServerProbe.isLive(prefix:)` — a stale non-zero pid (crash / setup's
    warm-up `taskkill /F`) no longer reads as "up" and lets `ensureRunning` skip the relaunch → a game
    launched against a dead client (silent `SteamAPI_Init` fail). The reg pid is Wine's Windows-pid
    namespace (not host-`kill`able), so the wineserver socket is the correct host-side liveness signal.
  - **`playManual` gained the 32-bit-DXMT guard `play` already had.** A manual DXMT game with a 32-bit exe
    on a 64-bit-only DXMT build was refused honestly instead of launching to a silent black screen.
  - **Wine maintenance tools route through `BottleResolver`.** winecfg (Steam + manual) / regedit /
    retina no longer hard-code `paths.steamBottle` + `backend.wineBinaryPath`; new `BottleResolver
    .steamTool`/`.manualTool` → `ToolTarget`, and `runWineTool` takes a resolved `wine`. Retina also gates
    on a BOOTED prefix (`system.reg`) not the downloaded client, so it no longer reports success while
    silently skipping the write.
  - **Setup idempotency.** Core-fonts EULA is recorded by a dedicated marker (`.silo-installed/corefonts-eula`)
    so a partial-failure resume never re-prompts the already-accepted license; Source Han Sans marks a pack
    installed only when ≥1 `.otf` actually landed (a truncated-but-tar-OK archive is retried, not recorded).
  - Tests (+6): stale-pid-without-wineserver liveness; `playManual` 32-bit refusal; `BottleResolver`
    tool-targets + wineNotConfigured; core-fonts EULA-resume runs silent; SHS empty-extract not marked.
    `setSteamReady` test helper now stages/unstages the wineserver socket to model a genuinely-live bottle.
  - **Doc drift reconciled:** STATUS `## BLOCKED` + Handoff checklist purged of removed features (`stop()`,
    flat-10s grace, `.sharedSteamClient`/`.emulatorStub`, `Kegworks` placeholder repo); CLAUDE.md
    concurrency tier fixed (`BackendResolver`→`BackendChooser.choose`/`BottleResolver`, noted
    `dxmtMightHelp`'s PE read) and the models rule split into persisted vs FS-probe descriptors.
  - **Deliberately NOT changed** (documented decisions / test-load-bearing, not defects): the `.gptk`
    default on the pure `makePlan`/`EnvFlags.environment`/`runInstaller` (makePlan is the pure builder,
    always fed an explicit `graphics` by the launch methods); the four FS-probe model descriptors stay
    `Sendable/Equatable/Identifiable` (contract clarified rather than bloating them with unused `Codable`).
- **🪟 Setup installer windows: focus them + a cancel now stops setup (2026-07-12, `main`; `swift build` clean +
  zero warnings, 360 tests green).** Two onboarding annoyances the user hit during a real setup:
  - **Focus the license/installer windows.** A window Silo's forked `wine` opens (a Core Fonts EULA, an MSVC
    redist, the Steam installer) lands *behind* the still-active Silo, so the user can miss that it appeared at
    all. New `InstallerWindowFocuser` (`Sources/SiloKit/Support/`, behind a `GuidedInstallFocusing` protocol so
    the VM unit-tests with a spy) observes `NSWorkspace.didLaunchApplicationNotification` and `activate()`s the
    launched app whose executable lives under the Wine runtime root (`isWineApp`, trailing-slash guarded so
    `…/wine-dxmt` can't match `…/wine`). `SteamBottleViewModel` arms it per **user-guided** component step and
    disarms between steps / before the windowless warm-up / on exit. Fail-safe: an unmatched window just stays
    where macOS put it (today's behaviour) — never a regression. On-device-unverified (Wine absent on the dev
    box); the arm/disarm bracketing + the match predicate are unit-tested.
  - **Cancelling a font/redist installer now FAILS setup** instead of silently continuing with a
    half-provisioned bottle. Declining the first Core Font EULA, or a non-success MSVC redist exit (incl. a
    1602 user cancel), throws `BottleError.componentCancelled(component)`; `provisionComponents` rethrows it
    (was best-effort for everything but Steam). Nothing is marked, so the next Set up re-prompts that
    component. The VM surfaces it as a pause — "Setup paused — you cancelled the … installer. Run Set up again
    to finish." — not a hard failure.
  - Tests (+5): VC-redist cancel now asserts the throw; first-Core-Font decline throws + installs nothing +
    stops after the first font; `provisionComponents` rethrows a mid-set cancel (Steam never runs);
    `isWineApp` predicate; the setUp flow arms the focuser with the runtime root on the user-guided step, then
    disarms; `setupFailureMessage` cancel copy.
- **🎛️ Automatic graphics backend (GPTK ⇄ DXMT) for the shared Steam bottle (2026-07-11, `main`; `swift build`
  clean + zero warnings, 354 tests green).** Steam games are no longer GPTK-only: each has a per-game
  `GraphicsChoice` (`.auto`/`.gptk`/`.dxmt`, default `.auto`) and GPTK + DXMT games co-reside in the ONE Steam
  bottle. Investigation (local CrossOver 26 + web) confirmed CrossOver's "Automatic" is a proprietary online
  per-title DB (default → wined3d, unusable) and that backend selection is per-process env — so Silo's
  variant-runtime + per-launch-overrides design already matches, and Silo's Automatic is an **educated guess
  from the game binary + reactive learning** instead of a title DB.
  - **`BackendChooser`** (pure, `Sources/SiloKit/Launch/BackendChooser.swift`): `.auto` → 32-bit ⇒ DXMT (GPTK
    is 64-bit-only), else GPTK (the proven default; also the only D3D12 path). `dxmtMightHelp` reads the PE
    **import table** (`WindowsExecutable.importedDLLs`) to gate the reactive switch — fail-open (empty imports
    / dynamic `LoadLibrary` loaders → try DXMT), suppressed only when confident DXMT can't help (imports D3D12,
    or D3D9 with no D3D10/11).
  - **Reactive learning**: when the `GraphicsFallbackMonitor` detects "GPTK didn't engage" on an `.auto` game
    and DXMT is installed + might help, `play` persists `.dxmt` for that game ("Silo will use DXMT next time").
  - `GameConfig.graphics` (tolerant decode, `graphics` key — the legacy dual-bottle `backend` key stays
    ignored); `BottleResolver.steam(backend:config:)` routes a DXMT Steam game onto the DXMT variant clone in
    the SAME Steam prefix (unconfigured DXMT still throws `backendNotConfigured`); `play` picks the backend off
    the chooser (32-bit-on-explicit-GPTK still refused, now steering to DXMT); a **Graphics** picker
    (Automatic/GPTK/DXMT) added to the Steam game settings sheet. Fallback/refusal messages unified to steer to
    DXMT (Steam + manual both have a per-game Graphics setting).
  - Tests (+10): `BackendChooser` table + PE-import reader (synthetic PE32/PE32+ fixtures, fail-open);
    `BottleResolver.steam(backend:.dxmt)` → clone runtime + Steam prefix (+ refusal); `play` auto-routes a
    32-bit Steam game onto the DXMT clone in the shared prefix with winemetal seeded; reactive switch persists
    `.dxmt`; `GameConfig` graphics codec.
  - **Review fixes (2026-07-11, high-effort multi-agent review):** the Steam Graphics picker now actually
    persists (`GameSettingsViewModel.save` was dropping `graphics`); the reactive switch re-reads fresh config
    at fire time (can't clobber an explicit pin or write for an uninstalled DXMT) and only promises the switch
    when the write succeeds; the fallback message steers to DXMT only when it could help (no false steer for
    D3D12/D3D9-only); a 32-bit game routed to a 64-bit-only DXMT is refused up front (`BackendConfig
    .dxmtSupports32Bit`); `play` resolves the exe ONCE and hands it to `launchInBottle` (no double install-dir
    walk, decision + launch use the same binary); `BackendChooser.choose` is now pure (`is32Bit:` in). 355
    tests green.
  - **Quality pass:** the failure-only PE import read (`dxmtMightHelp`) is now lazy — computed in
    `handleGraphicsFallback` only when a fallback actually fires, never on a healthy launch; the reactive-learn
    logic is factored into named `handleGraphicsFallback`/`learnDXMT`/`fallbackMessage` methods (no dense
    nested closure); the `.gptk` default was removed from `BottleResolver.steam` / `launchInBottle` /
    `launchManualGame` so a future launch path can't silently land on GPTK (`makePlan` keeps its default — it's
    the pure builder, always fed `graphics` by those methods); the four copied test PE-byte builders collapsed
    into one `Support/PEFixture`. No polling loops (fallback detection stays kqueue-driven via
    `GraphicsFallbackMonitor`).
  - **On-device (Wine absent here):** (1) **co-residency** — with the bottle Steam up, launch a DXMT-routed
    game and confirm it joins the SAME wineserver (one `server-*` socket under `/tmp/.wine-$(id -u)/` or
    `$TMPDIR`), Steamworks connects, and the log shows DXMT's feature level; (2) a 32-bit Steam title (e.g.
    Overcooked 2) end-to-end via Automatic → DXMT (needs the both-ABI DXMT release asset — confirm i386 is
    published, else run `build-dxmt.yml`); (3) a known-good GPTK title unchanged; (4) a GPTK-failing DX11 title
    flips itself to DXMT and works on the second launch.
- **🚪 Phase 4 — quit leaves Steam + games running; PID-free bottle liveness (2026-07-10, `main`; `swift build`
  clean + zero warnings, 350 tests green).** Like CrossOver, Silo now LAUNCHES detached and never owns a
  launched process's lifecycle: quitting Silo no longer kills Steam or games, and there is no per-game Stop
  button, PID tracking, or exit observer.
  - **Removed:** the app-quit teardown (`AppEnvironment.terminateAllOnQuit` + the `RootView` willTerminate
    hook); `GameProcessCoordinator` (the PID/observer table); the per-game Stop button + running badge (tiles
    are just Play / Launching…); `SteamClientSession.stop`/force-quit + `SteamBottle.forceQuitSync`;
    `LaunchOrchestrator.stopGame`/`observeExit`/`resolvedExecutableName`; and the `ProcessLedger` PID shadow
    (+ the now-dead `observeExit`/`spawnDetachedForget`/`startTime`/`ProcessObservation` primitives). KEPT
    `isRunning`/`terminate` + `SteamBottle.forceQuit`/`shutdownSteam` for the first-run WARM-UP only (setup
    plumbing that owns a transient client PID locally to drive its download/relaunch loop).
  - **New `WineServerProbe`** (`Sources/SiloKit/Process/WineServerProbe.swift`): PID-free bottle liveness via
    the wineserver socket (`<tmp>/.wine-<uid>/server-<dev>-<inode>/socket`, keyed by the prefix's dev+inode —
    the identity wine itself uses). Replaces the ledger as the corruption guard: `blockedForBottleWork` /
    `anythingRunning` refuse a bottle move / self-update while ANY bottle's wineserver is live — INCLUDING a
    crash orphan (its socket persists), so the crash-orphan protection survives PID-free. `removeManual`
    refuses while the game's own bottle is live.
  - **`SteamClientSession` off PIDs**: `isRunning` = `SteamReadiness.isReady` (Steam's own registered
    `ActiveProcess` pid, not a PID Silo tracks); `ensureRunning` coalesces concurrent callers, skips a
    redundant relaunch when already ready (Steam single-instances anyway), and reports launch success.
  - **What the "wine" processes taught us** (winedevice.exe ×2, wineserver, wineloader when only Steam runs):
    the wineserver is the detached per-prefix daemon that outlives the launcher — so bottle liveness belongs
    to the SOCKET, not a PID Silo holds. That's the basis for both halves of this phase.
  - Tests: deleted the coordinator/ledger suites + every stop/kill/track test; added `WineServerProbeTests` +
    a fake-socket fixture; the gate tests drive a fake wineserver socket and the Steam tests drive readiness
    via `user.reg`. New: "quitting does NOT kill launched games or Steam."
  - **On-device (Wine absent here):** confirm the exact temp root wine uses for its socket (`/tmp` vs
    `$TMPDIR` vs `$XDG_RUNTIME_DIR` — all three are probed; verify the one this runtime uses) so the guard
    actually fires; confirm quitting Silo leaves Steam + a running game alive.
- **🪟 Phase 3 — correctly NAMED Dock tiles for Silo-launched Steam + games (2026-07-10, `main`; `swift build`
  clean + zero warnings, 371 tests green).** A bare `wine steam.exe` launch shows a Dock tile named "wine".
  macOS names a GUI process's tile from `[NSBundle mainBundle].CFBundleName`, resolved from the executable
  path AS INVOKED — so Silo now spawns each launch through a generated `.app` wrapper whose
  `Contents/MacOS/<name>` is a **symlink to the wine loader**: spawning that in-bundle path makes `mainBundle`
  resolve to the wrapper → the tile is named "Steam" / the game's name. Confirmed from the loader binary that
  this is safe: the macOS loader maps ntdll **in-process** (no preloader re-exec — no exec symbols; it
  `realpath`s `_NSGetExecutablePath` for lib discovery, which FOLLOWS the symlink to the real runtime, while
  CFBundle uses the UNRESOLVED invoked path), so a bare symlink yields BOTH the name AND correct lib
  self-location at once.
  - New `DockAppBundle` (`Sources/SiloKit/Launch/DockAppBundle.swift`): pure plist builder + `write` that
    (re)creates `<folder>.app` with the `MacOS/<exe>` symlink. No bundle icon — `winemac.drv` supplies the
    live tile icon from the game window at runtime; the wrapper only fixes the NAME.
  - `Silo.pinWineLoader` sets `WINELOADER`/`WINESERVER` to the REAL runtime (safe: the INITIAL process never
    re-execs the loader; only child procs do — so it must NOT be the symlink, or every child would be named).
    `makePlan` gains `launchVia`; `launchInBottle`/`launchManualGame` gain a `DockIdentity` (name + stable
    folder slug + `paths.dockAppsDir`). `SteamBottle.launchSteam` wraps the client as `Steam.app` (its
    `explorer /desktop=` root window owns the tile). Best-effort: a wrapper-write failure falls back to
    launching the loader directly (tile → "wine").
  - Wrappers live under `supportDir/DockApps` (always reachable — not the relocatable bottles drive).
  - Tests (+7): `DockAppBundleTests` (names via CFBundleName, no icon/LSUIElement, symlink target, idempotent
    repoint); `makePlan` launchVia (spawns the symlink + pins WINELOADER/WINESERVER); the DXMT-manual + Steam
    launch tests now assert the wrapper executable + pinned loader.
  - **On-device (Wine absent here):** confirm the Steam window's PID reports `<Name>` via
    `lsappinfo info -only name <pid>` and that a single primary tile appears (a stray `steamwebhelper` tile
    would be a child-coalescing follow-up — CrossOver solves that with a proprietary helper Silo doesn't have).
- **🧹 Post-Phase-4 — removed the "Create Desktop Shortcut" feature (2026-07-10, `main`; 344 tests green).**
  Per the user, the Desktop-shortcut feature is gone entirely (`GameAppShortcut`, `GameLibraryViewModel.makeShortcut`,
  `LaunchOrchestrator.prepareGraphics`, the tile menu item, and their tests) — which also moots the Phase 3
  follow-up (that standalone `.app` `exec`'d wine, so its tile read "wine"). Manual games launch from Silo
  (correctly named tile) or their own `winecfg`; no standalone launcher `.app`.
- **🔧 Phase 2 — default Wine config for the Steam bottle (2026-07-10, `main`; `swift build` clean +
  zero warnings, 364 tests green serial + parallel).** A vanilla `wineboot` prefix carries no
  `HKCU\Software\Wine\DllOverrides`, but games expect the standard Windows-compatibility set. Silo now applies
  its own **58-entry** default override set (the classic Wine default template) to the Steam bottle.
  - New `Silo.defaultDllOverrides` (`Sources/SiloKit/Steam/BottleDefaults.swift`) + `SteamBottle.applyWineDefaults`:
    builds a REGEDIT4 `.reg` and imports it with ONE `wine regedit /S` (cheaper than 58 `reg add`s), idempotent
    (`.silo-installed/wine-defaults` marker). Called in `setUp` right after `provision` ("Configuring the bottle…").
  - **Removed Silo's `d3dcompiler_47=native` override** (kept the DLL file) — the native DLLs
    (d3dcompiler_47 4.3 MB, msvcp140 643 KB, vcruntime140 179 KB) are present, so Wine's load order picks them
    up with **NO** override. Dropped the now-dead `setDllOverride` helper.
  - **MSVC unchanged** — Phase 1 already installs the redist without overrides. The redist places the real
    `msvcp140.dll` on this Wine (bug-57518 doesn't bite cx-26.x), so the winetricks force-native workaround
    (+ risky CAB-extract) is **not** needed.
  - Tests (+2): a completeness pin (the 58-entry set, and NOT msvcp140/vcruntime140/d3dcompiler_47/concrt140),
    the `regedit` import + idempotency, `installD3DCompiler47` now asserts NO override.
  - **On-device:** after a fresh setUp, confirm winecfg → Libraries shows the override set, `d3dcompiler_47`
    no longer appears, and `system32/msvcp140.dll` is the real 643 KB file.
- **📦 Phase 1 — bottle provisioning + 2-step onboarding (2026-07-10, `main`; `swift build`
  clean + zero warnings, `swift test` green serial + parallel, 360 tests).** The Steam bottle now installs its
  game-dependency component set in a fixed order, with the license-bearing pieces run as **user-guided**
  GUI installers (`ProcessRunning.run` blocks until the user closes the window). Onboarding collapses from 3
  steps to **2**: (1) import GPTK `.dmg`, (2) **"Set up"** → `AppEnvironment.runFullSetup()` chains it all.
  - **Ordered component model.** `BottleComponent` enum (`allCases` = the single source of truth for order) +
    per-component `isSatisfied`/`install` on `SteamBottle`, driven by `provisionComponents(wine:onPhase:)` —
    satisfied components are skipped (resumable/idempotent), best-effort per component except the terminal
    Steam install. Order: **Core Fonts → Source Han Sans → d3dcompiler_47 → MSVC x86 → MSVC x64 → msync →
    Steam**. `SteamBottleViewModel.setUp()` now: download Steam → `wineboot` → `provisionComponents` →
    `forceQuit` (black-window guard) → warm-up → webhelper wrap.
  - **Core Fonts** (`installCoreFonts` reworked): installed in the FIXED `Silo.coreFonts` order; the FIRST
    font runs its installer **bare** (shows the Microsoft EULA, blocks), the rest extract silently (`/T /C /Q`)
    — "user-guided initially then auto." Added a GitHub-mirror fallback URL (SourceForge is flaky).
  - **Source Han Sans** (new `installSourceHanSans`): all **4** language packs (J/K/SC/TC, ~360 MB, OFL, no
    prompt) — download → bsdtar extract → copy `.otf` into `windows/Fonts`; **per-pack markers** make the big
    download resumable.
  - **d3dcompiler_47** (new `installD3DCompiler47`): both ABIs, extracted from Microsoft's Windows-SDK CABs via
    Wine's builtin **`wine expand`** (no cabextract), 64-bit→`system32` / 32-bit→`syswow64` (Phase 1 added a
    native override here; Phase 2 removed it — the file's presence is enough). **⚠️ R2 (highest on-device risk):**
    whether `wine expand -F:<member>` pulls the named member on a real Mac — fallback is re-hosting the two
    redistributable DLLs as Silo release assets.
  - **MSVC redist** (new `installVCRedist`): x86 then x64, **user-guided** (no `/quiet` → license shown).
    **msync** is a no-op (env-only, always satisfied → skipped).
  - **🐛 On-device fix (2026-07-10): MSVC never showed its user-guided installer.** Root cause: `wineboot`
    pre-populates system32/syswow64 with tiny **fakedll** stubs for Wine's builtins (incl. `msvcp140.dll`),
    so the "is `msvcp140.dll` present?" marker read true on a fresh prefix and **skipped the redist entirely**
    — same latent bug for `d3dcompiler_47`. Fixed: MSVC now tracks a **Silo marker** (`.silo-installed/
    vcredist-{x86,x64}`) written only on a success exit code (0/3010/1638; a cancel 1602 re-prompts), and
    d3dcompiler is **size-gated** (real DLL is multi-MB vs the ~KB stub). +2 tests pin it (a fakedll stub no
    longer satisfies either; a cancel re-prompts). 362 tests green.
  - **Steam** install is now **user-guided** (`runSteamInstaller(userGuided:)` drops `/S`); `installSteam`
    (silent) kept for the CLI/tests. `downloadSteamInstaller` is a separate early step (fails fast on network;
    now creates the prefix since it runs before `wineboot`).
  - **Orchestrator** `AppEnvironment.runFullSetup()`: download Wine (if `!wineReady`, then **await** the
    default-persist so the DXMT match / setUp don't read a nil wine binary — R7) → download DXMT (if
    `!dxmtReady`) → `steamBottleVM.setUp()`. `setupBusy` drives the onboarding spinner. `OnboardingView` → 2
    `StepRow`s; `--setup-steam` CLI drives the whole chain.
  - **New constants** in `Silo.swift` (no `versions.env` change): corefonts mirror, Source Han Sans base +
    packs, MSVC `aka.ms` URLs, d3dcompiler CAB URLs + member ids.
  - **Tests (+9):** per-component (EULA-first fonts, 4-pack SHS + resume, `wine expand` d3dcompiler + override,
    user-guided MSVC no-`/quiet`, user-guided Steam no-`/S`), the ordered-driver sequence + skip-satisfied, the
    reworked `setUp` (user-guided Steam + `forceQuit` before warm-up), the pure `componentStatus` mapping, and
    `runFullSetup` skip-when-ready delegation. `createComponentMarkers` test helper added.
  - **Pending on-device validation (a real Mac + Wine/GPTK; not gating the commit):** R1 SteamSetup
    auto-launch black-window (forceQuit mitigation); **R2 `wine expand` member extraction**; R3 MSVC bug-57518
    (manual `msvcp140.dll`); R4 first-corefont bare EULA under Wine; R5 exact aka.ms redirect / SHS asset +
    OTF names; R6 MSVC DLL-override set.
- **🧹 Phase 0 — removed the DXMT Steam bottle; collapsed to a SINGLE "Steam" bottle (2026-07-10, `main`;
  `swift build` clean + zero warnings, `swift test` green serial + parallel, 351 tests).** First of a
  multi-phase restructure. The dual-Steam-bottle topology (a GPTK `SteamBottle` + a `SteamBottle-DXMT`, each
  its own Steam install/login) is gone — there is now ONE shared Steam bottle, GPTK-only for now, with no
  GPTK/DXMT tags on it. **DXMT the graphics *backend* stays** (manual/non-Steam games still pick it; the
  DXMT *runtime* is still installed via Settings → DXMT). Removed/collapsed:
  - `AppPaths.steamBottle(_:)` family → single no-arg `steamBottle`/`…ClientDir`/`…Exe`/`…CEFDir`/`…Log`;
    `"SteamBottle-DXMT"` dropped from `bottleDirNames`; `log(forAppID:backend:)` → `log(forAppID:)`.
  - `SteamApp.ID` composite `(appID,backend)` + `SteamApp.backend` → plain `id = appID`; discovery no longer
    tags a bottle backend. `GameID.steam(appID:backend:)` → `.steam(appID:)`. `GameConfig` un-keyed from
    backend (appID only; a legacy `backend` JSON key decodes-and-ignores — no data loss).
  - `AppEnvironment`: the per-backend `BackendServices` dict + `services(for:)` + `dxmtBottleVM`/
    `dxmtClientSession`/`dxmtSteamReady`/`gptkSteamReady` → one inlined `steamBottleVM`/`steamClientSession`;
    `steamReady` is the single gate.
  - `GameLibraryViewModel`: dropped `dxmtSession`, the cross-bottle co-residency guards
    (`activeSteamBackend`/`stopOtherSteamClients`/`activeBackend`/`runningBackend`), `steamInstalledBackends`
    set → `steamInstalled: Bool`, dual-bottle discovery + two-cards-per-title. `busyGames: Set<Int>`.
  - `SteamBottle`/`SteamClientSession`/`SteamBottleViewModel`: dropped the `backend` field, the sibling-seed
    fast path (`seedFromCompleteBottle`), and the cross-backend `SteamSetupGate` + "other bottle" wiring.
  - UI: the "Steam bottle (DXMT)" General-settings section, the whole DXMT-bottle onboarding step, and the
    GPTK/DXMT **backend tag on Steam cards** are gone; "Steam bottle (GPTK)" → just "Steam bottle"; the
    "Open Steam" toolbar is a plain button again. `DXMTManagerView` (runtime tab) kept. CLI `--setup-steam`
    is no-arg. A 32-bit Steam game (GPTK is 64-bit-only) now says "not supported yet" instead of steering to
    the removed DXMT Steam bottle.
  - Decisions (user): the whole optional DXMT onboarding section removed (runtime still in Settings → DXMT);
    an existing on-disk `SteamBottle-DXMT` is **left in place** (Silo just stops using it — no auto-delete).
  - Tests: dual-bottle/cross-bottle/seed/setup-gate cases (which asserted now-removed behavior) deleted;
    per-backend config + discovery cases rewritten to single-bottle; fallback-message assertions updated.
- **✨ Library status line is now transient — auto-dismisses (2026-07-08, `main`; shipped in 0.3.2).** The
  bottom status bar set `"Launched X."` once and never cleared it, so it lingered long after the game closed
  (the game card's running indicator cleared correctly via kqueue; only the status *text* was sticky).
  `setStatus` now schedules a self-clear (default 5s) and each new status cancels the prior message's timer,
  so a stale timer can never wipe a newer line (e.g. a graphics-fallback warning that legitimately replaced
  it). Scoped to the library bar; settings/manager panes keep their own `statusMessage`. +2 tests, 365 green.
- **🔁 Second adversarial sweep (post-0.3.0) — 8 more real bugs, all fixed (2026-07-08, `main`; serial +
  parallel green, 362 tests).** Prompted by "are there no more remaining fixes?" — a fresh three-lens review
  (ledger/gates, launch/co-residency, setup/readiness) that INCLUDED the just-shipped crash-orphan code found
  bugs file-local review missed. Commits `656f608`→`3ebcf11`:
  - **(HIGH) Durable ledger dropped an entry before confirmed death.** `terminateAllSync`/`stop`/`clear`
    removed optimistically right after a bare async SIGTERM — on a clean quit where the game outlived the
    signal, the next launch's gate saw no survivor → move/update over a live wineserver. Now removed ONLY on
    confirmed death (kqueue exit) or self-prune (once the PID is actually gone). The exact false-negative the
    ledger exists to prevent.
  - **(HIGH) Relocation vacuously "succeeded" when the current root was on an ejected drive** → persisted the
    new location + relaunched into an empty dir while the real bottles sat orphaned on the drive. Now refuses
    until `bottlesRootReachable`.
  - **(MED-HIGH) The gate was blind to in-flight work:** `isAnythingRunning` ignored the busy sets (a launch
    that claimed a bottle but hadn't spawned), and `anythingRunning` ignored a bottle mid-setup/warm-up. Both
    now count; the warm-up download client is also recorded in the ledger (crash-during-setup).
  - **(MED) Launches weren't blocked during a self-update** (ends in `exit(0)`, no teardown → orphan) and a
    move + update could overlap (both relaunch). `launchBlockedByBottles` now refuses during an update; the
    gate is mutually exclusive with a move/update in flight.
  - **(MED) openSteam/uninstall could race a cross-bottle `play` into TWO live Steam clients** (one account →
    Steam logs one out). `stop()` no-op'd against a client caught mid-spawn; it now cancels the in-flight
    launch and `startSteam` self-terminates if cancelled after the spawn.
  - **(LOW-MED) `makeShortcut` skipped the 32-bit-on-GPTK refusal** → a shortcut that launches to a
    wined3d-fallback failure with no steer. Now refused like `playManual`.
  - **(LOW) taskkill sibling-collision guard was case-sensitive** but wine's `/IM` isn't — `Game.exe` vs
    `game.exe` slipped through. Now case-folded.
  - **Verified sound (no change):** the `(pid, startTime)` reuse-proofing, the seed exclude-list + setup-gate
    (the two earlier user-found bugs can't regress), `ensureRunning` coalescing/readiness, ConfigStore
    recovery. Residual: a game that re-execs under a PID Silo never recorded still needs the on-device
    wineserver-lock probe (a Wine-verified handoff item).
- **🏛️ Architecture-level review before onboarding users — 4 themes, ~15 bugs, all fixed (2026-07-07, branch
  `gptk-path-review`; SERIAL + PARALLEL both green, 340 tests).** Three lifecycle-scoped adversarial reviewers
  (launch/co-residency, setup/discovery/onboarding, relocation/update/persistence) found cross-subsystem
  bugs that file-local review missed. Commits `62dde8f`→`093fbfc`:
  - **Theme A — co-residency was per-appID, must be per-backend.** `play`/`openSteam`/`uninstall` refused only
    the SAME title cross-bottle, but `stopOtherSteamClients` tears down the other bottle's client — so
    launching a DIFFERENT game in the other bottle killed a running game's Steamworks. Now
    `activeSteamBackend(excluding:)` refuses any cross-bottle Steam launch, checked+claimed before any await.
  - **Theme B — liveness was in-memory only; gates were start-only.** Per the user's call, quit (and
    self-update relaunch) now TEARS DOWN games + Steam clients (`terminateAllOnQuit`; retired the opt-in
    toggle), so nothing orphans and cross-session gates stay accurate. Update refused while anything runs;
    launches refused during a bottles move. **Crash-orphan residual now closed (2026-07-08)** by
    `ProcessLedger`: a crash-durable (pid, start-time) shadow of every process Silo spawns into a bottle
    (games + Steam clients). The relocation/update gate (`blockedForBottleWork`) also refuses while a PRIOR
    run's process is still alive; (pid, start-time) identity makes a reused PID never falsely block; fail-open
    + self-pruning; the durable probe runs only at the action gate, never a SwiftUI body. Remaining residual:
    a game that re-execs under a PID Silo never recorded (a wineserver-lock probe — needs Wine to verify).
  - **Theme C — "ready" was defined 3 ways; gates picked the weakest.** "Installed" now means the WARMED
    client (`hasWarmedClient`: steamui.dll + webhelper), not the bootstrapper; onboarding's GPTK step +
    `setupComplete` key on `gptkSteamReady` (DXMT-first can't mark GPTK done); removing a runtime reconciles
    `BackendConfig` (no sticky readiness against a deleted runtime); `refreshLibraryIfReady` re-syncs both ways.
  - **Theme D — ejected relocated drive** now shows a distinct `BottlesDisconnectedView` (not first-run
    onboarding); launches + `setUp` refuse when the root is unreachable (no phantom bottle on the boot disk).
  - **Bonus:** `BottlesRelocationCoordinator` uses the injectable app-bundle resolver, so relocation's
    `relaunch`/`exit(0)` no longer kills the SERIAL test run — the whole suite passes serially for the first
    time (the parallel `tee` had been masking failures). +co-residency/relocation/warmed-client tests.
  - **Sweep leftovers cleared (2026-07-08):** `taskkill /IM` basename collision FIXED (`stop` drops to a
    SIGTERM-only stop when a co-resident sibling shares the exe basename, else fires /IM); the crash-orphan
    residual FIXED (`ProcessLedger`, see Theme B); `terminateAllOnQuit` composition now has a dedicated test.
    Reviewed + consciously left: `strand-on-failed-delete` is already surfaced (removeManual /
    discardManualBottle show a Finder path); `isSharedSystemApp` is a documented LastOwner heuristic with no
    better single-manifest signal; `bottlesDisconnected` short-circuits to zero I/O in the default location
    and must stay live to detect drive ejection.
- **🐛 Adversarial correctness pass — 10 bugs fixed (2026-07-07, `swift build` clean + `Scripts/test.sh`
  green, +2 tests).** Two independent adversarial reviewers swept the GPTK bottle path for BUGS (not just
  rot). The GPTK core came back clean; the fixes (most-severe first):
  1. **Steam readiness race (GPTK, the one important core bug).** `SteamClientSession.ensureRunning` checked
     the `steamPID` fast path before joining an in-flight launch — so a 2nd Play during Steam cold-start
     returned "ready" before Steam had registered its `ActiveProcess` pid, and the game's `SteamAPI_Init`
     could lose to Steam's init. Now joins the in-flight launch (which owns the readiness wait) FIRST.
  2. **DXMT manual-game shortcuts never seeded `winemetal.dll` into the prefix.** `makeShortcut` called
     `makePlan` directly, bypassing `linkGraphics`/`installDXMTPrefixLoaders`; a shortcut made before any
     in-Silo launch produced a `.app` that fell back to wined3d and failed. New
     `LaunchOrchestrator.prepareGraphics` (launch-free graphics prep); `makeShortcut` now calls it. Test added.
  3. **Clone race + interrupted-clone reuse.** `RuntimeVariants.ensureClone` was check-then-act; two quick
     first-time DXMT launches could make the loser's copy-fallback hit EEXIST, and a hard-killed mid-clone
     left a partial tree later reused. Now clones into a `.cloning-<uuid>` staging dir published by atomic
     rename (loser reuses the winner's; a partial never becomes the clone).
  4. **GPTK importer leaked a mount** when `hdiutil attach` succeeded but the plist had no mount-point (the
     caller never received a URL to detach). `attach` now best-effort detaches the parsed `dev-entry`. Test added.
  5. **`overlayGPTK` partial-overlay masquerade.** A mid-copy failure could leave a fresh `d3d11.dll` (the
     witness) beside stale siblings, so the next launch's witness check wrongly skipped. Copy the witness LAST.
  6. **Webhelper wrap could strand a CEF dir** (real webhelper preserved as `_orig`, no `steamwebhelper.exe`)
     on a mid-op I/O failure → black login, no self-heal. Now stage-then-rename (byte copy first, swap by rename).
  7. **Stale `errno`** in the clone copy-fallback error message — now the underlying POSIX code, captured at
     the failure point.
  8. **`RuntimeManager.install` reinstall was non-atomic** — extracted in place and removed `dest` on a
     mid-extract failure (nuking an existing good install; also merged stale files on reinstall). Now extracts
     into a `.extracting-<uuid>` staging dir and publishes with an atomic rename.
  9. **`stripBundledSDL` only searched `lib/silo-bundled`** — a custom-repo runtime bundling libSDL2 elsewhere
     kept the winebus/SDL crash. Now walks the whole runtime tree.
  10. **`GraphicsFallbackMonitor` armed a kqueue watch even when the pre-check already fired** — now returns
      before arming, so no fd lingers.
  Ruled out after tracing: `stopGame`'s base-wine taskkill (correct — wineserver is prefix-keyed) and the
  double-overlay (harmless idempotent no-op). **Left as-is (documented):** the readiness kqueue watch on
  `user.reg` can miss an atomic rename-replace and fall back to the bounded 20 s failsafe — but it's
  on-device-validated as event-driven, degrades gracefully, and the only fix touches the shared `FileWatch`
  the log tailer also uses (wide blast radius for a case the evidence says doesn't occur).
- **🧹 GPTK-path quality pass — 5 review findings fixed (2026-07-07, `swift build` clean + `Scripts/test.sh`
  green, EXIT=0/"All tests passed").** A focused audit of the GPTK bottle path (deterministic core, launch
  pipeline, runtime pieces) found it largely clean; five items closed:
  1. **Dead pre-dual-bottle shims removed.** All five no-arg `AppPaths.steamBottle*` convenience vars
     (`steamBottle`/`ClientDir`/`Exe`/`CEFDir`/`Log`) dropped from the shipping type — four were unused in
     Sources, the one live caller (`GeneralSettingsView`) now passes `.gptk`; the four the test suite uses
     moved to `Tests/SiloKitTests/Support/AppPaths+TestSupport.swift`. Also removed the dead
     `RuntimeVariants.variantWine` (superseded by `prepare`/`ensureClone`; test-only) + its `cloneWine` helper
     and the now-orphaned test.
  2. **`ManualGame.gameConfig`** — the `GameConfig(appID: 0, …)` mapping was open-coded in two places
     (`LaunchOrchestrator.launchManualGame`, `GameLibraryViewModel.makeShortcut`); now one computed property.
  3. **Resolver output threaded explicitly.** `makePlan`/`launchInBottle`/`launchManualGame` gained an
     optional `wine:` param (defaults to `backend.wineBinaryPath`), so the VM feeds the resolved variant
     runtime directly instead of mutating a `BackendConfig` copy at three call sites; `linkGraphics` takes the
     wine explicitly too. Backward-compatible — every existing makePlan/pipeline test unchanged.
  4. **Test-only PID projections retired.** `GameLibraryViewModel.runningPIDs`/`manualRunningPIDs` (dictionary
     reshaping that existed only for the test suite) replaced by narrow `pid(for:)` accessors mirroring
     `isRunning`; the ~8 test sites migrated.
  5. **Doc fix:** `WineRuntimeLayout`'s no-arg `windowsModulesDir`/`unixModulesDir` were mislabeled
     "back-compat" — they're the live GPTK-x86_64-only overlay path (`overlayGPTK` uses them; `overlayDXMT`
     passes an explicit `WineArch`) — relabeled.
- **🖥️ High Resolution Mode: pair LogPixels with RetinaMode (2026-07-07, on-device validated).** The Retina
  toggle wrote only `HKCU\Software\Wine\Mac Driver\RetinaMode`, so turning it on made game/UI text render
  tiny (Wine renders at native backing pixels with no DPI compensation). That's the missing half of what
  CrossOver calls "High Resolution Mode" — it reports **192 DPI** alongside RetinaMode so the UI scales up to
  match. `WineTools.setRetinaMode` now writes the **coupled pair**: `RetinaMode` (y/n) **and**
  `HKCU\Control Panel\Desktop\LogPixels` (192/96), so retina is never tiny and the two can't drift; LogPixels
  is only ever written here (192 DPI on a non-retina bottle would just bloat the UI). Validated on-device in
  the DXMT bottle: Overcooked 2 runs on DXMT (feature level 11_1) crisp + legible. Two findings recorded:
  (1) **second monitor stays live in fullscreen** because Silo never enables `CaptureDisplaysForFullscreen`
  (Wine's default-off = non-capturing borderless fullscreen; capture=y is what blanks other displays).
  (2) **games must be launched via Silo, not the co-resident Steam client's Play button** — Steam runs on the
  BASE runtime with no DXMT override, so a game it spawns falls to wined3d → "None of the requested D3D
  feature levels" → `InitializeEngineGraphics failed` (see the `silo-steam-launch-gotcha` note).
- **🔎 Dependency + per-runtime audit vs AppleGamingWiki (2026-07-06) — two gaps closed, on-device validated.**
  - **Core fonts (dependency gap).** Wine ships no MS TrueType fonts (the bottle's `windows/Fonts` was
    empty), which the Wine-Steam community flags as blank/garbled text in the client UI + games. `setUp()`
    now installs Microsoft's redistributable "core fonts for the web" (the winetricks `corefonts` set,
    `Silo.coreFonts`) into BOTH bottles — downloaded from SourceForge's canonical mirror and extracted with
    **Wine's own IExpress `/T /C /Q`** (no cabextract/winetricks dependency; validated on-device →
    25 fonts: Arial/Times/Courier/Verdana/Georgia/Comic/Impact/Andale/Trebuchet/Webdings). Idempotent
    (`SteamBottle.hasCoreFonts` marker), best-effort per font, cleans up after itself.
  - **MetalFX was GPTK-only (per-runtime gap).** The per-game MetalFX toggle always emitted
    `D3DM_ENABLE_METALFX` — a no-op for a DXMT game. `EnvFlags.environment(graphics:)` is now backend-aware:
    GPTK → `D3DM_ENABLE_METALFX`, DXMT → `DXMT_METALFX_SPATIAL_SWAPCHAIN`. DXR stays GPTK-only (DXMT has no
    DX12/raytracing). `makePlan` passes the launch backend through.
  - **Verified already-correct:** GPTK env set complete (`ROSETTA_ADVERTISE_AVX`, `MTL_HUD_ENABLED`, DXR);
    `WINEMSYNC` (deliberately msync, not the wiki's esync — required for shared-bottle co-residency);
    per-runtime DLL overrides + D3DMetal-framework-in-DYLD (GPTK only) + cloned runtimes; Windows 10 both
    bottles; DXVK/VKD3D/Vulkan correctly N/A (Metal-direct); vcrun covered by Wine builtins + Steam's
    per-game installers. **Onboarding already lean** — the 3 steps map to 3 genuinely-required user actions
    (GPTK needs a manual Apple `.dmg`, can't be automated); no meaningful simplification available.
- **🩹 Steam-bottle warm-up: fold the first-run self-update into setup (2026-07-06, on-device validated).**
  Problem: after setup, the user's first Steam launch hit "failed to load steamui.dll", the second was a
  black login window, and only the THIRD reached login. Root cause: `SteamSetup.exe /S` installs only the
  ~2 MB bootstrapper; the real client (steamui.dll + CEF/steamwebhelper) self-downloads on first run, and
  the webhelper wrap races that download. Fix: `SteamBottleViewModel.setUp()` now runs a one-time **warm-up**
  (`SteamClientSession.warmUpUpdate`) that completes the download BEFORE the user's first launch, then wraps
  the webhelper against the now-existing CEF dir. Works for BOTH GPTK + DXMT bottles (setUp is shared),
  non-invasive (rootless `steam.exe`, no window pops up), with a real **progress bar** (parsed from Steam's
  `Downloading update (X of Y KB)` log). Validated on-device against the fresh DXMT bottle: 7.1 MB
  bootstrapper → **1.0 GB fully-installed client** (steamui.dll + wrapped webhelper), no rollback, no
  leftover processes. **The debugging took several real runs; each found a concrete bug** (recorded so the
  hard-won knowledge isn't lost):
  - `-silent` makes Steam start minimized and SKIP the first-run client download → dropped it (launch bare
    `steam.exe`, rootless).
  - "steamui.dll exists" fires MID-download (Steam extracts it early); shutting down then makes Steam roll
    the half-applied update all the way back. The reliable "done" signal is Steam's own **"Update complete"**
    log marker (a single launch does the whole download→install→commit).
  - Wine spams thousands of `msync_init Failed` lines that pushed Steam's progress lines out of any log
    tail → parse the WHOLE log (`SteamBottle.updateState`).
  - The bottle log lives OUTSIDE the client dir and persists across setups, so a stale "Update complete"
    fired completion instantly → `SteamBottle.resetLog()` at warm-up start.
  - `--setup-steam <gptk|dxmt>` CLI harness added (like `--import-gptk`) to run setup headlessly on-device.
  - Pending: on-device confirm the DXMT bottle's first real launch now lands on login (the whole point);
    commit is on `dxmt-dualbottle-fixes`. **Corefonts install (recommended follow-up) not yet done.**
- **🔧 Six dual-backend UX/correctness fixes (2026-07-06, branch `dxmt-dualbottle-fixes`, 5 commits,
  each `swift build` clean + `Scripts/test.sh` green; app assembles + smoke ok).** Reported from on-device
  use of the dual-bottle build. Note on the test gate: the parallel `Scripts/test.sh` `tee` can drop both
  `✔`/`✘` lines cosmetically, so each commit was ALSO verified with a full `swift test --no-parallel` run
  — the ONLY serial failure is the pre-existing, environment-dependent `installUpdateNoBundle`
  (`runningAppBundle()` resolves differently under `--no-parallel`; fails identically on `main`, unrelated
  to this work). Commits:
  - **A — runtime listings exclude DXMT variant clones; `remove()` cascades.** The DXMT variant runtime is
    an APFS clone `<base>-dxmt` created as a SIBLING in `Runtimes/` by `RuntimeVariants`; it carries both a
    wine binary AND the overlaid DXMT modules, so it surfaced in BOTH `installedWines()` and
    `installedDXMT()` (cross-listing the Wine + DXMT panes). `RuntimeVariants` now owns the ONE
    clone-naming source of truth (`cloneName(ofBase:backend:)` + `isVariantClone`, on `rawValue` not
    `badge`); both listings skip clones; a real `dxmt-*-cx*` tag is never flagged. `remove(name:)` cascades
    to the base's derived clone (dead weight once its base is gone — `ensureClone` keeps an existing clone
    forever). **Decision:** `setDefault` does NOT touch clones (re-derived per launch by `BottleResolver`).
  - **B — honest, backend-aware graphics-failure message.** The old "running on fallback graphics
    (wined3d)" implied Silo has a working fallback; it doesn't (the wined3d fallback is inside GPTK's own
    d3d11.dll and, for Overcooked-class titles, then fails device creation) and Silo deliberately has NO
    rerouting (deterministic backend⇔bottle rule). New pure, table-tested
    `graphicsFallbackMessage(name:backend:isSteamGame:dxmtAvailable:)`: a GPTK title is pointed at DXMT,
    adapting to whether the DXMT bottle/runtime is set up (read at detection time); a DXMT title admits the
    wined3d fallback likely failed → Settings → DXMT. `GraphicsFallback` doc comments corrected. Detection
    + the pure GPTK→D3DMetal launch path untouched.
  - **C — a title installed in BOTH bottles surfaces as two cards.** `load()` deduped by appID (first
    wins), hiding the second bottle's copy. Identity is now (appID, backend): `SteamApp.id` is a computed
    composite `ID{appID,backend}` (no persistence change) and `GameID.steam(appID:backend:)` carries the
    backend, so both cards render (each with its GPTK/DXMT `BackendTag`) and tracking/stop/monitors are
    per-copy. `play()` gains a cross-bottle guard BEFORE `stopOtherSteamClients` (never kill the running
    game's co-resident Steam; one account can't be in-game twice → explanatory status). **Busy/spinner is
    per-COPY** (`busyGames: Set<SteamApp.ID>`) so only the launching card's button spins — an earlier
    appID-keyed set made BOTH cards spin during a launch (fixed 2026-07-06); cross-bottle launch protection
    is separate via `activeBackend(ofAppID:)` (running OR mid-launch), so blocking the other copy no longer
    requires marking it busy. `uninstall()` routes `steam://uninstall` through the game's OWN backend
    session (the DXMT copy must reach the DXMT bottle's Steam). Per-game config/settings/log stay
    appID-keyed (shared; the copies can never run at once). **Known, out of scope (noted for a follow-up):**
    launching a *different* game in the other bottle still stops the first bottle's Steam client under a
    running game — pre-existing, orthogonal to this fix.
  - **D — both Steam bottles in Settings → General** ("Steam bottle (GPTK)" then "Steam bottle (DXMT)"),
    moved out of the DXMT tab. The DXMT tab is now runtime-only.
  - **E — ONE runtime-install flow for Wine + DXMT (kills the onboarding/settings duplication).** A
    `RuntimeKind` strategy (`.wine`/`.dxmt`: noun, download hint, release picker, installed-list, install
    fn) parameterizes a single `RuntimeViewModel`; a new `RuntimeInstall` value is the common shape of
    `WineInstall`/`DXMTInstall` for the VM + a shared `RuntimeInstalledSection` list row. `AppEnvironment`
    gains `dxmtRuntime` (matched to the configured wine at click time), wires its default to
    `applyDXMTLibDir`, seeds it in `bootstrap`; `downloadLatestDXMT`/`dxmtDownloading` deleted. The DXMT
    tab now mirrors the Wine tab (install latest / import folder / installed list with Set default +
    Remove); onboarding's DXMT step + status chain use `dxmtRuntime` with Wine's string templates.
    **Decision:** DXMT adopts-as-default only when none is set (Wine semantics, was always-adopt); first
    install still flips `dxmtReady` via `onDefaultChanged`. The convenience `RuntimeViewModel(manager:repo:)`
    = Wine kind, keeping every existing call site + test valid.
  - **Pending (needs a human / on-device):** a `Scripts/dev.sh` visual pass (both bottle sections in
    General; DXMT tab mirrors Wine; two cards for a dual-installed title; the honest Overcooked-2 message);
    merge `dxmt-dualbottle-fixes` → `main`.
- **🧹 Full-project cleanup COMPLETE (2026-07-02, 3 tiers — robustness, dedupe, structure; 12 phases,
  each landed green).** Branch `dxmt-dual-bottle-backend` merged to `main` (ff); all phases on `main`.
  **Final verification:** `swift build` zero warnings, **305 tests green**, `Scripts/build-app.sh`
  assembles + ad-hoc-signs `dist/Silo.app`, `SILO_SMOKE=1` run passes, `git status` clean.
  Remaining (needs a human/on-device): a `Scripts/dev.sh` visual pass over the deduped views (library
  grid, both settings sheets, both bottle sections) + the next `build-wine` CI dispatch exercises the
  shared wrapper-check script. Phase log:
  - **Phase 0:** `.dxmt-build/` + `.dxmt-build-fullrun.log` gitignored (670 MB build artifacts).
  - **Phase 1:** `ConfigStore` recovery copy — every save refreshes `config.json.bak`; a
    present-but-corrupt primary restores the last good save (and self-heals the primary) instead of
    silently wiping all state. A *missing* primary still resets (deliberate).
  - **Phase 2:** swallowed errors surfaced. `DiscoveryEngine` distinguishes an *unreadable* primary
    library (`libraryUnreadable`, thrown) from the benign no-library-yet (`steamDirNotFound`, silently
    skipped); the library shows a per-bottle failure status (or `.error` when nothing else can show —
    LibraryGridView's error case is now reachable). `GameSettingsViewModel.save() -> Bool` +
    `errorMessage` (sheet only dismisses on success). A failed `lastPlayed` write after launch says the
    config is unwritable. `deleteBottle` failures say "remove it in Finder: <path>". `resolveMessage`
    maps the whole launch stack (exe-not-found / wineboot / DXMT-clone / linker-source-missing) to
    actionable text and all catch-sites route through it. 282 tests green.
  - **Phase 3:** correctness fixes. (1) **Manual-game shortcuts route through `BottleResolver`**
    (`GameLibraryViewModel.makeShortcut`, replaces `AppEnvironment.makeManualGameShortcut`) — a DXMT
    game's Desktop `.app` now snapshots the DXMT variant runtime + overrides instead of silently using
    the base/GPTK env; failures surface in the status bar. (2) Bottle tools (`setSteamBottleRetina` /
    `openWineTool`) take a `GraphicsBackend` (default `.gptk`) so the DXMT bottle can get Retina/winecfg
    (UI row lands with Phase 7's shared component). (3) `GameAppShortcut` writes atomically.
    (4) `deQuarantine` returns a `HardeningOutcome`; `RuntimeManager.lastHardeningIssue` +
    GPTK-import `onWarning` surface a failed de-quarantine/re-sign at install time ("Gatekeeper may
    refuse…") instead of a cryptic launch failure (new `LockedBox` Mutex util). (5) `LogTailer.start`
    creates/reads the log OFF the main actor (generation-guarded against stale arms). 287 tests green.
  - **Phase 4:** no more sync disk probes in SwiftUI body evaluation (bottles can live on a
    slow/disconnected external volume). `GameLibraryViewModel.steamInstalledBackends` = off-main cache
    (probed by `refreshSteamInstalled()`, called by every `load()`); `steamReady`/`steamInstalled(_:)`
    + `AppEnvironment.dxmtSteamReady` read it. `SteamBottleViewModel.steamInstalled` cached the same way
    (`refreshInstalled()` at bootstrap; `setUp` sets it). **Invalidation wiring:** `onSteamInstalled`
    fires after a fresh install → AppEnvironment reloads the library, so the onboarding gate flips
    without a relaunch (pinned by a wiring test — a missed invalidation would stall onboarding).
    290 tests green.
  - **Phase 5:** the co-residency sync rule (`WINEMSYNC=1`, strip `WINEESYNC`) now lives in ONE place —
    `Silo.enforceMsync` / `msyncWineEnvironment` — adopted by all five sites that each rebuilt it
    (`makePlan`, `stopGame`, `runWineTool`, `WineTools.environment`, `SteamBottle.steamEnvironment`).
    Zero behavior change (pinned by the exact env assertions across those suites). 292 tests green.
  - **Phase 6:** `GraphicsLinker` mechanics dedupe — `isGPTKModule`/`isDXMTModule` parameterize one
    `isOverlayModule(_:prefixes:)`; the witness idempotency check and the per-dll+`.so` copy loop are
    shared (`witnessMatches`, `copyModules`). SEMANTICS untouched: GPTK keeps its exact choreography
    (pre-witness framework-link self-repair → copy → re-link; no `wineWinDir` creation), DXMT keeps its
    dir creation. Pinned by the idempotency/self-repair/symlink suites + new direct helper tests.
    294 tests green.
  - **Phase 7:** view dedupe. `GameTileCard` = the one library-tile chrome (artwork band, three-state
    Play/Launching/Stop button, menu, hover treatment) — Steam + manual tiles now inject only their
    artwork/subtitle/menu/confirmations. `PerformanceFlagsSection` + `LaunchOptionsSection` shared by
    both settings sheets (manual sheet gains the guidance footers). `SteamBottleControls` = the one
    Setup/Launch/Reset-login/log block for the GPTK + DXMT settings sections; the **DXMT section gains
    a Repair row** (winecfg/regedit/control on the DXMT bottle, the Phase-3 backend-aware tools) and
    the **Retina toggle now writes the registry key into EVERY installed bottle** (one preference, both
    bottles consistent). No view tests per repo convention; logic unchanged (VM suites). 294 green.
  - **Phase 8:** scripts dedupe. `Scripts/check-webhelper-wrapper.py` = the ONE load-bearing CEF-flag
    guard (was duplicated between `build-wine.sh` and `build-wine.yml` — a drift there ships a broken
    Steam login); verified on synthetic pass/fail PEs. `Scripts/bootstrap-x86-brew.sh` = the shared
    Rosetta + x86_64-Homebrew bootstrap for `build-wine.sh` + `build-dxmt.sh`. `bash -n` + YAML-parse
    clean; CI proper validates on the next workflow dispatch. Toolchain pins untouched.
  - **Phase 9:** `GameProcessCoordinator` — the live-process bookkeeping (PIDs, kqueue exit observers,
    graphics-fallback monitors) moved out of `GameLibraryViewModel` into SINGLE tables keyed by
    `GameID{.steam(appID)|.manual(uuid)}`, replacing the four parallel Steam/manual dictionaries + 8
    observe/exit/clear/watch methods. The VM's public API (`isRunning`/`isBusy`/`isAnythingRunning`/
    `terminateAllSync`) is unchanged (zero view edits); `runningPIDs`/`manualRunningPIDs` remain as
    computed projections so the 507-line VM test suite passed UNMODIFIED. New coordinator tests pin the
    pid-match stale-exit guard, re-track cancellation, clear-stops-monitor, and exact-PID terminate.
    300 tests green.
  - **Phase 10 (a/b/c):** AppEnvironment decomposition, three green commits. **(a)** `BackendServices`
    = one keyed bundle (bottle + client session + settings VM) per `GraphicsBackend`, built in a loop
    (killing the gptk/dxmt construction copy-paste); pre-bundle names kept as computed forwards so
    views/tests were untouched. **Bonus fix:** `anythingRunning` now checks EVERY backend's session —
    a live DXMT Steam client blocks bottle relocation like the GPTK one. **(b)** `UpdateCoordinator`
    (`env.updates`) owns the inline self-update flow + its state. **(c)** `BottlesRelocationCoordinator`
    (`env.bottles`, in Provisioning/ next to `BottleRelocator`) owns the move flow;
    relocation-via-relaunch design unchanged; `isBlocked` late-bound to `env.anythingRunning`.
    AppEnvironment is now ≈300 lines of composition + thin orchestration. 301 tests green.
  - **Phase 11:** `RuntimeVariants` direct tests (the one real coverage gap): GPTK prepares in place
    (no clone), DXMT clones to `<root>-dxmt` + overlays the CLONE only, an existing clone survives
    re-prepare (idempotency — a re-clone would wipe in-clone state), `variantWine` is pure path math.
    305 tests green.
- **🩹 Two follow-up fixes (2026-07-05):**
  - **Runtime install no longer ad-hoc re-signs.** The install hardening ran `codesign --force --sign -
    --deep <runtime-dir>`, which ALWAYS failed (`bundle format unrecognized` — a runtime root is a plain
    `bin/lib/share` tree, not a bundle) and surfaced a scary "couldn't re-sign… Gatekeeper may refuse"
    warning after the cleanup made hardening report its result. Re-signing is also unnecessary: the
    runtimes are x86_64 (run unsigned under Rosetta) and GPTK's D3DMetal must keep Apple's signature.
    Removed the whole re-sign path (`reSign` param, the codesign branch, `HardeningOutcome.signed`,
    `RuntimeManager.harden`); `deQuarantine` now only strips `com.apple.quarantine` (the load-bearing
    step). Warnings now fire only on a genuine de-quarantine failure.
  - **`Scripts/test.sh` now fails when tests fail.** `swift test` under the CLT framework-search-path
    invocation printed Swift Testing failures but exited 0 on a full-suite run (verified Swift 6.3.3) —
    and `release.yml` gates publishing on this script, so CI could ship a broken build. test.sh now tees
    output and exits non-zero if any `✘` failure line appears OR swift test itself errors. Verified: clean
    → exit 0, deliberate failure → exit 1.
- **🪟 Settings UX pass (2026-07-05):** DXMT is now its own **runtime tab** (`DXMTManagerView`)
  alongside Wine + GPTK — Settings tabs are General · Wine · GPTK · DXMT. The whole DXMT concern
  (runtime download/import + its Steam bottle + repair tools) moved out of the General tab into the
  DXMT tab, so General is just the primary Steam bottle, bottle tools, bottle location, and updates.
  Trimmed explanatory captions across onboarding + settings (kept labels, status/error messages, and
  warnings) to cut visual clutter. 305 tests still green; app assembles + smoke ok.
- **🧩 DXMT as a second graphics backend — dual-bottle feature built end-to-end (2026-06-30, 267 tests green).**
  Reverses the GPTK-only stance (and M87's DXVK removal) per the user's design; `CLAUDE.md` "Graphics
  backends" rewritten to match. Branch `dxmt-dual-bottle-backend`. **Done + green:**
  - **Deterministic core (backend ⇔ runtime ⇔ bottle):** `GraphicsBackend{gptk,dxmt}` = single source of
    truth (per-backend `dllOverrides`/`overlaysExternalFramework`); `makePlan` emits exactly one backend's
    builtin set (determinism test: DXMT never leaks GPTK's). `GraphicsLinker.overlayDXMT`. `RuntimeVariants`
    (GPTK in place; DXMT = APFS clonefile clone + overlay) + `BottleResolver` (the one `(game,backend) →
    {prefix,wineBinary,graphics}` dispatch; refuses an unconfigured secondary backend).
  - **Models:** `ManualGame.backend` (tolerant decode) + `SteamApp.backend` (discovery-derived).
  - **Manual games:** `playManual` → resolver → a DXMT manual game runs on its cloned DXMT runtime in its
    own bottle. Backend picker in Add-a-Game + settings.
  - **Two Steam bottles:** `AppPaths.steamBottle(_:)` → `SteamBottle` (GPTK) / `SteamBottle-DXMT`.
    `SteamBottle` + `SteamClientSession` are backend-aware; `AppEnvironment` runs a GPTK + a DXMT bottle/
    session. `play/stop/openWinecfg` route by `game.backend` (DXMT Steam game → DXMT bottle on `/wine-dxmt`,
    only that bottle's client online). Discovery scans BOTH bottles, tags each game. Steam clients run on
    base wine (CEF; the co-resident game picks the variant — shared wineserver). **No login sync** (machine
    tokens are per-prefix → sign into each bottle once, by design).
  - **UI:** per-card backend tag on EVERY library card (Steam + manual); onboarding "Older games (DXMT) —
    optional" section + a General-settings DXMT section. `GraphicsFallback` backend-aware.
  - **DXMT runtime delivery:** **auto-download** from Silo's Releases (`AppEnvironment.downloadLatestDXMT`
    → `RuntimeManager.installDXMT`, reusing the Wine downloader engine — SHA-256 verify + extract +
    de-quarantine/ad-hoc-sign) OR manual folder import. One-click "Download…" in onboarding + Settings.
  - **Decision:** GPTK keeps the existing `SteamBottle` dir (no migration of the multi-GB prefix); DXMT is a
    sibling. Dropped the plan's `SteamBottle-GPTK` rename + `SteamLoginSync`.
  - **DXMT build — BUILDS on-device (macOS 26 Tahoe + Xcode 26.6, 2026-06-30):** `Scripts/build-dxmt.sh`
    (local) + `.github/workflows/build-dxmt.yml` (CI) build **DXMT v0.72 from upstream `3Shain/dxmt`** (the
    version CrossOver 26 bundles) against the published `wine-cx-*` CrossOver Wine, via DXMT's canonical
    Meson build, x86_64 to match the Wine. Full `meson compile` succeeds; `dxmt.tar.xz` (6.5 MB) ships
    `x86_64-windows/{d3d11,dxgi,d3d10core,winemetal}.dll` + `x86_64-unix/winemetal.so` (all builtin) — the
    exact tree `importDXMTRuntime`/`overlayDXMT` expect. Pins in `versions.env`. Real bugs fixed while
    validating:
    - **Toolchain:** llvm-mingw (clang) is REQUIRED — v0.72 doesn't compile with Homebrew GCC-mingw (tested:
      `std::setfill`/libc++ deps). It's DXMT's own pinned, intended toolchain.
    - **Native clang:** pin `/usr/bin/clang -arch x86_64` via a meson native file — llvm-mingw/llvm@15 both
      ship a bare `clang` that shadowed the Apple clang → `ld: library 'System' not found`.
    - **Metal:** Xcode 26 ships `metal` but its toolchain is a separate ~688 MB component; fetch it + probe
      an actual compile (a `-f metal` check is insufficient).
    - **Layout:** `-Dwine_builtin_dll=true` (v0.72 defaults false → d3d in system32); package the
      `x86_64-windows` + `x86_64-unix` sibling dirs.
  - **Decision:** GPTK keeps the existing `SteamBottle` dir (no migration of the multi-GB prefix); DXMT is a
    sibling. Dropped the plan's `SteamBottle-GPTK` rename + `SteamLoginSync`.
  - **PENDING (final on-device):** publish `dxmt-v0.72-cx26.2.0` (build-dxmt chained off wine-autoupdate, or
    `gh release`), Download it in Silo → Settings → DXMT, then confirm DXMT renders Overcooked 2.
- **✨ Tier-1 features from the Whisky study (2026-06-30, 239 tests green).** Five features mined from
  Whisky (the closest analog launcher) + Apple's GPTK materials, each with tests:
  1. **Retina/HiDPI toggle** for the Steam bottle (`WineTools.setRetinaMode` → `HKCU\…\Mac Driver\RetinaMode`;
     persisted in `BackendConfig.retinaMode` with a tolerant decoder so old config never wipes). Settings →
     General → "Bottle tools". The standard fix for wrong-sized game windows.
  2. **Wine repair tools** (winecfg / regedit / Control Panel + "Reveal Bottle in Finder") — escape hatch to
     fix a prefix by hand. Routes through the existing `LaunchOrchestrator.runWineTool`, which gained
     `WINEMSYNC=1` (shares the bottle's wineserver, no 2nd-server fork — also fixes the existing callers).
     `WineTools` is now registry-only (no duplicate tool-launcher).
  3. **Structured launch-log header** (`LaunchPlan.logHeader`, pure): every launch log opens with the
     resolved exe/args/cwd/env (sorted), written before spawn → a black-window report is self-explanatory.
  4. **Opt-in kill-on-quit** (Settings toggle, default off): `RootView`'s `willTerminate` hook →
     `GameLibraryViewModel.terminateAllSync` SIGTERMs only the games Silo launched, never the co-resident
     Steam client (test-verified).
  5. **PE icon extraction for manual games** (`PEIcon`, clean-room PE/.rsrc/.ico parser, bounds-checked):
     manual (non-Steam) games now show their `.exe`'s real icon in the grid (parsed off-main, cached). Steam
     games keep cover-art.
  6. **Game-Mode `.app` shortcut** for manual games (`GameAppShortcut`): "Create Desktop Shortcut" writes a
     standalone `.app` (categorized `public.app-category.games` → macOS Game Mode) that execs wine directly
     with a snapshot of the real launch env. Steam-game shortcuts deferred (need co-resident orchestration).
  Verified earlier vs Whisky: its `WINEESYNC`-under-msync quirk is GONE in GPTK 4 (NOT adopted); skipped
  DXVK/winetricks/custom-registry-UI/CLI per Silo's constraints.
- **🟢 GPTK D3DMetal CONFIRMED working — it IS Silo's active graphics path (2026-06-30).** Decisive
  on-device positive control: **We Were Here (582500)** launched co-resident under GPTK with verbose
  logging renders **D3D11 through D3DMetal**, proven by THREE independent signals (not a single-signal
  overclaim): (1) `d3d11.dll` + `dxgi.dll` load as **`builtin`** (GPTK's overlaid DLLs, not the native
  wined3d redist copies); (2) its Unity `Player.log` reports `Direct3D 11.0 [level 11.1]`, adapter
  **"AMD Compatibility Mode (ID=0x66af)"** — D3DMetal's signature fake adapter (wined3d-on-MoltenVK would
  report "Apple M4 Pro"); (3) **ZERO** wined3d/Vulkan/dlopen/feature-level signatures across 405 verbose
  lines (wined3d ALWAYS prints `err:winediag:…Using the Vulkan renderer` — absent). So the M83 "Bloons
  renders" gate is **vindicated**, the `GPTK-4.0_beta_1` + `wine-cx-26.2.0` pairing works, and the
  dlopen-layer fix (`linkD3DMetalFramework` symlink, self-repairing) holds.
  - **"How did wined3d slip in?" — it didn't.** wined3d lives *inside Apple's GPTK `d3d11.dll`* (built
    from wine d3d11 source + a D3DMetal backend + a `unix_call_fallback`). Silo is GPTK-only (DXVK removed
    M87) and never added a wined3d path. The fallback is GPTK's own, triggered only when a specific game's
    D3DMetal device-creation fails.
  - **Overcooked! 2 is a GAME-SPECIFIC exception, not a global failure.** Its `D3D11CreateDevice` via
    D3DMetal fails (opaque — inside closed GPTK; `d3dm_print`/os_log give nothing), so GPTK's d3d11 falls
    to its internal wined3d → `None of the requested D3D feature levels is supported` → "failed to
    initialize graphics." We Were Here (same Unity/D3D11 family) succeeds, so this is Overcooked-specific.
    **Prime lever: a different / non-beta GPTK version** (user can supply other `.dmg`s) — the beta likely
    matters for this class. RULED OUT for the global path: arch, native-redist shadowing, Metal-unavailable,
    dlopen. **Correction of my prior STATUS:** "device creation STILL fails (UNRESOLVED, casts doubt on
    whether GPTK renders ANYTHING)" was overgeneralized from Overcooked alone and is now disproven.
  - **Verbose wine logging for local builds (07c1c1e):** `Silo.wineDebug` = `+loaddll` locally, `-all`
    under CI (gated on `SILO_QUIET_WINE`, set by `build-app.sh` only when `$CI`). `WINEDEBUG=-all` had been
    *hiding* the very fallback `fixme:winediag` signatures the `GraphicsFallback` guardrail keys on — so the
    guardrail can now actually fire in dev. Shipped app stays silent automatically.
  - **Guardrail (shipped, working):** `GraphicsFallback` + `GraphicsFallbackMonitor` surface "GPTK didn't
    engage — fallback graphics" for the failing class instead of a silent "Launched". 224 tests green.
  - **GPTK 4 best-practice investigation (2026-06-30, read Apple's docs + cloned `apple/game-porting-toolkit`).**
    Key correction to the premise: **GPTK 4 is a NATIVE-Metal-porting toolkit** (AI agent skills + Metal
    Shader Converter + metal-cpp + native samples; prereqs macOS 27 / Xcode 27). The Windows-game
    "evaluation environment" (the D3DMetal that Silo overlays) is positioned as a **developer triage/eval
    tool**, not a documented end-user runtime. The repo has **ZERO** Wine/D3DMetal launcher-integration
    guidance (grepped the whole tree) — the only launch-env vars Apple documents are Metal-level
    (`MTL_HUD_ENABLED`, `MTL_HUD_LOG_ENABLED`, `MTL_CAPTURE_ENABLED`). So there is **no Apple reference
    implementation to "match"** for Silo's overlay-into-CrossOver-wine approach; Silo's launch env already
    matches the de-facto launcher standard (WINEPREFIX iso, WINEMSYNC, `ROSETTA_ADVERTISE_AVX=1` default-on,
    DYLD→lib/external, builtin d3d overrides, the D3DMetal.framework symlink) and is **proven working**
    (We Were Here). Overcooked-class device-creation failures are **D3DMetal's own feature/format limits**
    (Apple's `debugging-rendering-issues` skill flags Apple-GPU format gaps, e.g. `DXGI_FORMAT_D24_UNORM_S8_UINT`
    is not universally supported) — NOT a Silo implementation bug. Levers for that class: a different/non-beta
    **GPTK 4** build, or per-game Unity graphics args (`-force-feature-level-11-0` / `-force-d3d11-no-singlethreaded`).
- **🏷️ Release v0.2.1 (2026-06-29).** Patch over v0.2.0. (a) **Adversarial multi-agent quality audit**
  closed in four tiers — P0: readiness **TOCTOU** fixed (kqueue is edge-triggered; re-check after arming) +
  the M114 event-driven gate now tested **live** (`FileWatch` + readiness, previously never run with
  `readinessTimeout>0`); P1: `makePlan` exhaustiveness gaps (WINEDLLOVERRIDES `;`-merge, perf-flag
  propagation) + `BottleRelocator` failure paths (rollback, non-writable dest) covered, `play()` now
  surfaces a Steam-couldn't-start failure instead of launching against a dead client; P2: stale docs fixed +
  dead public surface removed (`installLocation`, `SteamBottle.isProvisioned`, `SteamStoreDetails.categories`
  /`.directXVersion`) + `KeyValuesParser` depth cap (no stack-overflow on hostile `.acf`) + manifest size
  guard; P3: PID maps encapsulated, denylist also strips `extra`, `..`-escape guard on relative exe, store
  fetch via `requireHTTPS`, new `RuntimeHardening`/`Filesystem` tests. **216 tests / 36 suites green; clean
  build.** (b) **GitHub Pages site** (`docs/`, Velox-style) — landing page at mikaelhug.github.io/Silo.
- **🏷️ Release v0.2.0 (2026-06-29).** Minor bump from 0.1.1 via `versions.env`. Highlights since 0.1.1:
  **manual non-Steam .exe games** (each in its **own isolated bottle**), **redistributables hidden**
  (`LastOwner==0`), **relocatable bottles** (move to another disk/external drive — % progress, exFAT guard),
  **versions.env single-source-of-truth**, **fully event-driven** (every sleep/poll removed; readiness via a
  kqueue watch on Steam's `ActiveProcess`), and a compact fixed-size **Settings** window. 202 tests / 32
  suites green; clean build (no warnings). Code/runtime production-quality (0% idle CPU, ~50 MB, no leaks);
  remaining ship-to-others gaps are on-device validation + notarization (human-gated), not code.
- **✅ M114 — removed every sleep/poll; readiness is now event-driven.** No fixed waits anywhere:
  - **Cold-start 10s grace → gone.** `SteamClientSession` now resolves the instant the co-resident Steam
    is ready via a **kqueue watch on the prefix's `user.reg`** for Steam's `ActiveProcess` pid (exactly what
    a game's `SteamAPI_Init` reads) — `SteamReadiness` (pure parse, unit-tested) + the reusable `FileWatch`.
    A cold launch waits only as long as Steam actually takes, not a flat 10s. The one remaining `Task.sleep`
    is a **bounded failsafe** (`readinessTimeout`, default 20s) that only fires if the signal never arrives
    (so a wrong signal can't hang a launch) — it is NOT the mechanism.
  - **Status auto-dismiss (6s) → gone:** the status bar shows the last action until replaced (no timer).
  - **Update-check spinner floor (700ms) → gone:** the spinner reflects the real check duration.
  - **Log-viewer throttle (150ms) → gone:** replaced with timer-free per-main-actor-turn coalescing (still
    event-driven, still coalesces bursts). Extracted `FileWatch` to `Support/` (shared by the log tailer +
    the readiness watch).
  - 202 tests / 32 suites green; clean build (no warnings); app reassembled.
- **✅ M112/M113 — single source of truth for versions (`versions.env`, Velox-style).** The app version was
  hard-coded in `Silo.swift` AND duplicated as a fallback in `build-app.sh`. Now `versions.env` (repo root)
  is the ONLY place a version is edited — `SILO_VERSION`, `SILO_GITHUB_REPO`, `CROSSOVER_VERSION` (the
  CrossOver FOSS wine-build input). `Scripts/gen-versions.sh` mirrors it into the committed (generated,
  DO-NOT-EDIT) `Sources/SiloKit/Versions.swift` (`Versions` enum); `Silo.version`/`updateRepo`/`wineRepo`
  read from it. `build-app.sh` regenerates + sources `versions.env` (dropped the grep + hard-coded version
  fallback); `build-wine.sh` defaults its CrossOver version to `CROSSOVER_VERSION`. A unit test fails if
  `Versions.swift` drifts from `versions.env` (verified). M113: scrubbed coincidental version literals from
  update test fixtures (arbitrary "current"/decoy-release versions that happened to equal the live one) so
  the live version lives ONLY in `versions.env` + its generated mirror. 197 tests / 31 suites green; clean
  build; app reassembled (the Info.plist version flows from the env).
- **✅ M111 — bottle move now has a progress bar + refuses exFAT/FAT.** Building on M109–M110:
  - **Progress bar.** `BottleRelocator` now does a byte-counting recursive copy for cross-volume moves
    (same-volume stays an instant rename) — preserves symlinks (a Wine prefix is full of them), sums total
    bytes up front, and reports a throttled `0...1` fraction. `AppEnvironment.bottlesProgress` drives a
    determinate `ProgressView` with a % label in Settings → Bottles (indeterminate spinner until the first
    fraction). Rollback unchanged (sources removed only after every dir copies).
  - **exFAT guard.** `Filesystem.isFATFamily` (via `statfs` `f_fstypename`) — `moveBottles` refuses an
    exFAT/`msdos`/`vfat` destination ("can't hold a Wine bottle, no symlink support — reformat as APFS / Mac
    OS Extended") rather than silently creating a broken prefix. Injectable check for tests.
  - 195 tests / 30 suites green; clean build (no warnings); app reassembled.
- **✅ M109–M110 — bottles are relocatable (move to another disk / external drive).** App state
  (config/logs/runtimes) stays under Application Support, but the **bottles** (Steam + every manual game's)
  now live under a configurable `AppPaths.bottlesRoot` (default = supportDir).
  - `BottlesLocation` persists the chosen root in a tiny file read SYNCHRONOUSLY at startup (`AppPaths.
    standard`), so every derived bottle path is correct from the first frame (M109).
  - `BottleRelocator` does a validated old→new move (writable + not-occupied checks; cross-volume
    copy+delete; best-effort rollback so it never half-relocates) (M109).
  - `AppEnvironment.moveBottles(to:)` / `resetBottlesLocation()`: refuse while anything's running, relocate
    off the main actor, persist, then **relaunch** to adopt the new root everywhere (AppPaths is injected
    by value). `anythingRunning` gate (M110).
  - UI: **Settings → General → Bottles** — shows the location (+ an "isn't reachable, is the drive
    connected?" warning when a relocated drive is ejected), **Move…** (folder picker → `<chosen>/Silo
    Bottles`), and **Reset to Default**; a spinner while moving (M110).
  - 193 tests / 30 suites green; clean build (no warnings); app reassembled.
- **✅ M107–M108 — each manual (non-Steam) game now runs in its OWN isolated bottle.** Steam games still
  share the one Steam bottle (Steamworks needs co-residency), but manual games no longer do — each gets a
  private Wine prefix at `~/Library/Application Support/Silo/ManualBottles/<uuid>` (own registry/drive_c/
  winecfg), so they can't pollute each other or Steam.
  - `WinePrefixProvisioner` (M107) = reusable `wineboot --init` for any prefix; `SteamBottle` delegates to
    it (DRY). `AppPaths.manualBottle(id)`.
  - VM (M108): `ensureManualBottle` (idempotent boot), play/install/stop/winecfg use `paths.manualBottle(id)`,
    `removeManual` deletes the bottle, `discardManualBottle` cleans up an unsaved draft.
  - UI: **Add Game** provisions the game's bottle (installer runs into it; a "Setting up…" spinner; Cancel
    discards a draft bottle). Manual settings sheet gains a **Bottle** section ("Run Installer in this
    bottle…", "Show bottle in Finder"); the tile's Wine Config opens the game's own bottle.
  - 187 tests / 29 suites green; clean build (no warnings); app reassembled.
- **✅ M101–M105 — non-Steam (.exe) games + hide Steam's redistributables.** Two core-app changes:
  - **Redistributables no longer surface as a game (M101).** Root cause: discovery parsed every
    `appmanifest_*.acf`; "Steamworks Common Redistributables" (228980) looks like a normal manifest. The
    principled signal (verified on-device): Steam auto-installs shared packages with `LastOwner == 0`,
    while user-owned games carry the owner's SteamID64. `SteamApp.isSharedSystemApp` + a DiscoveryEngine
    filter — not a name match. (An exe-presence heuristic would wrongly drop real games like Split Fiction,
    whose exe is nested.)
  - **Add non-Steam .exe games (M102–M105).** New `ManualGame` model persisted in `config.json`
    (backward-compatible tolerant decoder so a new key never wipes existing config); `LaunchOrchestrator.
    launchManualGame` + `runInstaller` (reuse `makePlan`, which lost its long-dead `app:` param); a
    UUID-keyed manual run-state in `GameLibraryViewModel` (Steam path untouched); and the UI: an
    **Add Game** wizard (Run Installer → Choose .exe → Add), `ManualGameTileView`, and a manual settings
    sheet. Manual games launch in the shared bottle prefix under GPTK without needing Steam.
  - 184 tests / 28 suites green; clean build (no warnings); app reassembled. Commits M101–M105.
- **✅ M100 — polished, stateful Updates UI in Settings → General.** Replaced the bare
  version/button/text rows with one self-contained status row that morphs between states (a `Phase` enum
  → icon + tint + title + subtitle + action): **Check Now** shows an animated spinner (held for a ~700 ms
  minimum so the loading always reads as deliberate), then the result cross-fades in — a green
  ✓ "You're on the latest version" or an accent ↓ "Version X is available" with a prominent **Update &
  Relaunch** button; install progress (downloading/installing) and a ⚠ failed+Retry state share the same
  row. Smooth (`.smooth(0.32)`) animation + `contentTransition(.opacity)` on the text + a scale/opacity
  transition on the icon. Mirrors the Wine tab's "load → result surfaces" flow. Dropped the now-redundant
  `AppEnvironment.updateMessage` (the view derives all copy from `updateCheck`). 175 tests green; clean build.
- **✅ M99 — code-rot sweep after the settings reshape (M94–M98).** Audited every file the settings
  reshaping touched. Removed **dead code**: `PathPickerRow` (the manual-paths picker, orphaned when the
  "Advanced (manual paths)" disclosure was dropped) and `BackendSettingsViewModel.isConfigured` (declared,
  never read). Fixed **stale references**: a user-visible onboarding string and a doc comment still said
  "Advanced → …" (now "Settings → General"); a leftover duplicate doc line called the Settings window "a
  sheet (Wine/GPTK paths)"; and "Wine Manager" / "GPTK Manager" doc mentions across `RuntimeViewModel`,
  `BackendSettingsViewModel`, `BackendConfig`, `WineInstall` (+ a test) now say "the Wine/GPTK settings
  tab". Dropped the stale "experimental" framing on `SteamBottleViewModel`. Verified all readiness flags,
  VM members, and picker helpers are still live. 175 tests green; clean build (no warnings).
- **✅ M98 — dropped settings explanatory footers + "already latest" update message.** Removed the
  descriptive footer `Text` under **Steam bottle**, **Updates** (General tab), **Wine**, and **GPTK** —
  the sections speak for themselves. Added an "already latest" confirmation to the app updater: a manual
  **Check for Updates** (or the bootstrap auto-check) now sets `AppEnvironment.updateMessage` to "You're on
  the latest version (X)" when current (nil when an update is available — the install button says it — or on
  offline), shown under the Check button. Mirrors the Wine tab's "already installed" message. 175 tests
  green; clean build (no warnings).
- **✅ M97 — Wine "install latest" no-op when current + a manual update check.** (1) `RuntimeViewModel.
  installLatest` now short-circuits when the newest published Wine is already installed — instead of
  re-downloading the ~250 MB build it reports "Latest Wine (X) is already installed" (and adopts it as
  default if none set). (2) Added a **"Check for Updates"** button to Settings → General → Updates
  (`AppEnvironment.checkForUpdate` + `isCheckingForUpdate`) so the user can re-check on demand, even though
  bootstrap still checks automatically. +2 tests → 175 / 28 suites green; clean build (no warnings).
- **✅ M96 — Settings tabs restructured to General / GPTK / Wine.** The Settings window now has three
  top-level tabs: **General** (the former Steam-bottle pane, with the app version + inline updater moved to
  a "Updates" section at the bottom — `GeneralSettingsView`, renamed from `BackendSettingsView`), **GPTK**
  (`GPTKManagerView`), and **Wine** (`WineDownloadView`). Removed the combined "Runtimes" tab + its
  `WineManagerView` wrapper (the GPTK/Wine segmented sub-tabs are now top-level tabs), and the standalone
  `UpdatesView` (folded into General). 173 tests / 28 suites green; clean build (no warnings).
- **✅ M95 — UI refinements (6 changes).** (1) Renamed "Advanced Settings" → **Settings** and made it the
  standard macOS **Settings window** (app-menu "Settings…" / ⌘, via a `Settings` scene + `openSettings`;
  the Library toolbar gear now opens it). Tabs: **Steam Bottle**, **Runtimes**, **Updates**. (2) Removed the
  Status section (Ready-to-launch / Default Wine / Default GPTK) and (3) the "Advanced (manual paths)"
  disclosure + the now-vestigial Save button from `BackendSettingsView` (it's just the Steam-bottle pane
  now). (4) **Removed the experimental HW-accelerated Steam UI** entirely (`cefHardwareArgs` /
  `hardwareAccelerated` everywhere) — on-device it only black-screened, confirming the ANGLE-D3D11-under-GPTK
  limit. (5) **Fixed the GPTK Runtimes list showing wine runtimes** — the M83 overlay copies
  `D3DMetal.framework` into the wine runtime's `lib/external`, so `GPTKImporter.installed()` matched it;
  now excludes any dir with a wine binary. (6) **Fixed the updater offering a Wine version as an app
  update** — it queried `/releases/latest` (often `wine-cx-*`); now fetches the release list and considers
  only the app's own `v*` releases (`isAppRelease`). 173 tests / 28 suites green; clean build.
- **✅ M94 — UI: single-pane Library + consolidated Advanced Settings.** Removed the sidebar entirely
  (`RootView` is now just `NavigationStack { LibraryGridView() }`); deleted `SidebarView`/`SidebarItem` and
  the **About** pane. **Advanced Settings** (Library toolbar → gear) is now a `TabView`: **Backend** (the
  former `BackendSettingsView`), **Runtimes** (the former Wine Manager — GPTK + Wine tabs), and **Updates**
  (new `UpdatesView` = version + the inline updater, replacing About). Update availability also surfaces as
  a small "· Update vX.Y.Z available" note to the right of the "X games" subtitle. 173 tests / 28 suites
  green; clean build. (Pending: a real Steam logo for the Steam button needs a bundled asset — SF Symbols
  has none and I won't fabricate Valve's mark; kept the SF Symbol for now.)
- **✅ M93 — unify the live Steam client under one owner (fixes the double-spawn bug).** The bottle's
  Steam client had TWO uncoordinated owners: `GameLibraryViewModel` tracked it (PID + coalescing +
  cold-start grace), while `SteamBottleViewModel.launchSteam` spawned its OWN untracked copy — so clicking
  Advanced → "Launch Steam" then Play on a game could start a second client (the Library's `steamPID` was
  still nil). Extracted **`SteamClientSession`** (`@MainActor @Observable`) as the single owner of the live
  client: PID tracking, launch coalescing, cold-start grace, the experimental HW-accel flag, and
  `ensureRunning()`/`sendURL()`. Both view models now route through it (Library `openSteam`/`play`/install/
  uninstall and settings `launchSteam` → `session.ensureRunning()`), keeping their distinct roles
  (operational library vs setup/admin) but with ONE tracked client. New test proves the cross-VM case
  (settings launch + Play → exactly one client). 173 tests / 28 suites green; clean build (no warnings).
  (This was the architecture finding I'd deferred at M88; safe to do now with M89's coalescing coverage.)
- **✅ M92 — Phase 5: hardware-accelerated Steam bottle (experimental opt-in path; on-device test needed).**
  Important framing first: **games launched from the bottle are ALREADY hardware-accelerated** — GPTK
  D3DMetal, proven on-device (Bloons TD 6, M83). Only the **2D Steam *client* UI** is software-rendered
  (SwiftShader), a deliberate CEF black-window workaround. That workaround predates the **M83 overlay** that
  made GPTK's D3D11 actually work, so CEF's GPU path (ANGLE→D3D11→D3DMetal) *might* now render where it
  couldn't before. Added an **opt-in experimental HW path** to test that:
  - `SteamBottle.cefHardwareArgs` + `steamEnvironment(hardwareAccelerated:)` — enables CEF's GPU process
    (`--use-gl=angle --use-angle=d3d11`, drops `--disable-gpu`/`--use-gl=swiftshader`/`STEAM_DISABLE_GPU_PROCESS`)
    and points the DYLD fallbacks at the runtime's overlaid D3DMetal (same wiring a game launch uses) so
    ANGLE's D3D11 can reach Metal. Default launch stays software (verified).
  - Toggle: **Advanced Settings → Steam bottle → "Hardware-accelerated UI (experimental)"**, then Launch Steam.
  - **Honest caveat:** our own GeoGuessr/Electron test showed ANGLE's D3D11 backend FAILS under GPTK
    (`eglInitialize D3D11 failed`) even post-overlay, so this may still black-screen; and even if it renders,
    the surface may not present. It's opt-in precisely so it can't break the working software default.
  - 172 tests / 28 suites green; clean build; `dist/Silo.app` reassembled.
- **✅ M91 — Phase 4 performance review (agentic).** 4 lenses (UI re-layout, main-actor blocking,
  redundant work, I/O) → skeptical verify → only 3 real worth-doing fixes (the codebase was already
  perf-clean since the 100%-CPU fix + polling removal): (1) roomier `URLCache.shared` (32 MB mem / 128 MB
  disk) so library cover-art is a cache hit on scroll-back, not a re-fetch; (2) hoisted `GameLibraryVM.
  filtered` to compute the filter+sort ONCE per `LibraryGridView` body (was twice — subtitle count + grid);
  (3) `LogTailer` now coalesces log-file write bursts to ~7×/sec (trailing throttle) so a noisy launch
  doesn't re-lay-out the 256 KB monospaced log Text on every kqueue event. No fix-now/high findings.
  171 tests / 28 suites green; clean build (no warnings).
- **✅ M90 — Phase 3 security hardening (agentic adversarial review, 14 findings).** 4 threat lenses
  (download/execute integrity, archive extraction, process-exec injection, error/failure modes) →
  exploitability verification → applied 8 hardenings:
  - **CRITICAL — in-app updater had ZERO integrity check** before replacing+executing the running app.
    Added fail-closed **SHA-256** verification of the release `.zip` against a published `<asset>.zip.sha256`
    (release.yml now ships it) + **https-only** download guard. (App is ad-hoc signed → no Developer-ID/spctl
    to pin; this defeats MITM/CDN tampering. **Defeating a *compromised release* needs notarization** — see
    BLOCKED.)
  - **HIGH — path traversal** via an attacker-named release tag flowing into a `Runtimes/` path: added
    `safeRuntimeComponent` sanitizer + a `runtimesDir`-containment assert; **HIGH — runtime SHA-256 now
    mandatory** (fail-closed) for the built-in `Silo.wineRepo` (was best-effort-skip).
  - https-only guard on all release-derived downloads (+ `NSAppTransportSecurity` ATS dict, default-deny);
    appmanifest `installdir` path-escape validation; **scrub `DYLD_INSERT_LIBRARIES`/`DYLD_FORCE_FLAT_NAMESPACE`**
    from inherited env for wine children; crash-safe staged GPTK import; honest checksum UI copy.
  - Shared `FileDigest.sha256` + `DownloadGuard.requireHTTPS`. +10 tests → **171 / 28 suites green**; clean build.
- **✅ M89 — Phase 2 test-coverage gaps (agentic, +49 tests → 161).** 4 domain mappers (orchestration,
  error/edge, graphics/runtime, parsing/models) → adversarial verify (real gap + catches a real bug, not
  coverage theater) → 25 verified gaps filled. New: `AppEnvironment.installUpdate` orchestration (no-bundle
  `.failed` + not-newer no-op), `applyBackend` fan-out, full `SteamBottleViewModel` suite, `GameLibraryVM`
  stop/uninstall-guard, and error branches across `Updater`/`RuntimeManager`/`GPTKImporter`/`ConfigStore`/
  `SteamBottle` (download/unpack/replace/wineboot/checksum failures + corrupt-config fallback), plus
  parser/Codable edges (`SteamPresenceStrategy` unknown-case, `EnvFlags` legacy migration + round-trip,
  `AppManifestDecoder`/`LibraryFoldersDecoder`). Test-infra only: `FakeProcessRunner` real terminate +
  incrementing PIDs; `FakeURLProtocol` per-session stub scoping (fixes a shared-registry race). No
  production code touched; **no production bugs found** (all assert existing behavior). 161 tests / 28
  suites green; clean build.
- **✅ M88 — Phase 1 architecture review (agentic, 8 verified fixes).** 4 cross-file lenses (boundaries,
  abstraction value, dependency direction, concurrency-fit) → adversarial verify → 12 actionable, applied
  the 8 safe ones: deleted the vestigial **`BackendResolver`** (it adopted an installed Whisky/CrossOver
  runtime — contradicts #8) + its `detectedSource`; `ProcessRunning.observeExit` now required (dropped the
  dead Noop default that could silently swallow game-exit); propagated the injected runner into `Updater`
  (closed a test-seam leak); removed `AppEnvironment.logTarget` view-type leak; added
  `ConfigStore.updateGame` field-scoped transaction (fixes a `lastPlayed` lost-update vs a concurrent
  settings save); consolidated the backend-config fan-out (`applyBackend` + `applyDefaultWine/GPTK`);
  extracted **`WineRuntimeLayout`** (one home for runtime FS-layout math, mirrors `PrefixLayout`). Stale
  CLAUDE.md actor list fixed. **Deferred** (flagged, regression-risky on validated CEF code): unify the
  Steam-client lifecycle (two VMs own it → possible double-spawn) and an `UpdaterViewModel` extraction.
  112 tests / 25 suites green; clean build (no warnings).
- **✅ M87 — removed the dead `.crossover`/DXVK backend (GPTK-only).** The CrossOver/DXVK fallback was
  advertised across config, UI, and policy but never wired (no DXVK download, no install path) — pure rot
  (decided with the user, 2026-06-28). Collapsed to a single graphics path: deleted `GraphicsBackend` +
  `BackendPolicy` (+ their tests), dropped `GameConfig.backend`,
  `BackendConfig.{crossoverWinePath,dxvkDLLDirPath,wineBinary(for:)}`, `EnvFlags.dxvkHUD`,
  `GraphicsLinker.linkDXVK`, the backend Picker + the CrossOver/DXVK path rows in Advanced Settings, the
  per-game DXVK-HUD field, the GameDetail backend recommendation, and the now-dead `applicationsDirectory`
  autodetect param (it only existed to find CrossOver.app). `makePlan`/`linkGraphics` are GPTK-only.
  Legit "CrossOver **source**" wine-build references (constraint #8) preserved; CLAUDE.md "Two runtime
  roles" updated to GPTK-only. 112 tests / 25 suites green; clean build (no warnings).
- **✅ M86 — agentic codebase audit (17 verified cleanups).** A 5-reviewer multi-agent audit
  (dedup → adversarial verify, 17 of 21 confirmed) → applied: dead code removed (`Asset.size`,
  `AppPaths.steamBottleWebHelper`, `BackendSettingsViewModel.paths`, `GameSettingsViewModel.appName`);
  duplication collapsed (`GPTKImporter.Result`→`GPTKInstall`, shared `deQuarantine()` +
  `RuntimeInstallRow`, generic `AppManifestDecoder.opt<T>`); `bootstrap()` re-entrancy fixed
  (`isBootstrapping`/`didBootstrap` split); **`BackendPolicy.effective` wired into `play()`** (gptk→
  crossover fallback — was dead code; covered by BackendPolicyTests); four stale M83 GPTK "system32"
  docs corrected to the overlay mechanism. 122 tests / 26 suites green; clean build (no warnings).
- **✅ M85 — inline in-app updater (Sparkle-style).** The updater now applies updates **inline**:
  download the release `.zip` → unpack beside `Silo.app` → atomic `replaceItemAt` → `lsregister` →
  relaunch — no browser hop / manual install, replacing the old check+download-Link. `Updater`.
  `downloadUpdate`/`installUpdate`/`relaunch` (binary exec via `ProcessRunning`);
  `AppEnvironment.installUpdate` + `UpdateState`; `AboutView` "Download & Relaunch" button + progress.
- **✅ CI(wine) — brew-link crash fixed (follow-up to M84 GnuTLS).** The x86_64-Homebrew step
  hard-failed on a transitive `python@3.14` link conflict (`idle3 already exists`). Now tolerates link
  failures (we reference every formula by `brew --prefix`, never the linked name) and asserts the needed
  formulae are installed. Validated in CI: "Build dependencies" + "Fetch CrossOver source" steps pass;
  the build proceeds into compiling Wine.
- **✅ M84 — Wine CI GnuTLS configure fix.**
  `build-wine.yml` now fails fast if x86_64 Homebrew dependencies do not install, installs `pkgconf`,
  and exports the x86_64 Homebrew `pkg-config` / include / library paths plus explicit x86_64 clang
  selection before Wine configure. This should unblock the GitHub runner failure:
  `libgnutls 64-bit development files not found` while keeping `--with-gnutls` required for schannel.
  Local verification: workflow YAML parses; `swift build --disable-sandbox` clean; `Scripts/test.sh
  --disable-sandbox` green (119 tests / 26 suites). The `--disable-sandbox` flag was only needed because
  this managed local session blocks SwiftPM's manifest sandbox.
- **✅ M83 — GPTK D3DMetal OVERLAY baked into Silo (native DX11 games render under GPTK on-device).**
  119 tests / 26 suites green; clean build (no warnings); `dist/Silo.app` reassembled. The load-bearing
  GPTK activation: Apple's d3d modules must be OVERLAID into the wine runtime's OWN `lib/wine` tree, not
  merely put on `WINEDLLPATH` (which loads GPTK's PE dll but pairs it with wine's own `wined3d`→OpenGL
  backend → `D3D11CreateDevice` 0x80004005). This **replaces the M29 WINEDLLPATH/system32-symlink wiring**.
  - **`GraphicsLinker.overlayGPTK(wineBinary:gptkLibDir:)`** copies GPTK's 6 graphics modules' PE `.dll`
    into `<wine>/lib/wine/x86_64-windows`, **recreates** each unix `.so` as a relative symlink in
    `x86_64-unix` (preserved, not dereferenced — keeps D3DMetal.framework's `@rpath` lookup working), and
    copies `lib/external` (libd3dshared.dylib + D3DMetal.framework) into `<wine>/lib/external`. The runtime
    is then self-contained for D3DMetal (GPTK not consulted at launch). Idempotent (byte-compares a witness
    module): no-op when current, re-applies on a runtime re-download or GPTK update — so it survives both.
  - **`makePlan` GPTK env** now points the DYLD fallbacks at the runtime's own `lib/external` and forces
    only the GPTK-translated modules builtin (`WINEDLLOVERRIDES=d3d10,d3d11,d3d12,dxgi=b`; no WINEDLLPATH;
    d3d9/wined3d untouched). Optimally-tuned set confirmed against Apple's GPTK README (documented env is
    just `ROSETTA_ADVERTISE_AVX` + `D3DM_SUPPORT_DXR`; MetalFX/DXR are per-game, off by default) — all
    already in `EnvFlags`. The overlay was the only substantive gap.
  - **Proven on-device:** Bloons TD 6 (native Unity D3D11) creates a real D3DMetal device
    (`Direct3D 11.0 level 10.1`), renders with sound + fullscreen, co-resident Steamworks connected.
  - Cleanup: old GPTK-into-`system32` path deleted; `link()`→`linkDXVK()` (crossover-only); dead
    `gptkExternalDirPath`/`gptkWineDLLDirPath`/`LinkError.backendNotConfigured` removed.
- **✅ M73–M81 — THE GATE IS CLEARED: bottle Steam RENDERS + LOGS IN on the from-source CrossOver wine
  (on-device, 2026-06-28).** 117 tests / 26 suites green; clean build. Three fixes, each found from live
  logs, finally got the Windows Steam client visible + signed in:
  - **winebus/SDL crash** (the recurring `NSWindow … main thread` abort): `winebus.so` dlopens libSDL2
    whose macOS init pops an off-main-thread NSAlert → Wine aborts. `WINEDLLOVERRIDES=winebus=` does NOT
    disable a PnP `.sys` driver; the reliable fix is removing the dylib. → build `--without-sdl` (M80) +
    `RuntimeManager.stripBundledSDL` auto-strips bundled `libSDL2*` (no rebuild needed).
    **⚠️ SUPERSEDED (controller support, see "Now"):** the crash was the *generic Homebrew*
    libSDL2, not SDL itself — CrossOver ships SDL 2.30.12 (same winebus source) and does NOT crash. SDL is
    now re-enabled: build `--with-sdl` + bundle a pinned SDL 2.30.12 built from source; `stripBundledSDL`
    removed.
  - **wrapper stranded** (M81): a Steam update switched the CEF dir `cef.win7x64`→`cef.win64`, leaving the
    single-dir wrapper orphaned while Steam ran the unwrapped webhelper → black. `installWebHelperWrapper`
    now wraps ALL `bin/cef/*/steamwebhelper.exe`. (Path was also wrongly `cef.win64`-hardcoded pre-M78.)
  - **presentation** (M79): Steam launches in a Wine virtual desktop (`explorer /desktop=`) so winemac.drv
    presents the CEF surface (rootless = black on CrossOver). CEF forced onto SwiftShader software GL via
    `STEAM_CEF_COMMAND_LINE` + the `--in-process-gpu` wrapper (M76).
  - Login via QR (Steam mobile) succeeded + cached (AllowAutoLogin=1). The Chromium `WSALookupServiceBegin`/
    `10045`/`Transport Error` log spam is NON-fatal background noise, not a login blocker.
  - **✅ CO-RESIDENT LAUNCH + STEAMWORKS VALIDATED:** GeoGuessr Steam Edition (3478870 — previously FAILED
    Steamworks with no logged-in Steam) launched via `launchInBottle` under GPTK and got
    `getAuthTicketForWebApi -> OK` from the co-resident Steam. The whole shared-bottle architecture works.
    Per-game polish left: GeoGuessr is Electron and its ANGLE/WebGL doesn't init under GPTK (map renders
    broken) — fixable per-game via software/SwiftShader GL, separate from the (working) architecture.
- **M68–M72 — REVERT to the Steam-bottle model + a 3-round agentic audit.** 115 tests / 26 suites green;
  clean build (no warnings). SteamCMD + macOS credential-seeding were removed and the app reverted to a
  single shared **Steam bottle**: one Wine prefix hosting a logged-in Windows Steam client; games install
  there and launch **co-resident** under GPTK/D3DMetal so Steamworks/DRM works (IPC is prefix-scoped). Then
  an agentic audit-fix loop (4 read-only audits → verify → apply → re-audit):
  - **M68:** the revert itself (bottle foundation, discovery from the bottle's `appmanifest`, launchInBottle).
  - **M69:** removed the dead isolated-prefix layer (PrefixProvisioner, GameLogStore, SteamBottle.launchGame,
    AppPaths.prefix/prefixesDir, RuntimeManager.installedRuntimes/availableAssets, SteamApp.downloadProgress/
    needsUpdate). Bottle now launches Steam in a Wine **virtual desktop** (`explorer /desktop=`) with
    overlay-disable overrides + msync; `play()` brings Steam up ONCE (tracked PID) with a cold-start grace.
    Wine build: add `CROSSCFLAGS=-fvisibility=default`; drop `/usr/local/lib` from the DYLD fallback (it
    leaked Homebrew's duplicate gtk → the "implemented in both" crash seen launching bottle Steam).
  - **M70:** removed the now-obsolete `.sharedSteamClient` strategy + unused `Receipt`/`revert` (the bottle
    IS the in-prefix Steam); `load()` surfaces real discovery errors instead of swallowing them.
  - **M71:** force msync for every bottle game launch (a per-game esync/none would fork a 2nd wineserver and
    break Steamworks); `steam://` install/uninstall deliver via single-instance forwarding (no 2nd Steam in
    a duplicate desktop); GraphicsLinker scoped to `d3d*`/`dxgi*` so it can't clobber the shared bottle;
    removed the orphaned `WineRuntime` type.
  - **M72:** `stop()` also `wine taskkill /F /IM <game exe>` in the bottle's msync wineserver so a
    child/relauncher game isn't orphaned (Steam untouched — different image names).
- **M58–M60 COMPLETE — spring cleaning.** 150 tests / 30 suites green; clean build (no warnings).
  Three parallel audits (dead code / duplication / post-pivot vestigial) → verified findings → acted.
  - **M58:** Uninstall also removes the game's isolated Wine prefix (full reclaim).
  - **M59 (dedup):** SteamAppInfo.headerArtURL/storePageURL (views stop hand-rolling URLs); one
    GameArtworkPlaceholder; one URL.tailString; shared .uninstallConfirmation modifier; LogTarget.windowID
    + AppEnvironment.logTarget(for:).
  - **M60 (removals):** deleted zero-ref dead symbols + post-pivot vestigial code (masterBottlePath/
    steamRoot/steamWineBinaryPath/isMasterBottleConfigured/steamWine, DiscoveryEngine.steamRoot(inBottle:),
    Silo.steamInstallerURL/steamLaunchArgs, AppPaths.masterBottleDefault, WineRuntime.wineserverBinary,
    PrefixLayout.syswow64/dosDevices, StateFlags.isDownloading, SteamApp URL helpers, requiresUserStub),
    removed CrashLoopGuard + orphaned ProcessRunning.processCount, hid the inert .sharedSteamClient from
    the picker, reworded stale Master-bottle docs. Net −156 lines (5045→4940 LOC) despite adding helpers.
- **M51–M57 COMPLETE — perf + reliability + UX pass.** 153 tests / 31 suites green; clean build (no
  warnings); .app assembles; verified running at **0.0% idle CPU** (was pinned at 100%).
  - **M51 (the energy bug):** sampled the live app → main thread pinned in SwiftUI layout driven by a
    CADisplayLink. Root cause: indeterminate `ProgressView()` spinners INSIDE the ScrollView (loading /
    "Updating" / AsyncImage placeholder) re-laid out the whole grid every frame. Moved spinners out of
    the scroll content; download bar `safeAreaInset`→VStack sibling; `filtered` no longer re-sorts.
    Verified 100%→0%.
  - **M52 (event-driven, no polling):** `ProcessRunning` gains `observeExit` (DispatchSource process) +
    `observeWrites` (file-system) + `firstPID`. Downloads read progress reactively from the SteamCMD log
    and detect completion/interruption from the process's real exit (no 2s poll, no flaky pgrep) — fixes
    the false "Resume"; manifest is authoritative on exit. Game-exit clears state via an exit observer.
  - **M53 (UX):** whole card opens details; detail view shows Disk size / Metacritic / Minimum
    requirements; status messages auto-dismiss (6s); refresh toolbar keeps button chrome while spinning.
    Fixed logged-in account "falling away" — `autodetect` was wiping `steamUsername`; now preserved + the
    account shows in the navigation subtitle.
  - **M54:** Uninstall (menu + details, confirmed) deletes the game's bucket files.
  - **M55:** fast refresh — incremental app-metadata cache (`ownedGames(known:)` only `app_info`s new
    apps; the cache persists the full owned catalog).
  - **M56:** `BackendPolicy` — GPTK default for DirectX 9–12, auto CrossOver fallback when GPTK absent;
    detail view shows the recommended backend + DirectX-derived rationale.
  - **M57:** log viewer is now a kqueue file-watcher (was a 1s poll). No timer/poll loops remain anywhere.
- **M0–M41 COMPLETE — pivot DONE.** 137 tests / 29 suites green; clean build (no warnings); .app assembles.
- **PIVOT COMPLETE (M36–M41):** Wine Steam-client GUI fully removed; replaced by native-macOS SteamCMD.
  - M37–M38: SteamCMDClient (install + force-windows download + capture) + SteamAppInfo metadata +
    ownedWindowsGames enumeration (licenses→packages→app_info, filtered to windows-only games).
  - M39: SyncMode enum, MSync default (Apple-Silicon best practice).
  - M40: GameLibraryViewModel + SteamLoginViewModel wired into AppEnvironment (account in BackendConfig).
  - M41 (UI swap + rip-out): new SteamLoginView + SteamGameTileView; LibraryGridView lists owned
    Windows-only games (Download→SteamCMD, Play→GPTK bucket); OnboardingView step 3 = "Sign in to Steam";
    readiness = wineReady && gptkReady && steamLoggedIn. DELETED: SteamBottleInstaller, SteamCardView,
    GameCardView, LibraryViewModel, SteamLibraryInstaller, OwnedAppsReader (+ their tests). ViewModelTests
    pruned to the surviving VMs. CrashLoopGuard retained (available; no longer wired to Steam GUI).
  - REMAINING (human-gated): real SteamCMD login + a real Windows-only game download → launch in a GPTK
    bucket (needs the user's Steam credentials). All headless-testable logic is done + green.
- **>>> ARCHITECTURE PIVOT (2026-06-27, user decision) <<<** The Wine **Steam-client GUI** does not
  render under our self-built wine on macOS 26 (CEF black window; verified that -no-cef-sandbox fixes the
  crash-loop but neither GPU-on nor GPU-off nor RetinaMode nor virtual-desktop renders it — this is the
  industry-wide problem that got Whisky archived). New model **"Native Steam library → SteamCMD → GPTK
  buckets"**: (1) DROP the Wine Steam bottle entirely (SteamBottleInstaller/openSteam/CEF flags/shared-
  client presence); (2) library = the user's owned games filtered to **Windows-only** (no native mac
  build); (3) download via **native macOS SteamCMD** `@sSteamCmdForcePlatformType windows` (no Wine/CEF);
  (4) launch each in a per-game **GPTK bucket** configured from the game's Steam metadata (DirectX→backend)
  else sensible default. Owned-list + metadata via SteamCMD itself (licenses_print / app_info_print) — no
  Web API key needed.
  - P0 DONE: native macOS SteamCMD **verified on macOS 26** (bootstraps, accepts force-windows, returns
    app_info platforms for appID 70).
  - M36 / P1-foundation DONE: `SteamCMD` pure command builders (download / app_info / licenses) + tests.
  - TODO: P1 `SteamCMDClient` (install steamcmd + run download/login via ProcessRunning); P2 owned
    Windows-only library + metadata; P3 metadata-driven GPTK bucket; P4 rip out old Steam-bottle code + UI rework.
- M35 = bundler no longer bundles glib/gstreamer/ffmpeg media stack (killed the "implemented in both" +
  glib-type dup warnings); 44→21 libs; clean wineboot = 0 freetype + 0 dup. RetinaMode reverted (broke windowing).
- M33 (user UX/bug fixes): (1) Steam card now has a right-click context menu + always-visible ellipsis
  (Open Steam, Reinstall, View Log…, Wine Config…, Reveal Bottle, Settings…). (2) Log viewer opens as a
  STANDALONE WINDOW (WindowGroup id "silo-log" + openWindow), not a modal sheet, so it live-tails while
  you drive the main window; generalized to any file (title+url), added an Autoscroll toggle. (3) (b)
  CrashLoopGuard + ProcessRunning.processCount: auto `wineserver -k` if a `winedbg` storm appears, wired
  behind openSteam. (4) (a) gstreamer dedup: reorder to bundled-LAST was tried but BREAKS FreeType
  (wine only finds its dlopen'd freetype from the bundle), so kept bundled-FIRST; proper dedup = don't
  bundle the glib/gstreamer/ffmpeg media stack (TODO in bundler; only manifests during video playback).
- **OPEN (windowing):** Steam launches but renders as two blank/black rootless windows (steam + CEF
  steamwebhelper). Testing a wine VIRTUAL DESKTOP (HKCU\Software\Wine\Explorer Desktop=Default) to
  composite into one window — enabled on the user's bottle; awaiting visual confirmation it renders.
- M32 (bug: "Open Steam" opens nothing): Steam WAS launching but its CEF UI renderer went
  "unresponsive" and Steam killed+relaunched it every ~90s forever, so the window stayed 0x0/blank.
  Root cause: the CEF sandbox under wine. Fix: `Silo.steamLaunchArgs` now passes `-no-cef-sandbox`
  (+ `-cef-disable-gpu -allosarches`; dropped obsolete `-cef-force-32bit`). EMPIRICALLY VERIFIED on
  the user's machine: 0 "unresponsive" events after relaunch and a real 705x440 Steam login window appeared.
- M31 (bug: can't right-click library cards): GameCardView had only the ellipsis `Menu`, no
  `.contextMenu`. Added a right-click menu (Play/Stop, Isolate, Settings…, View Log…, Reveal Prefix,
  Wine Config…, View on Steam Store, Reset Prefix) via a shared `managementMenu()` builder reused by
  the ellipsis menu, which is now always visible (even while running). Per-game settings pane gained
  **Launch options** (`GameConfig.launchOptionsString` ↔ `customArgs`, Steam-style) and a DXVK HUD
  field (CrossOver backend only). `SteamApp.storePageURL` added. +3 tests.
- M30 (bug: Install Steam hung + crash storm): the silent `SteamSetup.exe /S` auto-launches Steam.exe,
  which crash-loops under wine (Steam CEF) and spawns *hundreds* of `winedbg --auto` processes, so the
  installer NEVER returns → app stuck "Installing…", `masterBottlePath` never set. Fix: `SteamBottleInstaller`
  now SPAWNS the installer detached, polls for `Steam.exe` to appear (≤180s), then `wineserver -k`s the
  bottle so the crash-loop can't accumulate; full client downloads on first real run via "Open Steam"
  (which passes CEF-safe flags). Verified on the user's machine: bottle + Steam.exe present; storm killed.
- M29 (D3DMetal path wiring): GPTK game launches now (a) put GPTK's `lib/external` on
  `DYLD_FALLBACK_LIBRARY_PATH` + `DYLD_FALLBACK_FRAMEWORK_PATH` so `d3d11.so` resolves
  `@rpath/libd3dshared.dylib` and `D3DMetal.framework`; (b) add GPTK's `lib/wine` to `WINEDLLPATH`
  and force d3d/dxgi `=b` (builtin) so wine loads GPTK's d3d instead of the base wine's. New
  `BackendConfig.gptkExternalDirPath` / `gptkWineDLLDirPath` derive these from `gptkLibDirPath`.
  STATICALLY VERIFIED on the real GPTK-4.0_beta_1: D3DMetal.framework loads under x86_64; converter
  libs (libmetalirconverter/libdxccontainer) resolve via the framework's own rpath; wine honors
  DYLD_FALLBACK (proven by the freetype fix). **E2E activation is human-gated** (see BLOCKED).
- M28 (self-contained wine): `Scripts/bundle-wine-dylibs.sh` copies the transitive closure of wine's
  non-system dylib deps (arch-filtered to the wine's arch — x86_64) into `<wine>/lib/silo-bundled`;
  the app launches wine with `DYLD_FALLBACK_LIBRARY_PATH=<…>/lib/silo-bundled` (URL.siloDyldFallback)
  so freetype/gstreamer/etc. resolve without Homebrew. Wired into build-wine (CI + local) + install-
  local-wine. **VERIFIED**: wineboot with the app's exact env → 0 FreeType warnings, prefix boots.
- M27 (bug: "Install Steam does nothing"): first-run `wineboot` was hanging on blocking wine-mono/
  wine-gecko install dialogs. Now `wineboot` (SteamBottleInstaller + PrefixProvisioner) sets
  `WINEDLLOVERRIDES=mscoree,mshtml=` (`Silo.winePrefixInitOverrides`) so it completes headlessly.
  Verified: the user's wine-cx-26.2.0 boots a home-dir prefix cleanly with the override.
- **KNOWN (build follow-up):** the locally-built wine logs "cannot find the FreeType font library" —
  the self-built wine depends on Homebrew dylibs (freetype/gstreamer/…) not bundled/relocated, so it's
  not fully self-contained. Prefix creation still works; fonts won't render until deps are bundled.
- CI FIX: `Scripts/test.sh` crashed on the runner (bash 3.2 + `set -u` + empty `FLAGS` array →
  "unbound variable"); now guards the empty-array expansion. (This was failing every CI run.)
- M26 = game artwork: `SteamApp.headerArtURL` (Steam CDN header.jpg); GameCardView shows the cover
  via AsyncImage with a gradient placeholder fallback.
- M25 (Wine Manager fixes from user report): `locateWineBinary` now excludes directories, so GPTK
  installs (`lib/wine` dir) no longer masquerade as Wine in the Wine tab; Wine tab simplified to a
  single "Install latest Wine" (dropped the broken multi-version refresh — CI publishes the canonical
  latest); removed a stray `Runtimes/GPTK` left by the M15 verification import.
- M24 = downloaded-Wine SHA-256 verification (build-wine publishes `.sha256`; RuntimeManager verifies).
- M23 = audit robustness + UX: downloaded Wine is
  de-quarantined + ad-hoc re-signed (Gatekeeper), extraction cleans up on failure; GPTK de-quarantined
  (no re-sign — keeps Apple's signature); live log tail; library recently-played sort + installed/updates
  filter; prefix management (reveal / Wine config / reset); CI concurrency + ccache + timeouts + read perms.
  **Perf levers (msync default, DXMT, rosettax87, DXVK install) still deferred — say "do perf" to start.**

- M22 = launch feedback + UX wins: Running/exited
  state + Stop button (`ProcessRunning.isRunning`, `LaunchOrchestrator.stop` via `wineserver -k`,
  `LibraryViewModel` PID monitor); `lastPlayed` stamped; `Updater` wired (bootstrap check → About
  "Update available"); exe **picker** in GameSettingsSheet (`ExecutableResolver.allExecutables`);
  library auto-refresh on app re-activation (scenePhase).

## Review backlog (remaining)
- PERF (deferred per user — say "do perf"): msync default-on (esync/msync mutually-exclusive enum);
  DXMT backend; rosettax87 fast x86; DXVK install path (the `.crossover` backend is unreachable on a clean install).
- HUMAN-GATED: notarization in release.yml (needs your Apple Developer ID + secrets).
- D3DMETAL PATH: DONE (M29). Runtime env wired + statically verified. Real activation needs a game launch (BLOCKED).
- NICE-TO-HAVE: pin GitHub Actions by commit SHA (clears Node-20 deprecation notice).
- All other audit findings (correctness, robustness, UX) are DONE (M21–M24). Wine sourcing architecture settled (see
  WINE-BUILD.md): self-hosted CrossOver-based Wine built in our own CI (`build-wine.yml`,
  workflow_dispatch) → published to our Releases → app pulls from `Silo.wineRepo` (= mikaelhug/Silo);
  no third-party prebuilt dependency. D3DMetal still imported from Apple's `.dmg`. Steam launches with
  CEF crash-workaround flags. **Perf work (DXMT/rosettax87/msync) deferred per user.**

## Wine strategy decision (2026-06-26) — see WINE-BUILD.md
- CrossOver's Wine is LGPL open source (what Apple's GPTK formula compiles). We build it ourselves in
  CI and host it, rather than depend on Gcenx/Sikarugir prebuilts (which can go stale). Don't build
  upstream Wine from scratch — perf comes from translation layers (D3DMetal/DXMT/DXVK) + x86 translator.
- **CI-gated:** `build-wine.yml` is a best-effort recipe NOT yet validated end-to-end; until the first
  `wine-*` release exists, the Wine tab is empty — use CrossOver (auto-detected) or override the path.
- **Pivot (user, 2026-06-26):** GPTK acquisition is "Browse to Apple `.dmg`" → Silo mounts + extracts
  `redist/lib`. VERIFIED against the real `Game_Porting_Toolkit_4.0_beta_1.dmg` (gitignored) via
  `silo --import-gptk <dmg>`: extracts D3DMetal.framework + 6 DLLs to Runtimes/GPTK (68M), clean detach.

## Research findings (2026-06-26, grounds M13–M16)
- `apple/game-porting-toolkit` is a **resources repo, no binary releases**; official GPTK = a DMG
  behind Apple-ID login (not automatable). **`Gcenx/game-porting-toolkit/releases`** has prebuilt
  GPTK binaries (no login) → use as the 1-click default; link Apple's repo for the manual route.
- Steam Windows installer: `https://cdn.cloudflare.steamstatic.com/client/installer/SteamSetup.exe`
  (akamai mirror: `https://steamcdn-a.akamaihd.net/client/installer/SteamSetup.exe`), silent flag `/S`.
- No single "install whole library" command. Mechanism = `steam://install/<appid>` per owned app via
  the running Steam client; owned appids parsed from `userdata/*/config/localconfig.vdf`.
- "wine-mirror/wine" is source-only (no mac binaries) → it means "use a vanilla Wine runtime" as the
  Steam-bottle fallback when GPTK can't run the Steam client.

## Build/test snapshot
- `swift build`: ✅ clean (no warnings)
- `swift test`:  ✅ 88 tests / 19 suites passing (run via `Scripts/test.sh`)
- `Scripts/build-app.sh`: ✅ produces ad-hoc-signed `dist/Silo.app` (com.mikael.silo, min OS 26.0); bundled binary smoke-runs
- CI/Release: ✅ `.github/workflows/{ci,release}.yml` valid YAML
- Last green commit: M12 CI + release + README

## Task board

### DOING
- _(none)_

### TODO (in order; each ends in a green commit)
- _(none — all milestones complete)_

### DONE
- M0 — Scaffold SPM project + harness docs (Package.swift, silo/SiloKit/SiloKitTests, CLAUDE.md, STATUS.md, README, .gitignore, Scripts/test.sh).
- M1 — KeyValues tokenizer + parser + KVNode (`Discovery/{ACFTokenizer,KeyValuesParser,KVNode}.swift`; 14 parser/tokenizer tests).
- M2 — Models (`SteamApp`, `StateFlags`, `LibraryFolder`) + decoders (`AppManifestDecoder`, `LibraryFoldersDecoder`) + fixtures + `FixtureLoader`; 10 decoder tests.
- M3 — `DiscoveryEngine` (actor): scans primary + extra libraries, skips bad manifests; `TempDir` helper; 5 tests.
- M4 — Config models (`GraphicsBackend`, `SteamPresenceStrategy`, `EnvFlags`, `WineRuntime`, `BackendConfig`, `GameConfig`) + `AppPaths` + `AppState` + `ConfigStore` actor (JSON); 8 tests.
- M5 — `ProcessRunning` protocol + `ProcessResult` + `SystemProcessRunner` (temp-file redirect, env merge, detached spawn) + `FakeProcessRunner` (lock-guarded); 8 tests incl real subprocesses.
- M6 — `PrefixLayout`, `PrefixProvisioner` actor (idempotent wineboot --init), `GraphicsLinker` (symlink/copy GPTK or DXVK into system32); 9 tests. Note: Sendable structs use computed `FileManager.default` (can't store non-Sendable); actors may store it.
- M7 — `LaunchPlan`, pure `LaunchOrchestrator.makePlan` (static; isolated WINEPREFIX, backend env, DXVK overrides), `launch` pipeline (provision→link→log→spawn), `ExecutableResolver`, `GameLogStore`; GameConfig gained `executableRelativePath`; 12 tests.
- M8 — `BackendResolver` (Whisky/Kegworks/CrossOver detection, .none on clean machine) + `SteamPresenceInstaller` (none/appIDFile/sharedClient/emulatorStub with backup+revert), wired into launch pipeline; 10 tests.
- M9 — `GitHubRelease` model, `Updater` (GH Releases version check, numeric compare), `RuntimeManager` actor (list/fetch/download+tar-extract/remove); `FakeURLProtocol` test support; 9 tests. Note: Swift Testing runs in parallel — network tests use unique stub URLs (no shared-state reset).
- M10 — `AppEnvironment` composition root + `SiloApp` (SwiftUI App); view models (`LibraryViewModel`, `BackendSettingsViewModel`, `GameSettingsViewModel`, `RuntimeViewModel`); views (Root/Sidebar/LibraryGrid/GameCard/Badge/BackendSettings/RuntimeManager/GameSettingsSheet/LogViewer/About/PathPickerRow); `silo --smoke` headless path; 7 VM tests.
- M11 — `Resources/{Info.plist.template,silo.entitlements (no sandbox)}` + `Scripts/{build-app,sign,run,dev,clean}.sh`; assembles + ad-hoc signs `dist/Silo.app`, strips quarantine. Verified bundle valid + bundled binary smoke-runs.
- M12 — `.github/workflows/{ci,release}.yml` (build+test+bundle on push/PR; tag → ad-hoc-signed Silo.zip release) + README (build, first-run setup, sandbox, legal).
- M13 — App icon: CoreGraphics generator (`Scripts/make-icon.swift`) + `make-icon.sh` (sips/iconutil) -> `Resources/AppIcon.icns`; wired via `CFBundleIconFile`; bundled by build-app.sh.
- M14 — `SteamBottleInstaller` (boot bottle → download SteamSetup.exe → silent `/S` install) + `BackendConfig.steamWine` (vanilla fallback) + AppPaths.masterBottleDefault; "Create Master Steam Bottle (1-click)" button + VM; 4 tests.
- M15 — `GPTKImporter` (browse Apple .dmg → `hdiutil attach` outer+nested via plist → copy `redist/lib` → Runtimes/GPTK, set `gptkLibDirPath`); RuntimeVM.importGPTK + "Import GPTK from .dmg…" UI + Apple link; `silo --import-gptk` CLI; **verified on real GPTK 4.0 DMG**; 4 tests. Decision log: GPTK has no wine binary (overlay only); base wine still from CrossOver/download.
- M16 — `OwnedAppsReader` (parse userdata/*/config/localconfig.vdf owned appids) + `SteamLibraryInstaller` (queue `steam://install/<appid>` per owned app via wine); LibraryVM.installEntireLibrary + "Install entire library" toolbar button; localconfig.vdf fixture; 6 tests.
- M17 — GPTK Manager: versioned installs (`Runtimes/GPTK-<version>` from DMG name) via `GPTKImporter.runtimeName/installed/remove`; `GPTKInstall` model; `BackendConfig.gptkRuntimeName`; `GPTKManagerViewModel` (import/remove/set-default, auto-default on first import) + `GPTKManagerView` + sidebar "GPTK Manager". Moved GPTK import out of Wine Runtimes view. 5 new tests.
- M18 — Wine Manager (`WineManagerView` segmented GPTK|Wine tabs): GPTK tab = `GPTKManagerView`; Wine tab = `WineDownloadView` driven by rewritten `RuntimeViewModel` (latest 3 Gcenx releases, 1-click install, set-default, remove). `WineInstall` model; `RuntimeManager.availableReleases/preferredAsset/installWine/installedWines/locateWineBinary`; `BackendConfig.wineRuntimeName`; `Silo.wineRepo` (Gcenx, .tar.xz ~250MB). Backend view → "Setup" with Advanced disclosure for manual paths; deleted RuntimeManagerView; sidebar Library/Setup/Wine Manager/About. 3 new tests (109 total).
- M23 — Audit robustness+UX: RuntimeManager `harden` (xattr de-quarantine + ad-hoc codesign) + extraction cleanup; GPTKImporter de-quarantine; LogViewer live tail+autoscroll; LibraryViewModel SortOrder/Filter + lastPlayed map; PrefixProvisioner.remove + LaunchOrchestrator.runWineTool (winecfg) + GameCard prefix menu; CI concurrency/ccache/timeouts/read-perms; 3 tests (117 total).
- M22 — Launch feedback + UX: `ProcessRunning.isRunning(pid:)` (kill(pid,0)); `LaunchOrchestrator.stop` (wineserver -k); `LibraryViewModel` runningPIDs + monitor + Stop + `lastPlayed`; Updater wired into AppEnvironment/About; exe picker (`ExecutableResolver.allExecutables`); scenePhase auto-refresh; 3 new tests (116 total).
- M21 — Post-review correctness hardening (see git log).
- M20 — Wine sourcing architecture: `Silo.wineRepo` → self-hosted `mikaelhug/Silo` (removed stale Gcenx `defaultRuntimeRepo`/`gptkRepo`); `WINE-BUILD.md` decision doc; `.github/workflows/build-wine.yml` (CI builds CrossOver-base Wine from open source → our Releases; workflow_dispatch, needs CI iteration). Steam launches with `Silo.steamLaunchArgs` CEF flags (`openSteam`). 1 new test (112 total). Perf (DXMT/rosettax87/msync) deferred.
- M19 — Library-as-home: removed Setup sidebar pane. `OnboardingView` (3 StepRows: Install Wine/Import GPTK/Install Steam) shown when `AppEnvironment.setupComplete` is false; `SteamCardView` (Open Steam via `AppEnvironment.openSteam`) pinned first in the grid when complete. `RuntimeViewModel.installLatest`; setup-readiness computed on AppEnvironment; Advanced settings via Library toolbar gear → `AdvancedSettingsSheet`(BackendSettingsView). Sidebar Library/Wine Manager/About. 2 new tests (111 total).

## Decision log
- 2026-06-26 — Use Swift Testing (`import Testing`) not XCTest: bundled in toolchain, keeps zero deps. XCTest is NOT available under Command Line Tools (no Xcode), Testing is.
- 2026-06-26 — Testing under CLT needs framework search paths: `Testing.framework` lives in `$(xcode-select -p)/Library/Developer/Frameworks` and `lib_TestingInterop.dylib` in `.../Library/Developer/usr/lib`. `Scripts/test.sh` adds both via `-F` + `-rpath`. Plain `swift test` fails with "no such module 'Testing'".
- 2026-06-26 — Package `platforms: .macOS(.v15)`; real min OS enforced via Info.plist `LSMinimumSystemVersion=26.0`.
- 2026-06-26 — Custom `URLSession` GitHub-Releases updater instead of Sparkle to keep `Package.swift` dependency-free.

## Known follow-ups (non-blocking)
- DiscoveryEngine skips Windows-style (`C:\...`) library paths in `libraryfolders.vdf`; only host-absolute (`/...`) extra libraries are scanned. In the single-downloader model games land in the primary C: library (always scanned), so this is sufficient for v1. Add Wine `dosdevices` drive-letter translation if cross-drive libraries are needed.
- Co-resident logged-in Steam: the real "Steam client in the game's prefix" answer is now the **shared Steam bottle** (`SteamBottle` + `SteamClientSession` run one logged-in Windows Steam client that all co-resident Steam games reach). The old per-game presence strategies `.sharedSteamClient` and `.emulatorStub` are **removed** — `SteamPresenceStrategy` has only `.none` + `.steamAppIDFile` (unknown/legacy raw values decode to `.none`). Constraint #7 still bars bundling any emulator.

## BLOCKED
- **HW-accelerated Steam *UI* (M92, on-device test):** flip Advanced → Steam bottle → "Hardware-accelerated
  UI (experimental)" → Launch Steam. If the CEF window renders (not black) and the GPU log shows ANGLE/D3D11
  (not SwiftShader), GPTK now drives the Steam UI on Metal — report back and it can become the default. If it
  black-screens / `eglInitialize D3D11 failed`, the ANGLE-D3D11-under-GPTK limit still holds and software GL
  stays the path (the 2D UI is fine on software; games are HW regardless). Only the user can run this gate.
- _(none for the build — the items below need a real Wine runtime + on-device launch, not code changes)_
- **Bottle Steam CEF render + login (M76, verified recipe applied — needs on-device confirm):** deep-research
  (→ MelonForAll/vineport, confirmed working macOS 2026) found the root cause of BOTH the black window AND
  the `Transport Error 2` login failure: the steamwebhelper wrapper injected `--single-process`, which also
  breaks Chromium's network service under Wine. Fixed to `--in-process-gpu` + SwiftShader software GL
  (`STEAM_CEF_COMMAND_LINE`/`STEAM_DISABLE_GPU_PROCESS`/`GALLIUM_DRIVER=llvmpipe`) + rootless launch +
  Vineport's steam.exe flags. **To verify:** rebuild wine (`Scripts/build-wine.sh <ver>` — corrected
  wrapper) + rebuild the app, Advanced → Reset Steam login → Launch Steam → confirm the UI paints + login
  completes. If still failing, the research's fallback is kaon's model (native macOS Steam primary).
- **`explorer /desktop=` program-path form:** `launchSteam` passes the macOS **unix** path of `steam.exe`
  as the program arg to `wine explorer /desktop=Silo,<geom>`. If wine's explorer needs a Windows path
  (`C:\Program Files (x86)\Steam\steam.exe`) instead, Steam won't launch — verify on-device and switch if so.
- **~~stop() under real Wine~~ + ~~cold-start 10s grace~~ — REMOVED as stale (reconciled 2026-07-12).**
  Neither exists in the code: Phase 4 dropped the per-game `stop()`/`taskkill` teardown (Silo launches
  detached and never stops a game), and the flat-10s `play()` grace was replaced by the event-driven
  readiness gate (`SteamClientSession.ensureRunning` → kqueue on `user.reg`, 20s failsafe; `isRunning` now
  also cross-checks the wineserver socket so a stale reg pid can't read as "up"). Delisted, not a gate.
- **GPTK E2E activation — RESOLVED (M83).** Confirmed from a real D3D game (Bloons TD 6): `WINEDLLPATH`
  alone does NOT activate GPTK (wine keeps its own wined3d backend → device-creation failure); the overlay
  copy into wine's own `lib/wine` (Whisky's method) is required and now automated by
  `GraphicsLinker.overlayGPTK`. D3DMetal device creation + render verified on-device.
- **~~Confirm the default Wine/GPTK runtime repo~~ — RESOLVED (reconciled 2026-07-12).** No
  `Silo.defaultRuntimeRepo`/`Kegworks` symbol exists; the runtime repo is `Silo.wineRepo` =
  `Versions.githubRepo` = `mikaelhug/Silo` (Silo ships its own from-CrossOver-source Wine). Delisted.
- **Remaining items below are genuine on-device HARDWARE gates** (not code drift) — they need a real Wine
  runtime + a Mac to run, and are a human on-device pass, not a code change.

## Handoff checklist (for human, post-loop E2E)
- [ ] Build the patched wine: `Scripts/build-wine.sh 26.2.0` (adds `-fvisibility=default` + the
      steamwebhelper wrapper). Download/point Silo at a GPTK runtime.
- [ ] Onboarding: import GPTK `.dmg`, then **Set up** (chains Wine → DXMT → Steam → wineboot → components →
      warm-up) → **Launch Steam**. Confirm the CEF login window actually PAINTS (the gate above); sign in
      once (Steam caches it).
- [ ] Confirm the library lists games installed in the bottle; **Install** routes a `steam://` URL to the
      running Steam.
- [ ] **Play** → game launches co-resident in the bottle under its chosen backend (GPTK by default, DXMT
      per game); Steamworks/online works. (There is NO Stop — Silo launches detached and leaves games
      running, like CrossOver; quitting Silo doesn't kill them.)
- [ ] (Distribution) provide Apple Developer ID + notarization secrets for signed releases.
