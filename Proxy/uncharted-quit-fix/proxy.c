/* Silo's "Uncharted fix" (Correzione Uncharted): a d3d12.dll proxy in front of D3DMetal's d3d12.
 *
 * UNCHARTED: Legacy of Thieves Collection releases some of its D3D12 resources one time too many: a texture's last
 * Release comes from one place (u4.exe+0x18b25d5), and its cleanup loop releases the same texture again 375 ms later
 * (u4.exe+0x15fa756) — on a dead object, so quitting from the game's menu crashed every time and left the "safe
 * mode" prompt for the next start. It happens during play too: 2006 such releases in a 3-minute session, ~180 of them
 * while playing (callers in u4.exe and iggy_w64_final.dll), silently touching freed memory. Measured 2026-11-22 with
 * Silo's d3d12-relog experiment; D3DMetal's own reference counting was probed and matches Windows (QueryInterface,
 * SetPrivateDataInterface), so the extra Release is the game's.
 *
 * The change: the proxy holds one reference of its own on every resource the game creates (placed, committed,
 * reserved) and reports the counts the game expects. When the game drops its last reference the resource is kept
 * alive for SILO_UNCHARTED_DEFER_MS (default 2000 ms), then freed for real; a Release on it in that window is a
 * no-op instead of a use after free. Nothing else is touched: every other call goes straight to D3DMetal.
 *
 * Silo puts this file in the game's folder and launches the game with d3d12=n,b; D3DMetal's own d3d12 is loaded from
 * the copy Silo keeps beside it in the runtime (d3dm_d3d12.dll — the proxy can't load a second module named
 * d3d12.dll). Environment:
 *   SILO_REAL_D3D12          full DOS path of that copy (set by Silo; falls back to loading it by name)
 *   SILO_UNCHARTED_DEFER_MS  how long a released resource is kept; "0" turns the change off (for an A/B comparison)
 *   SILO_UNCHARTED_FIX_LOG   DOS path of a log file (off when unset): the counts at exit
 * Built by Scripts/build-uncharted-fix.sh. Verified on UNCHARTED (GPTK 4 beta 3, macOS Steam) 2026-11-22. */
#define COBJMACROS
#define INITGUID
#include <windows.h>
#include <d3d12.h>
#include <stdarg.h>
#include <stdint.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* How Silo recognises its own file in a game folder (UnchartedFix.marker). Keep in sync. */
__attribute__((used)) static const char silo_marker[] = "Silo Uncharted fix d3d12 proxy";

static HMODULE real;
static DWORD defer_ms = 2000;
static char log_path[MAX_PATH];
static CRITICAL_SECTION lock;
static long n_tracked, n_deferred, n_freed, n_swallowed;

static void plog(const char *fmt, ...) {
    if (!log_path[0]) return;
    FILE *f = fopen(log_path, "a");
    if (!f) return;
    va_list ap;
    va_start(ap, fmt);
    vfprintf(f, fmt, ap);
    va_end(ap);
    fputc('\n', f);
    fclose(f);
}

/* ---- the resources the proxy holds a reference on: open addressing, backward-shift delete ----------- */

typedef struct { void *key; int zombie; } entry;
#define MAP_BITS 18
#define MAP_MASK ((1u << MAP_BITS) - 1)
static entry *map;
static size_t map_count;

static size_t slot(void *key) { return ((uintptr_t)key >> 4) & MAP_MASK; }

static entry *map_find(void *key) {
    for (size_t i = slot(key);; i = (i + 1) & MAP_MASK) {
        if (!map[i].key) return NULL;
        if (map[i].key == key) return &map[i];
    }
}

/* NULL when full: the resource is then simply not tracked (it behaves as without the proxy). */
static entry *map_put(void *key) {
    if (map_count * 4 >= (MAP_MASK + 1) * 3) return NULL;
    for (size_t i = slot(key);; i = (i + 1) & MAP_MASK) {
        if (map[i].key == key) { map[i].zombie = 0; return &map[i]; }
        if (!map[i].key) { map[i].key = key; map[i].zombie = 0; map_count++; return &map[i]; }
    }
}

static void map_del(entry *x) {
    size_t i = (size_t)(x - map);
    map[i].key = NULL;
    map_count--;
    for (size_t j = (i + 1) & MAP_MASK; map[j].key; j = (j + 1) & MAP_MASK) {
        size_t home = slot(map[j].key);
        if ((j > i && (home <= i || home > j)) || (j < i && (home <= i && home > j))) {
            map[i] = map[j];
            map[j].key = NULL;
            i = j;
        }
    }
}

/* Resources the game has released for the last time, oldest first, freed once defer_ms has passed. */
#define QUEUE (1u << 16)
static void *queue[QUEUE];
static DWORD queue_tick[QUEUE];
static size_t queue_head, queue_tail;

/* ---- vtable patching ---------------------------------------------------------------------------------- */

#define MAX_VT 32
typedef struct { void *vt; void *orig; } hook;
static hook rel_hooks[MAX_VT], place0_hooks[MAX_VT], place1_hooks[MAX_VT], place2_hooks[MAX_VT],
    comm0_hooks[MAX_VT], comm1_hooks[MAX_VT], comm2_hooks[MAX_VT], comm3_hooks[MAX_VT], resv0_hooks[MAX_VT];
static int n_rel, n_place0, n_place1, n_place2, n_comm0, n_comm1, n_comm2, n_comm3, n_resv0;

static void *find_orig(hook *h, int n, void *obj) {
    void *vt = *(void **)obj;
    for (int i = 0; i < n; i++) if (h[i].vt == vt) return h[i].orig;
    return NULL;
}

/* Replace vt[slot] by fn, remembering the original for this vtable. Caller holds `lock`. */
static void patch(void *obj, int vslot, void *fn, hook *h, int *n) {
    void **vt = *(void ***)obj;
    for (int i = 0; i < *n; i++) if (h[i].vt == vt) return;
    if (vt[vslot] == fn || *n >= MAX_VT) return;
    DWORD old;
    if (!VirtualProtect(&vt[vslot], sizeof(void *), PAGE_READWRITE, &old)) return;
    h[*n].vt = vt;
    h[*n].orig = vt[vslot];
    (*n)++;
    vt[vslot] = fn;
    VirtualProtect(&vt[vslot], sizeof(void *), old, &old);
}

#define SLOT(type, member) ((int)(offsetof(type, member) / sizeof(void *)))

typedef ULONG (STDMETHODCALLTYPE *PFN_REL)(IUnknown *);

/* Free, for real, the queued resources whose time is up (all of them when `all`). */
static void flush(int all) {
    void *due[64];
    PFN_REL fn[64];
    int n = 0;
    DWORD now = GetTickCount();
    EnterCriticalSection(&lock);
    while (queue_head != queue_tail && n < 64 && (all || now - queue_tick[queue_head % QUEUE] >= defer_ms)) {
        void *o = queue[queue_head++ % QUEUE];
        entry *e = map_find(o);
        if (!e || !e->zombie) continue;
        map_del(e);
        fn[n] = (PFN_REL)find_orig(rel_hooks, n_rel, o);
        due[n++] = o;
    }
    LeaveCriticalSection(&lock);
    for (int i = 0; i < n; i++) if (fn[i]) { fn[i]((IUnknown *)due[i]); n_freed++; }
}

static ULONG STDMETHODCALLTYPE hook_release(IUnknown *obj) {
    EnterCriticalSection(&lock);
    PFN_REL orig = (PFN_REL)find_orig(rel_hooks, n_rel, obj);
    entry *e = map_find(obj);
    int tracked = e != NULL, zombie = e && e->zombie;
    LeaveCriticalSection(&lock);
    if (zombie) {  /* released again after its last Release: the use after free this proxy exists for */
        n_swallowed++;
        return 0;
    }
    if (!orig) return 0;  /* not reachable: only installed on vtables recorded here */
    ULONG left = orig(obj);
    if (!tracked) return left;
    /* the proxy's own reference is the 1 left over */
    if (left == 1) {
        EnterCriticalSection(&lock);
        entry *x = map_find(obj);
        if (x && queue_tail - queue_head < QUEUE) {
            x->zombie = 1;
            queue[queue_tail % QUEUE] = obj;
            queue_tick[queue_tail % QUEUE] = GetTickCount();
            queue_tail++;
            n_deferred++;
            x = NULL;
        }
        LeaveCriticalSection(&lock);
        if (x) {  /* queue full: free it now, as without the proxy */
            EnterCriticalSection(&lock);
            entry *y = map_find(obj);
            if (y) map_del(y);
            LeaveCriticalSection(&lock);
            orig(obj);
        }
    }
    flush(0);
    return left ? left - 1 : 0;
}

/* A resource the game just created: the proxy takes its own reference on it. */
static void track(void **out) {
    if (!out || !*out) return;
    IUnknown *res = (IUnknown *)*out;
    EnterCriticalSection(&lock);
    patch(res, 2, (void *)hook_release, rel_hooks, &n_rel);
    entry *e = find_orig(rel_hooks, n_rel, res) ? map_put(res) : NULL;
    LeaveCriticalSection(&lock);
    if (e) { IUnknown_AddRef(res); n_tracked++; }
}

#define ORIG(type, hooks, n, obj) \
    ({ EnterCriticalSection(&lock); type o_ = (type)find_orig(hooks, n, obj); LeaveCriticalSection(&lock); o_; })

typedef HRESULT (STDMETHODCALLTYPE *PFN_PLACE0)(ID3D12Device *, ID3D12Heap *, UINT64, const D3D12_RESOURCE_DESC *,
                                               D3D12_RESOURCE_STATES, const D3D12_CLEAR_VALUE *, REFIID, void **);
typedef HRESULT (STDMETHODCALLTYPE *PFN_PLACE1)(ID3D12Device8 *, ID3D12Heap *, UINT64, const D3D12_RESOURCE_DESC1 *,
                                               D3D12_RESOURCE_STATES, const D3D12_CLEAR_VALUE *, REFIID, void **);
typedef HRESULT (STDMETHODCALLTYPE *PFN_PLACE2)(ID3D12Device10 *, ID3D12Heap *, UINT64, const D3D12_RESOURCE_DESC1 *,
                                               D3D12_BARRIER_LAYOUT, const D3D12_CLEAR_VALUE *, UINT32,
                                               const DXGI_FORMAT *, REFIID, void **);
typedef HRESULT (STDMETHODCALLTYPE *PFN_COMM0)(ID3D12Device *, const D3D12_HEAP_PROPERTIES *, D3D12_HEAP_FLAGS,
                                              const D3D12_RESOURCE_DESC *, D3D12_RESOURCE_STATES,
                                              const D3D12_CLEAR_VALUE *, REFIID, void **);
typedef HRESULT (STDMETHODCALLTYPE *PFN_COMM1)(ID3D12Device4 *, const D3D12_HEAP_PROPERTIES *, D3D12_HEAP_FLAGS,
                                              const D3D12_RESOURCE_DESC *, D3D12_RESOURCE_STATES,
                                              const D3D12_CLEAR_VALUE *, ID3D12ProtectedResourceSession *, REFIID,
                                              void **);
typedef HRESULT (STDMETHODCALLTYPE *PFN_COMM2)(ID3D12Device8 *, const D3D12_HEAP_PROPERTIES *, D3D12_HEAP_FLAGS,
                                              const D3D12_RESOURCE_DESC1 *, D3D12_RESOURCE_STATES,
                                              const D3D12_CLEAR_VALUE *, ID3D12ProtectedResourceSession *, REFIID,
                                              void **);
typedef HRESULT (STDMETHODCALLTYPE *PFN_COMM3)(ID3D12Device10 *, const D3D12_HEAP_PROPERTIES *, D3D12_HEAP_FLAGS,
                                              const D3D12_RESOURCE_DESC1 *, D3D12_BARRIER_LAYOUT,
                                              const D3D12_CLEAR_VALUE *, ID3D12ProtectedResourceSession *, UINT32,
                                              const DXGI_FORMAT *, REFIID, void **);
typedef HRESULT (STDMETHODCALLTYPE *PFN_RESV0)(ID3D12Device *, const D3D12_RESOURCE_DESC *, D3D12_RESOURCE_STATES,
                                              const D3D12_CLEAR_VALUE *, REFIID, void **);

static HRESULT STDMETHODCALLTYPE hook_place0(ID3D12Device *d, ID3D12Heap *heap, UINT64 off, const D3D12_RESOURCE_DESC *desc,
                                             D3D12_RESOURCE_STATES st, const D3D12_CLEAR_VALUE *cv, REFIID riid, void **out) {
    HRESULT hr = ORIG(PFN_PLACE0, place0_hooks, n_place0, d)(d, heap, off, desc, st, cv, riid, out);
    if (SUCCEEDED(hr)) track(out);
    return hr;
}

static HRESULT STDMETHODCALLTYPE hook_place1(ID3D12Device8 *d, ID3D12Heap *heap, UINT64 off, const D3D12_RESOURCE_DESC1 *desc,
                                             D3D12_RESOURCE_STATES st, const D3D12_CLEAR_VALUE *cv, REFIID riid, void **out) {
    HRESULT hr = ORIG(PFN_PLACE1, place1_hooks, n_place1, d)(d, heap, off, desc, st, cv, riid, out);
    if (SUCCEEDED(hr)) track(out);
    return hr;
}

static HRESULT STDMETHODCALLTYPE hook_place2(ID3D12Device10 *d, ID3D12Heap *heap, UINT64 off, const D3D12_RESOURCE_DESC1 *desc,
                                             D3D12_BARRIER_LAYOUT layout, const D3D12_CLEAR_VALUE *cv, UINT32 nf,
                                             const DXGI_FORMAT *fmts, REFIID riid, void **out) {
    HRESULT hr = ORIG(PFN_PLACE2, place2_hooks, n_place2, d)(d, heap, off, desc, layout, cv, nf, fmts, riid, out);
    if (SUCCEEDED(hr)) track(out);
    return hr;
}

static HRESULT STDMETHODCALLTYPE hook_comm0(ID3D12Device *d, const D3D12_HEAP_PROPERTIES *hp, D3D12_HEAP_FLAGS hf,
                                            const D3D12_RESOURCE_DESC *desc, D3D12_RESOURCE_STATES st,
                                            const D3D12_CLEAR_VALUE *cv, REFIID riid, void **out) {
    HRESULT hr = ORIG(PFN_COMM0, comm0_hooks, n_comm0, d)(d, hp, hf, desc, st, cv, riid, out);
    if (SUCCEEDED(hr)) track(out);
    return hr;
}

static HRESULT STDMETHODCALLTYPE hook_comm1(ID3D12Device4 *d, const D3D12_HEAP_PROPERTIES *hp, D3D12_HEAP_FLAGS hf,
                                            const D3D12_RESOURCE_DESC *desc, D3D12_RESOURCE_STATES st,
                                            const D3D12_CLEAR_VALUE *cv, ID3D12ProtectedResourceSession *ps,
                                            REFIID riid, void **out) {
    HRESULT hr = ORIG(PFN_COMM1, comm1_hooks, n_comm1, d)(d, hp, hf, desc, st, cv, ps, riid, out);
    if (SUCCEEDED(hr)) track(out);
    return hr;
}

static HRESULT STDMETHODCALLTYPE hook_comm2(ID3D12Device8 *d, const D3D12_HEAP_PROPERTIES *hp, D3D12_HEAP_FLAGS hf,
                                            const D3D12_RESOURCE_DESC1 *desc, D3D12_RESOURCE_STATES st,
                                            const D3D12_CLEAR_VALUE *cv, ID3D12ProtectedResourceSession *ps,
                                            REFIID riid, void **out) {
    HRESULT hr = ORIG(PFN_COMM2, comm2_hooks, n_comm2, d)(d, hp, hf, desc, st, cv, ps, riid, out);
    if (SUCCEEDED(hr)) track(out);
    return hr;
}

static HRESULT STDMETHODCALLTYPE hook_comm3(ID3D12Device10 *d, const D3D12_HEAP_PROPERTIES *hp, D3D12_HEAP_FLAGS hf,
                                            const D3D12_RESOURCE_DESC1 *desc, D3D12_BARRIER_LAYOUT layout,
                                            const D3D12_CLEAR_VALUE *cv, ID3D12ProtectedResourceSession *ps, UINT32 nf,
                                            const DXGI_FORMAT *fmts, REFIID riid, void **out) {
    HRESULT hr = ORIG(PFN_COMM3, comm3_hooks, n_comm3, d)(d, hp, hf, desc, layout, cv, ps, nf, fmts, riid, out);
    if (SUCCEEDED(hr)) track(out);
    return hr;
}

static HRESULT STDMETHODCALLTYPE hook_resv0(ID3D12Device *d, const D3D12_RESOURCE_DESC *desc, D3D12_RESOURCE_STATES st,
                                            const D3D12_CLEAR_VALUE *cv, REFIID riid, void **out) {
    HRESULT hr = ORIG(PFN_RESV0, resv0_hooks, n_resv0, d)(d, desc, st, cv, riid, out);
    if (SUCCEEDED(hr)) track(out);
    return hr;
}

#define PATCH_IF(iid, vtbl, member, fn, hooks, n)                                                   \
    do {                                                                                            \
        void *p_ = NULL;                                                                            \
        if (SUCCEEDED(IUnknown_QueryInterface(dev, &iid, &p_)) && p_) {                             \
            patch(p_, SLOT(vtbl, member), (void *)fn, hooks, &n);                                   \
            IUnknown_Release((IUnknown *)p_);                                                       \
        }                                                                                           \
    } while (0)

static void patch_device(IUnknown *dev) {
    EnterCriticalSection(&lock);
    PATCH_IF(IID_ID3D12Device, ID3D12DeviceVtbl, CreatePlacedResource, hook_place0, place0_hooks, n_place0);
    PATCH_IF(IID_ID3D12Device8, ID3D12Device8Vtbl, CreatePlacedResource1, hook_place1, place1_hooks, n_place1);
    PATCH_IF(IID_ID3D12Device10, ID3D12Device10Vtbl, CreatePlacedResource2, hook_place2, place2_hooks, n_place2);
    PATCH_IF(IID_ID3D12Device, ID3D12DeviceVtbl, CreateCommittedResource, hook_comm0, comm0_hooks, n_comm0);
    PATCH_IF(IID_ID3D12Device4, ID3D12Device4Vtbl, CreateCommittedResource1, hook_comm1, comm1_hooks, n_comm1);
    PATCH_IF(IID_ID3D12Device8, ID3D12Device8Vtbl, CreateCommittedResource2, hook_comm2, comm2_hooks, n_comm2);
    PATCH_IF(IID_ID3D12Device10, ID3D12Device10Vtbl, CreateCommittedResource3, hook_comm3, comm3_hooks, n_comm3);
    PATCH_IF(IID_ID3D12Device, ID3D12DeviceVtbl, CreateReservedResource, hook_resv0, resv0_hooks, n_resv0);
    LeaveCriticalSection(&lock);
}

/* ---- exports ------------------------------------------------------------------------------------------- */

/* Loaded on first use, never from DllMain (loader lock). */
static HMODULE get_real(void) {
    if (!real) {
        char path[MAX_PATH];
        DWORD n = GetEnvironmentVariableA("SILO_REAL_D3D12", path, sizeof path);
        if (n && n < sizeof path) real = LoadLibraryA(path);
        if (!real) real = LoadLibraryA("d3dm_d3d12.dll");
        plog("Silo Uncharted fix: D3DMetal d3d12 %s, keeping released resources %lu ms",
             real ? "loaded" : "NOT FOUND", defer_ms);
    }
    return real;
}

#define FORWARD(name, ret, params, args)                                         \
    ret WINAPI name params {                                                    \
        static ret (WINAPI *fn) params;                                         \
        if (!fn && get_real()) fn = (void *)GetProcAddress(real, #name);       \
        if (!fn) return (ret)E_FAIL;                                            \
        return fn args;                                                         \
    }

HRESULT WINAPI D3D12CreateDevice(IUnknown *adapter, D3D_FEATURE_LEVEL fl, REFIID riid, void **out) {
    static HRESULT (WINAPI *fn)(IUnknown *, D3D_FEATURE_LEVEL, REFIID, void **);
    if (!fn && get_real()) fn = (void *)GetProcAddress(real, "D3D12CreateDevice");
    if (!fn) return E_FAIL;
    HRESULT hr = fn(adapter, fl, riid, out);
    if (SUCCEEDED(hr) && out && *out && defer_ms) patch_device((IUnknown *)*out);
    return hr;
}

FORWARD(D3D12GetDebugInterface, HRESULT, (REFIID riid, void **out), (riid, out))
FORWARD(D3D12GetInterface, HRESULT, (REFCLSID clsid, REFIID riid, void **out), (clsid, riid, out))
FORWARD(D3D12EnableExperimentalFeatures, HRESULT, (UINT n, const IID *ids, void *cfg, UINT *sizes), (n, ids, cfg, sizes))
FORWARD(D3D12SerializeRootSignature, HRESULT,
        (const D3D12_ROOT_SIGNATURE_DESC *d, D3D_ROOT_SIGNATURE_VERSION v, ID3DBlob **b, ID3DBlob **e), (d, v, b, e))
FORWARD(D3D12SerializeVersionedRootSignature, HRESULT,
        (const D3D12_VERSIONED_ROOT_SIGNATURE_DESC *d, ID3DBlob **b, ID3DBlob **e), (d, b, e))
FORWARD(D3D12CreateRootSignatureDeserializer, HRESULT, (const void *data, SIZE_T len, REFIID riid, void **out),
        (data, len, riid, out))
FORWARD(D3D12CreateVersionedRootSignatureDeserializer, HRESULT, (const void *data, SIZE_T len, REFIID riid, void **out),
        (data, len, riid, out))

/* For thunks.S: the exports passed straight through, resolved on first call. */
void *uqf_thunk_ptrs[4];
static const char *const thunk_names[4] = {
    "GetBehaviorValue", "D3D12CoreCreateLayeredDevice", "D3D12CoreGetLayeredDeviceSize", "D3D12CoreRegisterLayers",
};

static void uqf_missing(void) {
    plog("Silo Uncharted fix: a pass-through export is missing from D3DMetal's d3d12");
    ExitProcess(3);
}

void *uqf_resolve(int idx) {
    void *p = get_real() ? (void *)GetProcAddress(real, thunk_names[idx]) : NULL;
    if (!p) p = (void *)uqf_missing;
    uqf_thunk_ptrs[idx] = p;
    return p;
}

BOOL WINAPI DllMain(HINSTANCE inst, DWORD reason, void *reserved) {
    (void)reserved;
    if (reason == DLL_PROCESS_ATTACH) {
        DisableThreadLibraryCalls(inst);
        InitializeCriticalSection(&lock);
        char v[16];
        if (GetEnvironmentVariableA("SILO_UNCHARTED_DEFER_MS", v, sizeof v)) defer_ms = (DWORD)strtoul(v, NULL, 10);
        DWORD n = GetEnvironmentVariableA("SILO_UNCHARTED_FIX_LOG", log_path, sizeof log_path);
        if (!n || n >= sizeof log_path) log_path[0] = 0;
        map = calloc(MAP_MASK + 1, sizeof(entry));
        if (!map) defer_ms = 0;
    } else if (reason == DLL_PROCESS_DETACH) {
        plog("Silo Uncharted fix: %ld resources tracked, %ld kept after their last Release, %ld freed, "
             "%ld extra Releases made harmless", n_tracked, n_deferred, n_freed, n_swallowed);
    }
    return TRUE;
}
