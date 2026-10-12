/* Silo experiment: d3d11.dll proxy in front of D3DMetal's d3d11 (loaded as d3dm_d3d11.dll).
 * Only change: a read-only depth-stencil state with DepthFunc = EQUAL is created as GREATER_EQUAL
 * (God of War is reverse-Z; its G-buffer pass tests EQUAL against the prepass depth).
 * SILO_DEPTH_EQUAL_FIX=0 disables the change. Everything else is passed through untouched. */
#define COBJMACROS
#define INITGUID
#include <windows.h>
#include <d3d11_4.h>
#include <d3d11on12.h>
#include <stdio.h>
#include <stdarg.h>
static void plog(const char *fmt, ...) {
    FILE *f = fopen("Z:\\tmp\\silo-proxy.log", "a");
    va_list ap; va_start(ap, fmt);
    if (f) { vfprintf(f, fmt, ap); fclose(f); }
    va_end(ap);
}

typedef HRESULT (WINAPI *PFN_CDSS)(ID3D11Device *, const D3D11_DEPTH_STENCIL_DESC *, ID3D11DepthStencilState **);

static HMODULE real;
static int fix_enabled = 1;
static volatile LONG swapped;
#define MAX_VTBLS 8
static void *vtbls[MAX_VTBLS];
static PFN_CDSS originals[MAX_VTBLS];
static int nvtbls;
static CRITICAL_SECTION lock;

static HMODULE get_real(void) {
    if (!real) {
        char v[8];
        if (GetEnvironmentVariableA("SILO_DEPTH_EQUAL_FIX", v, sizeof v) && v[0] == '0') fix_enabled = 0;
        real = LoadLibraryA("d3dm_d3d11.dll");
        if (!real) plog("silo-d3d11-proxy: LoadLibrary(d3dm_d3d11.dll) failed, error %lu\n", GetLastError());
        if (!real) {
            char p[MAX_PATH];
            if (GetEnvironmentVariableA("SILO_REAL_D3D11", p, sizeof p)) {
                real = LoadLibraryA(p);
                plog("silo-d3d11-proxy: LoadLibrary(%s) = %p, error %lu\n", p, (void *)real, real ? 0 : GetLastError());
            }
        }
        plog("silo-d3d11-proxy: real d3d11 = %p, fix %s\n", (void *)real, fix_enabled ? "ON" : "OFF");
    }
    return real;
}

static HRESULT WINAPI hooked_cdss(ID3D11Device *This, const D3D11_DEPTH_STENCIL_DESC *desc, ID3D11DepthStencilState **out) {
    PFN_CDSS orig = NULL;
    void *vt = *(void **)This;
    EnterCriticalSection(&lock);
    for (int i = 0; i < nvtbls; i++) if (vtbls[i] == vt) { orig = originals[i]; break; }
    LeaveCriticalSection(&lock);
    if (!orig) return E_FAIL; /* cannot happen: we only install on vtables we recorded */
    { static volatile LONG calls; LONG c = InterlockedIncrement(&calls);
      if (c <= 300 && desc) plog("silo-d3d11-proxy: CDSS #%ld enable %d write %d func %d stencil %d\n", c, desc->DepthEnable, desc->DepthWriteMask, desc->DepthFunc, desc->StencilEnable); }
    if (fix_enabled && desc && desc->DepthEnable && desc->DepthWriteMask == D3D11_DEPTH_WRITE_MASK_ZERO &&
        desc->DepthFunc == D3D11_COMPARISON_EQUAL) {
        D3D11_DEPTH_STENCIL_DESC d = *desc;
        d.DepthFunc = D3D11_COMPARISON_GREATER_EQUAL;
        if (InterlockedIncrement(&swapped) <= 4)
            plog("silo-d3d11-proxy: EQUAL depth state -> GREATER_EQUAL\n");
        return orig(This, &d, out);
    }
    return orig(This, desc, out);
}

/* CreateDepthStencilState is slot 21 of ID3D11Device (and of every ID3D11DeviceN, which extend it). */
static void patch_vtable(IUnknown *obj) {
    void **vt = *(void ***)obj;
    EnterCriticalSection(&lock);
    for (int i = 0; i < nvtbls; i++) if (vtbls[i] == vt) { LeaveCriticalSection(&lock); return; }
    if (nvtbls < MAX_VTBLS && vt[21] != (void *)hooked_cdss) {
        DWORD old;
        if (VirtualProtect(&vt[21], sizeof(void *), PAGE_EXECUTE_READWRITE, &old)) {
            vtbls[nvtbls] = vt;
            originals[nvtbls] = (PFN_CDSS)vt[21];
            nvtbls++;
            vt[21] = (void *)hooked_cdss;
            VirtualProtect(&vt[21], sizeof(void *), old, &old);
            plog("silo-d3d11-proxy: patched device vtable %p\n", (void *)vt);
        }
    }
    LeaveCriticalSection(&lock);
}

static void hook_device(ID3D11Device *dev) {
    static const IID *iids[] = { &IID_ID3D11Device, &IID_ID3D11Device1, &IID_ID3D11Device2,
                                 &IID_ID3D11Device3, &IID_ID3D11Device4, &IID_ID3D11Device5 };
    if (!dev) return;
    for (unsigned i = 0; i < sizeof iids / sizeof *iids; i++) {
        IUnknown *u = NULL;
        if (SUCCEEDED(ID3D11Device_QueryInterface(dev, iids[i], (void **)&u)) && u) {
            patch_vtable(u);
            IUnknown_Release(u);
        }
    }
}

typedef HRESULT (WINAPI *PFN_CD)(IDXGIAdapter *, D3D_DRIVER_TYPE, HMODULE, UINT, const D3D_FEATURE_LEVEL *, UINT,
                                 UINT, ID3D11Device **, D3D_FEATURE_LEVEL *, ID3D11DeviceContext **);
typedef HRESULT (WINAPI *PFN_CDSC)(IDXGIAdapter *, D3D_DRIVER_TYPE, HMODULE, UINT, const D3D_FEATURE_LEVEL *, UINT,
                                   UINT, const DXGI_SWAP_CHAIN_DESC *, IDXGISwapChain **, ID3D11Device **,
                                   D3D_FEATURE_LEVEL *, ID3D11DeviceContext **);
typedef HRESULT (WINAPI *PFN_11ON12)(IUnknown *, UINT, const D3D_FEATURE_LEVEL *, UINT, IUnknown *const *, UINT,
                                     UINT, ID3D11Device **, ID3D11DeviceContext **, D3D_FEATURE_LEVEL *);

HRESULT WINAPI D3D11CreateDevice(IDXGIAdapter *a, D3D_DRIVER_TYPE t, HMODULE s, UINT f, const D3D_FEATURE_LEVEL *fl,
                                 UINT n, UINT v, ID3D11Device **dev, D3D_FEATURE_LEVEL *ofl, ID3D11DeviceContext **ctx) {
    PFN_CD p = (PFN_CD)GetProcAddress(get_real(), "D3D11CreateDevice");
    if (!p) return E_FAIL;
    HRESULT hr = p(a, t, s, f, fl, n, v, dev, ofl, ctx);
    plog("silo-d3d11-proxy: D3D11CreateDevice(adapter %p, type %d, flags 0x%x, %u levels, first 0x%x) = 0x%08lx, level 0x%x\n", (void *)a, t, f, n, fl && n ? fl[0] : 0, hr, ofl ? *ofl : 0);
    if (SUCCEEDED(hr) && dev) hook_device(*dev);
    return hr;
}

HRESULT WINAPI D3D11CreateDeviceAndSwapChain(IDXGIAdapter *a, D3D_DRIVER_TYPE t, HMODULE s, UINT f,
                                             const D3D_FEATURE_LEVEL *fl, UINT n, UINT v,
                                             const DXGI_SWAP_CHAIN_DESC *scd, IDXGISwapChain **sc,
                                             ID3D11Device **dev, D3D_FEATURE_LEVEL *ofl, ID3D11DeviceContext **ctx) {
    PFN_CDSC p = (PFN_CDSC)GetProcAddress(get_real(), "D3D11CreateDeviceAndSwapChain");
    if (!p) return E_FAIL;
    HRESULT hr = p(a, t, s, f, fl, n, v, scd, sc, dev, ofl, ctx);
    if (SUCCEEDED(hr) && dev) hook_device(*dev);
    return hr;
}

HRESULT WINAPI D3D11On12CreateDevice(IUnknown *d12, UINT f, const D3D_FEATURE_LEVEL *fl, UINT n,
                                     IUnknown *const *q, UINT nq, UINT node, ID3D11Device **dev,
                                     ID3D11DeviceContext **ctx, D3D_FEATURE_LEVEL *ofl) {
    PFN_11ON12 p = (PFN_11ON12)GetProcAddress(get_real(), "D3D11On12CreateDevice");
    if (!p) return E_FAIL;
    HRESULT hr = p(d12, f, fl, n, q, nq, node, dev, ctx, ofl);
    if (SUCCEEDED(hr) && dev) hook_device(*dev);
    return hr;
}

BOOL WINAPI DllMain(HINSTANCE inst, DWORD reason, LPVOID reserved) {
    if (reason == DLL_PROCESS_ATTACH) { DisableThreadLibraryCalls(inst); InitializeCriticalSection(&lock); }
    return TRUE;
}
