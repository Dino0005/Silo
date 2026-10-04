// steamwebhelper wrapper — makes Steam's CEF UI paint under Wine on macOS.
//
// Steam's `steamwebhelper.exe` (Chromium/CEF) renders to a BLACK window under Wine because its multi-process
// GPU path can't present through winemac.drv. The verified fix (MelonForAll/vineport, confirmed working on
// Apple-Silicon macOS 2026) is to force CEF onto its SOFTWARE GL renderer (SwiftShader) with the GPU folded
// into the browser process via `--in-process-gpu` — NOT `--single-process`. `--single-process` also collapses
// Chromium's NETWORK service into one process, which fails under Wine (`WSALookupServiceBegin failed`) and
// breaks login with "Failed to poll auth session / Transport Error 2"; `--in-process-gpu` keeps the network
// service separate (and working). These flags pair with `STEAM_CEF_COMMAND_LINE=…--use-gl=swiftshader…` set
// at launch (see SteamBottle.steamEnvironment); this wrapper is the reliable belt-and-suspenders injector.
//
// Silo renames the real `steamwebhelper.exe` → `steamwebhelper_orig.exe` and drops this wrapper in its place.
// Steam launches the wrapper with its usual arguments; the wrapper re-launches the real binary with the same
// arguments PLUS the CEF flags, forwarding inherited handles/exit code transparently.
//
// Built in the Wine pipeline (mingw-w64, 64-bit, GUI subsystem) and shipped inside the runtime at
// share/silo/steamwebhelper-wrapper.exe; SteamBottle.installWebHelperWrapper places it in the bottle.
//
//   x86_64-w64-mingw32-gcc -O2 -municode -mwindows -o steamwebhelper-wrapper.exe steamwebhelper-wrapper.c

#include <windows.h>

static const wchar_t *kRealExe = L"steamwebhelper_orig.exe";
static const wchar_t *kInjectedFlags =
    L" --no-sandbox --in-process-gpu --disable-gpu --disable-gpu-compositing";

int wmain(void)
{
    // Path to the real steamwebhelper, in the same directory as this wrapper.
    wchar_t real[MAX_PATH];
    DWORD n = GetModuleFileNameW(NULL, real, MAX_PATH);
    if (n == 0 || n >= MAX_PATH) return 1;
    wchar_t *slash = wcsrchr(real, L'\\');
    if (slash == NULL) return 1;
    slash[1] = L'\0';
    if (wcslen(real) + wcslen(kRealExe) >= MAX_PATH) return 1;
    wcscat(real, kRealExe);

    // The real binary's own path as argv[0], then Steam's arguments, then the CEF flags (idempotent —
    // Steam may already pass some). argv[0] must NOT stay "steamwebhelper.exe": Wine's alt loader picks the
    // process to hand to Silo's Steam host by the exe name in argv[0] (ntdll send_to_cx_loader), and the
    // wrapper itself carries that name — so the real webhelper, the one owning Steam's window, is told
    // apart only by starting its command line with steamwebhelper_orig.exe.
    const wchar_t *args = GetCommandLineW();
    if (*args == L'"') {
        args++;
        while (*args && *args != L'"') args++;
        if (*args == L'"') args++;
    } else {
        while (*args && *args != L' ' && *args != L'\t') args++;
    }
    static wchar_t cmdline[32768];
    cmdline[0] = L'"';
    lstrcpynW(cmdline + 1, real, MAX_PATH);
    wcscat(cmdline, L"\"");
    if (wcslen(cmdline) + wcslen(args) + wcslen(kInjectedFlags) >= 32000) return 1;
    wcscat(cmdline, args);
    if (wcsstr(cmdline, L"--in-process-gpu") == NULL)
        wcscat(cmdline, kInjectedFlags);

    STARTUPINFOW si;
    PROCESS_INFORMATION pi;
    ZeroMemory(&si, sizeof si);
    si.cb = sizeof si;
    ZeroMemory(&pi, sizeof pi);

    // Inherit handles so Steam's IPC pipes/fds reach the real webhelper.
    if (!CreateProcessW(real, cmdline, NULL, NULL, TRUE, 0, NULL, NULL, &si, &pi))
        return 2;

    WaitForSingleObject(pi.hProcess, INFINITE);
    DWORD code = 0;
    GetExitCodeProcess(pi.hProcess, &code);
    CloseHandle(pi.hProcess);
    CloseHandle(pi.hThread);
    return (int)code;
}
