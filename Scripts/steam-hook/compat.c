// silo-steam-hook.dylib — Silo's library inside macOS Steam (the real client, steam_osx, and its CEF browser helper).
//
// 1. Focus hand-off (activation.m), always: a game Silo starts from macOS Steam runs as its own game app (GameApps,
//    GameAppLoader), not launched by LaunchServices, so since macOS 14 it can't take the front from Steam; Steam
//    yields to it once per game process. Same idea as NotProton PR #90's final focus fix (sn0wst0rm, 71b8965).
// 2. Compatibility layer, only with SILO_STEAM_COMPAT=1 (experimental, for Silo as a Steam compatibility tool):
//    steamclient.dylib sets CCompatManager's "compat layer enabled" switch at init as
//    strnicmp(platform, "linux") == 0  →  cset wN, eq ; strb wN, [xM, #off]. We find that sequence from its "linux"
//    string, check `off` against the field BIsCompatibilityToolEnabled reads (found from its VProf name string), and
//    rewrite the cset as  mov wN, #1  in memory only. No Steam file is ever modified.
// SILO_HOOK_LOG = optional log file.
#include <crt_externs.h>
#include <dlfcn.h>
#include <libkern/OSCacheControl.h>
#include <mach-o/dyld.h>
#include <mach-o/getsect.h>
#include <mach/mach.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

void silo_hook_log(const char *fmt, ...);
void silo_activation_install(void);
void silo_dock_icon_install(void);

static void logf_(const char *fmt, ...) {
    const char *path = getenv("SILO_HOOK_LOG");
    if (!path) return;
    FILE *f = fopen(path, "a");
    if (!f) return;
    fprintf(f, "%ld pid=%d ", (long)time(NULL), getpid());
    va_list ap; va_start(ap, fmt); vfprintf(f, fmt, ap); va_end(ap);
    fputc('\n', f); fclose(f);
}

void silo_hook_log(const char *fmt, ...) {
    char line[512]; va_list ap; va_start(ap, fmt); vsnprintf(line, sizeof line, fmt, ap); va_end(ap);
    logf_("%s", line);
}

#if defined(__arm64__)
static const uint8_t *find_cstring(const uint8_t *base, unsigned long size, const char *s) {
    size_t n = strlen(s) + 1;
    for (unsigned long i = 0; i + n <= size; i++)
        if ((i == 0 || base[i - 1] == 0) && memcmp(base + i, s, n) == 0) return base + i;
    return NULL;
}

// Address referenced by ADRP at words[i] + ADD (same register) within the next 4 instructions, or 0.
static uintptr_t adrp_add_target(const uint32_t *words, size_t count, size_t i, uintptr_t pc) {
    uint32_t w = words[i];
    if ((w & 0x9f000000) != 0x90000000) return 0;
    int64_t imm = ((w >> 29) & 3) | (((w >> 5) & 0x7ffff) << 2);
    if (imm & (1 << 20)) imm -= 1 << 21;
    uintptr_t page = (pc & ~(uintptr_t)0xfff) + (imm << 12);
    uint32_t rd = w & 31;
    for (size_t j = 1; j <= 4 && i + j < count; j++) {
        uint32_t w2 = words[i + j];
        if ((w2 & 0xffc00000) == 0x91000000 && ((w2 >> 5) & 31) == rd && (w2 & 31) == rd)
            return page + ((w2 >> 10) & 0xfff);
    }
    return 0;
}

static int write_code(uint32_t *at, uint32_t value) {
    mach_port_t task = mach_task_self();
    vm_address_t page = (vm_address_t)at & ~(vm_address_t)(vm_page_size - 1);
    kern_return_t kr = vm_protect(task, page, vm_page_size, FALSE, VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY);
    if (kr != KERN_SUCCESS) { logf_("vm_protect rw failed %d", kr); return 0; }
    *at = value;
    kr = vm_protect(task, page, vm_page_size, FALSE, VM_PROT_READ | VM_PROT_EXECUTE);
    if (kr != KERN_SUCCESS) { logf_("vm_protect rx failed %d", kr); return 0; }
    sys_icache_invalidate(at, 4);
    return 1;
}

static void patch_steamclient(const struct mach_header_64 *mh) {
    unsigned long tsize = 0, csize = 0;
    uint8_t *text = getsectiondata(mh, "__TEXT", "__text", &tsize);
    uint8_t *cstr = getsectiondata(mh, "__TEXT", "__cstring", &csize);
    if (!text || !cstr) { logf_("sections not found"); return; }
    uintptr_t linux_s = (uintptr_t)find_cstring(cstr, csize, "linux");
    uintptr_t vprof_s = (uintptr_t)find_cstring(cstr, csize, "CCompatManager::BIsCompatibilityToolEnabled");
    if (!linux_s || !vprof_s) { logf_("anchor strings not found"); return; }
    const uint32_t *words = (const uint32_t *)text;
    size_t count = tsize / 4;

    // The field BIsCompatibilityToolEnabled tests: the first  ldrb wX, [xY, #off]  after its VProf name.
    int64_t field = -1;
    for (size_t i = 0; i < count && field < 0; i++) {
        if (adrp_add_target(words, count, i, (uintptr_t)(words + i)) != vprof_s) continue;
        for (size_t j = i; j < i + 24 && j < count; j++)
            if ((words[j] & 0xffc00000) == 0x39400000) { field = (words[j] >> 10) & 0xfff; break; }
    }
    if (field < 0) { logf_("BIsCompatibilityToolEnabled field not found"); return; }

    // "linux" … bl … cmp w0,#0 ; cset wN,eq ; strb wN,[xM,#field]
    int patched = 0;
    for (size_t i = 0; i < count; i++) {
        if (adrp_add_target(words, count, i, (uintptr_t)(words + i)) != linux_s) continue;
        for (size_t j = i + 2; j < i + 10 && j + 2 < count; j++) {
            uint32_t cmp = words[j], cset = words[j + 1], strb = words[j + 2];
            if (cmp != 0x7100001f) continue;                                  // cmp w0, #0
            if ((cset & 0xffffffe0) != 0x1a9f17e0) continue;                  // cset wN, eq
            if ((strb & 0xffc00000) != 0x39000000 || (strb & 31) != (cset & 31)) continue;
            if (((strb >> 10) & 0xfff) != field) continue;
            uint32_t mov = 0x52800020 | (cset & 31);                          // mov wN, #1
            if (write_code((uint32_t *)(words + j + 1), mov)) {
                logf_("compat layer switch forced on at %p (field 0x%llx)", (void *)(words + j + 1),
                      (unsigned long long)field);
                patched++;
            }
        }
    }
    if (!patched) logf_("compat layer switch not found (field 0x%llx)", (unsigned long long)field);
}
#endif

static void on_image(const struct mach_header *mh, intptr_t slide) {
    (void)slide;
    Dl_info info;
    if (!dladdr(mh, &info) || !info.dli_fname) return;
    const char *name = strrchr(info.dli_fname, '/');
    if (!name || strcmp(name, "/steamclient.dylib") != 0) return;
    logf_("steamclient.dylib loaded: %s", info.dli_fname);
#if defined(__arm64__)
    patch_steamclient((const struct mach_header_64 *)mh);
#else
    logf_("not arm64: nothing done");
#endif
}

__attribute__((constructor)) static void silo_hook_init(void) {
    char exe[4096]; uint32_t size = sizeof exe;
    if (_NSGetExecutablePath(exe, &size) != 0) return;
    const char *name = strrchr(exe, '/');
    if (name && strcmp(name, "/Steam Helper") == 0) {
        // The Steam window belongs to the CEF browser helper (the "Steam Helper" without --type=), so that is the
        // app that must yield the front to a game (measured 2026-11-12: frontmost = com.valvesoftware.steam.helper).
        // Its renderer/GPU subprocesses stay untouched.
        int argc = *_NSGetArgc(); char **argv = *_NSGetArgv();
        for (int i = 1; i < argc; i++) if (strncmp(argv[i], "--type=", 7) == 0) return;
        logf_("hook loaded in the Steam browser helper: focus hand-off only");
        silo_activation_install();
        return;
    }
    if (!name || strcmp(name, "/steam_osx") != 0) return;   // other processes inherit the variable: stay inert
    logf_("hook loaded in %s", exe);
    // Steam reads controllers through SDL3, which (via GameController) gives a pad to macOS when Steam isn't the active
    // app: a DualSense switched on while another app is active came up with its lightbar off (measured 2026-11-15,
    // Xcode active; clicking Steam in the Dock first gave Steam's colour). SDL's own hint keeps the pad Steam's in the
    // background; set before SDL starts, and not over a value the user gave.
    setenv("SDL_JOYSTICK_ALLOW_BACKGROUND_EVENTS", "1", 0);
    const char *compat = getenv("SILO_STEAM_COMPAT");   // the compatibility layer is experimental: opt-in only
    if (compat && strcmp(compat, "1") == 0) _dyld_register_func_for_add_image(on_image);
    silo_activation_install();
    silo_dock_icon_install();
}
