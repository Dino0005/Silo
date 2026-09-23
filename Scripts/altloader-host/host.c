/* Silo alt-loader host (PROTOTIPO, non parte della build dell'app).
 *
 * Riceve da Wine un processo GIA' creato dal wineserver e lo DIVENTA, restando
 * dentro un .app bundle: e' quello che rende corretta l'icona in Mission Control
 * e Stage Manager (il processo-finestra ha un bundle).
 *
 * Mittente:  wine, dlls/ntdll/unix/process.c :: send_to_cx_loader()
 * Ricevente: qui. Formato (tutte le lunghezze uint64):
 *   uint32 REQUEST_LOAD_WINE (0x52c17355)
 *   uint64 + working directory
 *   uint64 + blob env "K=V\0" (ordine: environ, promozioni PE, WINEDEBUG)
 *   uint64 + blob argv[1..] "\0"-terminati
 *   sendmsg 1 byte + SCM_RIGHTS: stdin, stdout, stderr, socket wineserver,
 *                                [WINE_WAIT_CHILD_PIPE]
 *   shutdown(SHUT_WR); il mittente legge un uint32 di risposta
 *
 * Link (obbligatorio, vedi loader/main.c e STATUS.md):
 *   -Wl,-no_pie -Wl,-pagezero_size,0x1000 -Wl,-image_base,0x200000000
 *   -Wl,-segaddr,WINE_RESERVE,0x1000 -Wl,-segaddr,WINE_TOP_DOWN,0x7ff000000000
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
#include <dlfcn.h>
#include <stdint.h>
#include <sys/mman.h>
#include <sys/socket.h>
#include <sys/un.h>

__asm__(".zerofill WINE_RESERVE,WINE_RESERVE");
static char __wine_reserve[0x1fffff000] __attribute__((section("WINE_RESERVE, WINE_RESERVE")));
__asm__(".zerofill WINE_TOP_DOWN,WINE_TOP_DOWN");
static char __wine_top_down[0x001ff0000] __attribute__((section("WINE_TOP_DOWN, WINE_TOP_DOWN")));
struct wine_preload_info { void *addr; size_t size; };
static const struct wine_preload_info preload_info[] = {
    { __wine_reserve, sizeof(__wine_reserve) }, { __wine_top_down, sizeof(__wine_top_down) }, { 0, 0 } };
const __attribute((visibility("default"))) struct wine_preload_info *wine_main_preload_info = preload_info;

#define REQUEST_LOAD_WINE 0x52c17355u
static FILE *lg;
#define L(...) do { fprintf(lg, __VA_ARGS__); fflush(lg); } while (0)

static void init_reserved_areas(void) {
    for (int i = 0; wine_main_preload_info[i].size; i++)
        mmap(wine_main_preload_info[i].addr, wine_main_preload_info[i].size, PROT_NONE,
             MAP_FIXED | MAP_NORESERVE | MAP_PRIVATE | MAP_ANON, -1, 0);
}
static int rd(int s, void *buf, size_t n) {
    char *p = buf;
    while (n) { ssize_t r = read(s, p, n);
                if (r > 0) { p += r; n -= r; } else if (r == 0 || errno != EINTR) return 0; }
    return 1;
}
static char *rd_blob(int s, uint64_t *out) {
    uint64_t n; if (!rd(s, &n, sizeof n)) return NULL;
    char *b = calloc(n + 1, 1); if (n && !rd(s, b, n)) { free(b); return NULL; }
    *out = n; return b;
}

int main(int argc, char **argv) {
    init_reserved_areas();
    const char *sockpath = argc > 1 ? argv[1] : "/tmp/silo-altloader.sock";
    char lgpath[1100]; snprintf(lgpath, sizeof lgpath, "%s.log", sockpath);
    lg = fopen(lgpath, "w");
    L("host pid %d, socket %s\n", getpid(), sockpath);

    unlink(sockpath);
    int srv = socket(PF_LOCAL, SOCK_STREAM, 0);
    struct sockaddr_un sa; memset(&sa, 0, sizeof sa);
    sa.sun_family = AF_UNIX; strncpy(sa.sun_path, sockpath, sizeof sa.sun_path - 1);
    if (bind(srv, (struct sockaddr *)&sa, sizeof sa) || listen(srv, 5)) {
        L("bind/listen: %s\n", strerror(errno)); return 1; }

    int c = accept(srv, NULL, NULL);
    uint32_t type; if (!rd(c, &type, sizeof type)) { L("nessun tipo\n"); return 1; }
    L("type=0x%08x%s\n", type, type == REQUEST_LOAD_WINE ? " LOAD_WINE" : " (inatteso)");

    uint64_t cwd_len, env_len, arg_len;
    char *cwd = rd_blob(c, &cwd_len), *env = rd_blob(c, &env_len), *args = rd_blob(c, &arg_len);
    if (!cwd || !env || !args) { L("payload incompleto\n"); return 1; }
    L("cwd=%llu env=%llu argv=%llu\n", (unsigned long long)cwd_len,
      (unsigned long long)env_len, (unsigned long long)arg_len);

    int fds[5], nfds = 0;
    { char b; char cbuf[CMSG_SPACE(sizeof(int) * 5)];
      struct iovec iov = { &b, 1 }; struct msghdr m; memset(&m, 0, sizeof m);
      m.msg_iov = &iov; m.msg_iovlen = 1; m.msg_control = cbuf; m.msg_controllen = sizeof cbuf;
      if (recvmsg(c, &m, 0) != 1) { L("recvmsg: %s\n", strerror(errno)); return 1; }
      for (struct cmsghdr *cm = CMSG_FIRSTHDR(&m); cm; cm = CMSG_NXTHDR(&m, cm))
        if (cm->cmsg_level == SOL_SOCKET && cm->cmsg_type == SCM_RIGHTS) {
            nfds = (cm->cmsg_len - CMSG_LEN(0)) / sizeof(int);
            memcpy(fds, CMSG_DATA(cm), nfds * sizeof(int)); } }
    L("fd ricevuti: %d ->", nfds);
    for (int i = 0; i < nfds; i++) L(" %d", fds[i]);
    L("\n");
    if (nfds < 4) { L("attesi almeno 4 fd\n"); return 1; }

    uint32_t resp = 0; write(c, &resp, sizeof resp);

    for (uint64_t i = 0; i < env_len; ) {
        char *e = env + i; i += strlen(e) + 1;
        char *eq = strchr(e, '='); if (!eq) continue;
        *eq = 0; setenv(e, eq + 1, 1);
    }
    if (cwd_len && *cwd) chdir(cwd);

    /* DIAGNOSTICA: stdin/stdout adottati, ma stderr resta sul NOSTRO log, cosi'
       un fatal_perror di Wine ("Bad server socket %d") finisce dove lo leggiamo.
       In produzione stderr andra' sul log del gioco (lo legge GraphicsFallback). */
    dup2(fds[0], 0); dup2(fds[1], 1); dup2(fileno(lg), 2);

    char num[32]; snprintf(num, sizeof num, "%d", fds[3]);
    setenv("WINESERVERSOCKET", num, 1);
    /* exec_wineloader() (loader.c) esporta SEMPRE questa coppia, non solo il socket.
       Non avendo pe_info nel messaggio, chiediamo riserva nulla: e' il caso che
       exec_wineloader usa per le fakedll (res_start = res_end = 0). */
    if (!getenv("WINEPRELOADRESERVE")) setenv("WINEPRELOADRESERVE", "0-0", 1);
    if (nfds >= 5) { snprintf(num, sizeof num, "%d", fds[4]); setenv("WINE_WAIT_CHILD_PIPE", num, 1); }
    L("WINESERVERSOCKET=%d\n", fds[3]);

    const char *root = getenv("CX_ROOT");
    if (!root) { L("CX_ROOT assente nell'env ricevuto\n"); return 1; }
    char ntdll[2048], loader[2048];
    snprintf(ntdll, sizeof ntdll, "%s/lib/wine/x86_64-unix/ntdll.so", root);
    snprintf(loader, sizeof loader, "%s/lib/wine/x86_64-unix/wine", root);

    int n = 1; for (uint64_t i = 0; i < arg_len; ) { n++; i += strlen(args + i) + 1; }
    char **wargv = calloc(n + 1, sizeof *wargv); wargv[0] = loader;
    { int k = 1; for (uint64_t i = 0; i < arg_len; ) { wargv[k++] = args + i; i += strlen(args + i) + 1; } }
    for (int k = 0; k < n; k++) L("argv[%d]=%s\n", k, wargv[k]);

    void *h = dlopen(ntdll, RTLD_NOW);
    if (!h) { L("dlopen: %s\n", dlerror()); return 1; }
    void (*wine_main)(int, char **) = dlsym(h, "__wine_main");
    if (!wine_main) { L("__wine_main assente\n"); return 1; }
    /* DIAGNOSI: conta i byte in coda SENZA toccare il messaggio. MSG_PEEK su
       Darwin non e' affidabile per messaggi con dati ancillari (SCM_RIGHTS) e
       puo' riportare zero mentre un control message e' in coda: la misura
       precedente ("socket vuoto") era probabilmente cieca, non vera. */
    for (int t = 0; t < 40; t++) {
        int navail = -1; socklen_t sl = sizeof navail;
        int rc = getsockopt(fds[3], SOL_SOCKET, SO_NREAD, &navail, &sl);
        if (rc == 0 && navail > 0) { L("SO_NREAD dopo %d ms: %d byte in coda\n", t * 50, navail); break; }
        if (rc != 0) { L("SO_NREAD errno=%d\n", errno); break; }
        if (t == 39) L("SO_NREAD: 0 byte per 2000 ms\n");
        usleep(50000);
    }
    L("--- chiamo __wine_main (da qui sotto parla Wine) ---\n");
    wine_main(n, wargv);
    L("--- __wine_main E' RITORNATO ---\n");
    return 0;
}
