// silo-game-loader.dylib — injected into the Wine processes of a game started from macOS Steam (GameAppLoader).
// When Wine is about to exec its loader for one of the game's executables, exec the copy of the loader that lives in
// the game's .app instead, so every process of the game — a relaunch included — runs inside that bundle and macOS
// shows the game's name and icon. Same idea as NotProton's PR #90 (sn0wst0rm); Silo's own code.
// SILO_GAME_LOADER = the loader in the bundle; SILO_GAME_EXES = ':'-separated executable names (case-insensitive).
// Anything else (steam.exe, services, a mismatch) execs untouched.
//
// Also loaded, through the game app's LSEnvironment, when LaunchServices starts the app by itself — the Games app does,
// with no arguments, and Wine would just print its usage and quit. Then `games_handoff` asks Steam for the game instead
// (SILO_GAMES_HANDOFF, a steam:// link), opening "Steam (Silo)" first when Steam isn't running (SILO_STEAM_LAUNCHER),
// so Steam starts with Silo's library and its grants. Silo's own idea from its NotProton fork (49ee6f5); own code.
#include <crt_externs.h>
#include <fcntl.h>
#include <spawn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <unistd.h>

// Silo's runtime execs its loader directly (no preloader, no WINEDLLPATH → no winetemp link), so match the
// exec of a Wine loader ("…/wine" or a winetemp link) whose arguments name one of the game's executables.
static int names_game_exe(const char *arg, const char *names) {
    const char *base = arg;
    for (const char *c = arg; *c; c++) if (*c == '/' || *c == '\\') base = c + 1;
    char list[1024]; snprintf(list, sizeof list, "%s", names);
    for (char *save = NULL, *name = strtok_r(list, ":", &save); name; name = strtok_r(NULL, ":", &save))
        if (!strcasecmp(base, name)) return 1;
    return 0;
}

static int is_game_exec(const char *path, char *const argv[]) {
    const char *names = getenv("SILO_GAME_EXES");
    if (!path || !names || !argv) return 0;
    const char *base = strrchr(path, '/');
    base = base ? base + 1 : path;
    if (strcmp(base, "wine") && !strstr(path, "/winetemp-")) return 0;
    if (argv[1] && names_game_exe(argv[1], names)) return 1;   // the program itself, not its arguments
    return 0;
}

// Keeps the display awake while this process — about to become the game — lives: played with a controller only, macOS
// sees no activity and starts the screen saver (the alt-loader host does the same, host.c keep_display_awake).
// `caffeinate -w` ends with the game by itself, and the pid survives the exec. Only stdio (as /dev/null) is passed on,
// so it holds none of Wine's descriptors.
static void keep_display_awake(void) {
    char pid[32];
    snprintf(pid, sizeof pid, "%d", getpid());
    char *args[] = { "caffeinate", "-d", "-i", "-w", pid, NULL };
    posix_spawn_file_actions_t io;
    posix_spawn_file_actions_init(&io);
    for (int fd = 0; fd <= 2; fd++)
        posix_spawn_file_actions_addopen(&io, fd, "/dev/null", fd ? O_WRONLY : O_RDONLY, 0);
    posix_spawnattr_t attributes;
    posix_spawnattr_init(&attributes);
    posix_spawnattr_setflags(&attributes, POSIX_SPAWN_CLOEXEC_DEFAULT);
    pid_t child;
    extern char **environ;
    posix_spawn(&child, "/usr/bin/caffeinate", &io, &attributes, args, environ);
    posix_spawnattr_destroy(&attributes);
    posix_spawn_file_actions_destroy(&io);
}

static int silo_execv(const char *path, char *const argv[]) {
    const char *loader = getenv("SILO_GAME_LOADER");
    if (loader && strcmp(path, loader) && is_game_exec(path, argv) && access(loader, X_OK) == 0) {
        fprintf(stderr, "silo-game-loader: %s runs from the game app\n", argv[1]);
        keep_display_awake();
        return execv(loader, argv);
    }
    return execv(path, argv);
}

__attribute__((used)) static const struct { const void *replacement, *original; } interpose_execv
    __attribute__((section("__DATA,__interpose"))) = { (const void *)silo_execv, (const void *)execv };

// The hand-off runs in a detached shell, so this process — the game app, bouncing in the Dock — quits at once while Steam
// starts. "Steam (Silo)" only when Steam isn't up; then the link once its client is running (it queues the launch until
// Steam is ready). The shell gets no DYLD_ or SILO_ variables: nothing of this library follows it.
static const char handoff_script[] =
    "if ! /usr/bin/pgrep -x steam_osx >/dev/null && [ -d \"$1\" ]; then\n"
    "  /usr/bin/open \"$1\"\n"
    "  i=0; while [ $i -lt 120 ] && ! /usr/bin/pgrep -x steam_osx >/dev/null; do sleep 1; i=$((i+1)); done\n"
    "  sleep 3\n"
    "fi\n"
    "exec /usr/bin/open \"$2\"\n";

__attribute__((constructor)) static void games_handoff(void) {
    int argc = *_NSGetArgc();
    char **argv = *_NSGetArgv();
    if (argc > 2 || (argc == 2 && strncmp(argv[1], "-psn_", 5))) return;   // a real launch: a program to run
    const char *url = getenv("SILO_GAMES_HANDOFF");
    if (!url || strncmp(url, "steam://", 8)) return;
    const char *launcher = getenv("SILO_STEAM_LAUNCHER");
    char *args[] = { "sh", "-c", (char *)handoff_script, "silo-games-handoff", (char *)(launcher ? launcher : ""),
                     (char *)url, NULL };
    extern char **environ;
    size_t n = 0;
    while (environ[n]) n++;
    char **env = calloc(n + 1, sizeof(char *));
    size_t k = 0;
    for (size_t i = 0; i < n; i++)
        if (strncmp(environ[i], "DYLD_", 5) && strncmp(environ[i], "SILO_", 5)) env[k++] = environ[i];
    env[k] = NULL;
    posix_spawn_file_actions_t io;
    posix_spawn_file_actions_init(&io);
    for (int fd = 0; fd <= 2; fd++)
        posix_spawn_file_actions_addopen(&io, fd, "/dev/null", fd ? O_WRONLY : O_RDONLY, 0);
    posix_spawnattr_t attributes;
    posix_spawnattr_init(&attributes);
    posix_spawnattr_setflags(&attributes, POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT);
    pid_t child;
    posix_spawn(&child, "/bin/sh", &io, &attributes, args, env);
    _exit(0);
}
