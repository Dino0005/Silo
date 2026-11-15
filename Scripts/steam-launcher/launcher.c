// "Steam (Silo)" — the launcher the user keeps in the Dock (SteamLauncherApp). Starts macOS Steam's real client with
// Silo's library inside (silo-steam-hook.dylib) and exits. A compiled, signed executable rather than a script so
// macOS can list it in Privacy & Security: Steam started by it inherits its privacy grants (measured 2026-11-13: with
// "Controllo del dispositivo e accesso ai dati" off for the starter, Steam Input's virtual gamepad was never created),
// so the user turns it on once for "Steam (Silo)" — and Silo itself never opens.
//
// Contents/Resources/silo-steam-hook holds the library's path, written by Silo. Already running → just bring Steam
// forward. No client or no library → open /Applications/Steam.app the usual way.
//
// The grant is "Eventi" (kTCCServicePostEvent). Asking for it with CGRequestPostEventAccess shows macOS's prompt and
// lists the app in Privacy & Security, switched off, so the user only has to turn it on (as NotProton does). Silo runs
// `--request-access` (ask and exit, Steam not started) when "Steam per macOS" is switched on; a normal start asks too
// when the grant is missing (macOS shows the prompt only once per app).
#include <CoreGraphics/CoreGraphics.h>
#include <limits.h>
#include <mach-o/dyld.h>
#include <signal.h>
#include <spawn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/sysctl.h>
#include <unistd.h>
#include <libproc.h>

extern char **environ;

static int run(const char *path, char *const argv[], char *const envp[], const char *cwd) {
    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_init(&actions);
    posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", 0, 0);
    if (cwd) posix_spawn_file_actions_addchdir(&actions, cwd);
    posix_spawnattr_t attributes;
    posix_spawnattr_init(&attributes);
    posix_spawnattr_setflags(&attributes, POSIX_SPAWN_SETSID);
    pid_t pid;
    int status = posix_spawn(&pid, path, &actions, &attributes, argv, envp);
    posix_spawn_file_actions_destroy(&actions);
    posix_spawnattr_destroy(&attributes);
    return status;
}

static int steam_running(const char *client) {
    int count = proc_listallpids(NULL, 0);
    if (count <= 0) return 0;
    pid_t *pids = calloc((size_t)count + 32, sizeof(pid_t));
    count = proc_listallpids(pids, (int)(((size_t)count + 32) * sizeof(pid_t)));
    char path[PROC_PIDPATHINFO_MAXSIZE];
    int found = 0;
    for (int i = 0; i < count && !found; i++)
        if (pids[i] > 0 && proc_pidpath(pids[i], path, sizeof path) > 0 && strcmp(path, client) == 0) found = 1;
    free(pids);
    return found;
}

static void open_normally(void) {
    char *argv[] = { "/usr/bin/open", "/Applications/Steam.app", NULL };
    run(argv[0], argv, environ, NULL);
}

// Asks macOS for the grant Steam inherits; a no-op once it is given.
static void request_access(void) {
    if (!CGPreflightPostEventAccess()) CGRequestPostEventAccess();
}

int main(int argc, char *args[]) {
    if (argc > 1 && strcmp(args[1], "--request-access") == 0) {
        request_access();
        return 0;
    }
    request_access();
    const char *home = getenv("HOME");
    if (!home) return 1;
    char root[PATH_MAX], client[PATH_MAX], dir[PATH_MAX];
    snprintf(root, sizeof root, "%s/Library/Application Support/Steam", home);
    snprintf(client, sizeof client, "%s/Steam.AppBundle/Steam/Contents/MacOS/steam_osx", root);
    snprintf(dir, sizeof dir, "%s/Steam.AppBundle/Steam/Contents/MacOS", root);

    if (steam_running(client)) {
        char *argv[] = { "/usr/bin/open", "-b", "com.valvesoftware.steam", NULL };
        return run(argv[0], argv, environ, NULL) == 0 ? 0 : 1;
    }

    // The library's path, next to this executable: ../Resources/silo-steam-hook
    char self[PATH_MAX]; uint32_t size = sizeof self;
    char hook[PATH_MAX] = "";
    if (_NSGetExecutablePath(self, &size) == 0) {
        char *slash = strrchr(self, '/');
        if (slash) {
            *slash = 0;
            char file[PATH_MAX];
            snprintf(file, sizeof file, "%s/../Resources/silo-steam-hook", self);
            FILE *f = fopen(file, "r");
            if (f) {
                if (fgets(hook, sizeof hook, f)) hook[strcspn(hook, "\r\n")] = 0;
                fclose(f);
            }
        }
    }
    if (access(client, X_OK) != 0 || !hook[0] || access(hook, R_OK) != 0) {
        open_normally();
        return 0;
    }

    // Steam's environment: ours, minus any inherited insert, plus the library and the compatibility layer.
    size_t n = 0;
    while (environ[n]) n++;
    char **envp = calloc(n + 8, sizeof(char *));
    size_t k = 0;
    for (size_t i = 0; i < n; i++)
        if (strncmp(environ[i], "DYLD_", 5) != 0 && strncmp(environ[i], "SILO_STEAM_COMPAT=", 18) != 0)
            envp[k++] = environ[i];
    char insert[PATH_MAX + 32], tools[PATH_MAX + 48];
    snprintf(insert, sizeof insert, "DYLD_INSERT_LIBRARIES=%s", hook);
    snprintf(tools, sizeof tools, "STEAM_EXTRA_COMPAT_TOOLS_PATHS=%s/compatibilitytools.d", root);
    envp[k++] = insert;
    envp[k++] = "SILO_STEAM_COMPAT=1";
    envp[k++] = tools;
    envp[k] = NULL;

    char *argv[] = { client, NULL };
    int status = run(client, argv, envp, dir);
    if (status != 0) open_normally();
    return 0;
}
