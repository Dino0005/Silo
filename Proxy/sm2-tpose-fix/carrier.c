/* Silo's Spider-Man 2 T-pose fix: an amd_ags_x64.dll carrier for macprotips' fix.
 *
 * THE FIX (macprotips, github.com/macprotips/SpiderMan2Fix, Unlicense / public domain). On M1-M4 Macs
 * D3DMetal backs a typed buffer view with a Metal texture buffer, whose width is capped at 2^28 elements:
 * reads past that element return 0 and writes are dropped, without any error. Spider-Man 2 keeps every
 * character's mesh in one 2 GB pool and reads it through typed R32 views of ~536M elements, so meshes stored
 * in its upper half are never skinned (T-pose, missing heads); the symbiote's triangles are written into the
 * same pool through a typed UAV and are lost. The fix, unchanged from their d3d12.dll shim (1.2):
 *   1. typed 32-bit buffer SRVs and UAVs wider than 2^28 elements are created raw;
 *   2. the four shaders that read or write them are replaced by copies whose accesses are raw
 *      (silo-sm2-pool-<hash>.dxil, built on the user's Mac from their own Spider-Man2.exe by sm2-shaders).
 * It acts only when silo-sm2-fix.ini names this exact game build and every listed shader is present.
 *
 * WHERE IT LOADS (ours). Their shim is d3d12.dll, which needs a d3d12=n override — and Silo launches GPTK
 * games with WINEDLLOVERRIDES d3d12=b, which beats any registry setting. This file instead takes the place of
 * amd_ags_x64.dll, which the game imports statically and no runner ships; the original is renamed
 * amd_ags_x64_real.dll and every AGS export is forwarded to it (carrier.def). The game loads d3d12.dll later,
 * at run time: a loader notification sees it arrive and points the export-table entry of D3D12CreateDevice at
 * a jump to this module before anyone can look it up, so whoever creates the device (the game, or NVIDIA
 * Streamline beneath it) creates D3DMetal's device through here.
 *
 * VTABLE HOOKS (ours). A slot is patched in place when VirtualProtect allows it; otherwise the object gets a
 * private copy of its vtable with the slot replaced (D3DMetal's vtables can live outside Wine's views).
 *
 * THE FOG BARRIER (ours, from vkd3d-proton). vkd3d-proton forces a compute barrier after the shader with hash
 * 324071d329f05ccc for Spider-Man2.exe (vkd3d_proton_app_workarounds.json, "Add missing barrier in Spider Man
 * 2"): the next pass can otherwise read its output half written. Here: a UAV barrier after every Dispatch of a
 * pipeline built from that shader. On when the ini says fog_barrier = 1.
 *
 * Log: silo-sm2-fix.log beside this file, replaced on every launch. Built by Scripts/build-sm2-fix.sh. */
#define WIN32_LEAN_AND_MEAN
#define COBJMACROS
#include <windows.h>
#include <initguid.h>
#include <d3d12.h>
#include <stddef.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <wchar.h>

#include "sm2fix_core.h"

/* How Silo recognises its own file in a game folder. Keep in sync with Silo. */
__attribute__((used)) static const char silo_marker[] = "Silo Spider-Man 2 fix carrier";

#define FIX_VERSION "1.0"
#define WIDE_VIEW (1u << 28)          /* D3DMetal's typed buffer limit on M1-M4 */
#define MAX_SHADERS 8
#define FOG_SHADER_HASH SM2_DEFAULT_HASH
#define DEV_IDX(m) (offsetof(ID3D12Device4Vtbl, m) / sizeof(void *))
#define LIST_IDX(m) (offsetof(ID3D12GraphicsCommandListVtbl, m) / sizeof(void *))
/* Slots copied into a private vtable: more than any ID3D12Device or command list version has. */
#define VTBL_COPY_SLOTS 192

typedef HRESULT (WINAPI *PFN_CREATE_DEVICE)(IUnknown *, D3D_FEATURE_LEVEL, REFIID, void **);

static HMODULE g_self;
static FILE *g_log;
static SRWLOCK g_log_lock = SRWLOCK_INIT;
static SRWLOCK g_lock = SRWLOCK_INIT;
static INIT_ONCE g_init = INIT_ONCE_STATIC_INIT;
static BOOL g_active, g_fog_barrier;
static struct { uint64_t hash; void *data; size_t size; } g_shaders[MAX_SHADERS];
static unsigned int g_shader_count;
static volatile LONG g_views, g_uavs, g_pipelines, g_fog_barriers;
static PFN_CREATE_DEVICE g_create_device;
static volatile LONG g_redirected;

/* ------------------------------------------------------------------ helpers (macprotips) */

static void log_msg(const char *fmt, ...)
{
    va_list args;

    if (!g_log)
        return;
    AcquireSRWLockExclusive(&g_log_lock);
    va_start(args, fmt);
    vfprintf(g_log, fmt, args);
    va_end(args);
    fputc('\n', g_log);
    fflush(g_log);
    ReleaseSRWLockExclusive(&g_log_lock);
}

static void path_next_to_self(WCHAR *out, size_t len, const WCHAR *file)
{
    WCHAR *slash;

    GetModuleFileNameW(g_self, out, (DWORD)len);
    slash = wcsrchr(out, L'\\');
    if (!slash)
        slash = wcsrchr(out, L'/');
    if (slash)
        slash[1] = 0;
    else
        out[0] = 0;
    wcsncat(out, file, len - wcslen(out) - 1);
}

static void *read_file(const WCHAR *path, size_t *size)
{
    void *data = NULL;
    FILE *f = _wfopen(path, L"rb");
    long n;

    *size = 0;
    if (!f)
        return NULL;
    if (!fseek(f, 0, SEEK_END) && (n = ftell(f)) > 0 && !fseek(f, 0, SEEK_SET) && (data = malloc((size_t)n)))
    {
        if (fread(data, 1, (size_t)n, f) == (size_t)n)
            *size = (size_t)n;
        else
        {
            free(data);
            data = NULL;
        }
    }
    fclose(f);
    return data;
}

/* The running game's build: PE timestamp and image size of the exe, as sm2-shaders writes them. */
static void game_build(char *out, size_t len)
{
    const BYTE *base = (const BYTE *)GetModuleHandleW(NULL);
    const IMAGE_DOS_HEADER *dos = (const IMAGE_DOS_HEADER *)base;
    const IMAGE_NT_HEADERS64 *nt = (const IMAGE_NT_HEADERS64 *)(base + dos->e_lfanew);

    snprintf(out, len, "%08lx-%08lx", (unsigned long)nt->FileHeader.TimeDateStamp,
            (unsigned long)nt->OptionalHeader.SizeOfImage);
}

/* silo-sm2-fix.ini: "game_build = <build>", "shaders = <hash> <hash> ...", "fog_barrier = 0|1". */
static int read_settings(char *build, size_t build_len, uint64_t *hashes, unsigned int *count)
{
    WCHAR path[MAX_PATH];
    char line[512];
    FILE *f;

    *count = 0;
    build[0] = 0;
    path_next_to_self(path, MAX_PATH, L"silo-sm2-fix.ini");
    if (!(f = _wfopen(path, L"r")))
        return 0;
    while (fgets(line, sizeof(line), f))
    {
        char *value = strchr(line, '='), *end;

        if (line[0] == '#' || !value)
            continue;
        *value++ = 0;
        while (*value == ' ' || *value == '\t')
            value++;
        value[strcspn(value, "\r\n")] = 0;
        if (!strncmp(line, "game_build", 10))
            snprintf(build, build_len, "%s", value);
        else if (!strncmp(line, "fog_barrier", 11))
            g_fog_barrier = atoi(value) == 1;
        else if (!strncmp(line, "shaders", 7))
        {
            while (*value && *count < MAX_SHADERS)
            {
                uint64_t h = strtoull(value, &end, 16);
                if (end == value)
                    break;
                hashes[(*count)++] = h;
                value = end + strspn(end, " ,\t");
            }
        }
    }
    fclose(f);
    return 1;
}

/* Decides once whether to apply the fix (macprotips' checks). Runs on the first device creation, never in
 * DllMain or under the loader lock. */
static BOOL CALLBACK init_once(INIT_ONCE *once, void *param, void **context)
{
    WCHAR path[MAX_PATH], name[64];
    char running[32], expected[64] = "";
    uint64_t hashes[MAX_SHADERS];
    unsigned int count = 0, i;

    path_next_to_self(path, MAX_PATH, L"silo-sm2-fix.log");
    g_log = _wfopen(path, L"w");
    log_msg("Silo Spider-Man 2 fix " FIX_VERSION " (macprotips' SpiderMan2Fix, carried on amd_ags_x64.dll)");
    log_msg("D3D12CreateDevice %s", g_redirected ? "redirected through this module" : "NOT redirected");

    game_build(running, sizeof(running));
    if (!read_settings(expected, sizeof(expected), hashes, &count))
        log_msg("No silo-sm2-fix.ini: not applying the fix.");
    else if (strcmp(running, expected))
        log_msg("This game build is %s, the fix was set up for %s (the game was updated): not applying the fix."
                " Rebuild its shaders.", running, expected[0] ? expected : "none");
    else if (!count)
        log_msg("silo-sm2-fix.ini lists no shaders: not applying the fix.");
    else
    {
        g_active = TRUE;
        for (i = 0; i < count; i++)
        {
            size_t size;
            void *data;

            swprintf(name, ARRAYSIZE(name), L"silo-sm2-pool-%016llx.dxil", (unsigned long long)hashes[i]);
            path_next_to_self(path, MAX_PATH, name);
            data = read_file(path, &size);
            if (!data || size < 32 || memcmp(data, "DXBC", 4))
            {
                log_msg("Missing or damaged %ls: not applying the fix.", name);
                free(data);
                g_active = FALSE;
                break;
            }
            g_shaders[g_shader_count].hash = hashes[i];
            g_shaders[g_shader_count].data = data;
            g_shaders[g_shader_count].size = size;
            g_shader_count++;
        }
        if (g_active)
            log_msg("Game build %s matches. Applying the fix (%u shaders%s).", running, g_shader_count,
                    g_fog_barrier ? ", fog barrier on" : "");
    }
    return TRUE;
}

static void ensure_init(void)
{
    InitOnceExecuteOnce(&g_init, init_once, NULL, NULL);
}

/* ---------------------------------------------------------------- vtable hooks (ours) */

/* A hooked slot: the vtable the object points at now (the original, or our copy of it), and what was there. */
static struct { void **vtbl; unsigned int index; void *orig; } g_hooks[64];
static unsigned int g_hook_count;
/* Private vtable copies, one per original vtable, shared by every object that had it. */
static struct { void **orig; void **copy; } g_copies[16];
static unsigned int g_copy_count;

static void *orig_fn(void *obj, unsigned int index)
{
    void **vtbl = *(void ***)obj, *fn = NULL;
    unsigned int i;

    AcquireSRWLockShared(&g_lock);
    for (i = 0; i < g_hook_count && !fn; i++)
        if (g_hooks[i].vtbl == vtbl && g_hooks[i].index == index)
            fn = g_hooks[i].orig;
    ReleaseSRWLockShared(&g_lock);
    return fn;
}

/* How many leading slots of a vtable are readable, up to VTBL_COPY_SLOTS. Past the real end this copies
 * whatever follows; those slots belong to no interface the object answers for, so they are never called. */
static unsigned int readable_slots(void **vtbl)
{
    MEMORY_BASIC_INFORMATION info;
    const BYTE *end;

    if (!VirtualQuery(vtbl, &info, sizeof(info)) || info.State != MEM_COMMIT
            || (info.Protect & (PAGE_NOACCESS | PAGE_GUARD)))
        return 0;
    end = (const BYTE *)info.BaseAddress + info.RegionSize;
    if ((const BYTE *)(vtbl + VTBL_COPY_SLOTS) <= end)
        return VTBL_COPY_SLOTS;
    return (unsigned int)((end - (const BYTE *)vtbl) / sizeof(void *));
}

/* Called with g_lock held. The object's vtable after making sure it is one we may write. */
static void **writable_vtbl(void *obj, unsigned int index)
{
    void **vtbl = *(void ***)obj, **copy;
    unsigned int i, slots;
    DWORD old;

    for (i = 0; i < g_copy_count; i++)
    {
        if (g_copies[i].copy == vtbl)
            return vtbl;
        if (g_copies[i].orig == vtbl)
        {
            *(void ***)obj = g_copies[i].copy;
            return g_copies[i].copy;
        }
    }
    if (VirtualProtect(&vtbl[index], sizeof(void *), PAGE_READWRITE, &old))
    {
        VirtualProtect(&vtbl[index], sizeof(void *), old, &old);
        return vtbl;
    }
    if (g_copy_count == ARRAYSIZE(g_copies) || (slots = readable_slots(vtbl)) <= index
            || !(copy = VirtualAlloc(NULL, VTBL_COPY_SLOTS * sizeof(void *), MEM_COMMIT | MEM_RESERVE, PAGE_READWRITE)))
        return NULL;
    memcpy(copy, vtbl, slots * sizeof(void *));
    g_copies[g_copy_count].orig = vtbl;
    g_copies[g_copy_count].copy = copy;
    g_copy_count++;
    /* Slots already hooked in the original vtable are still hooked in the copy: record them under it too. */
    for (i = 0; i < g_hook_count && g_hook_count < ARRAYSIZE(g_hooks); i++)
        if (g_hooks[i].vtbl == vtbl)
        {
            g_hooks[g_hook_count].vtbl = copy;
            g_hooks[g_hook_count].index = g_hooks[i].index;
            g_hooks[g_hook_count].orig = g_hooks[i].orig;
            g_hook_count++;
        }
    log_msg("vtable %p is read-only: this object now uses a private copy", vtbl);
    *(void ***)obj = copy;
    return copy;
}

static BOOL hook_slot(void *obj, unsigned int index, void *hook)
{
    void **vtbl;
    BOOL ok = FALSE;
    DWORD old;
    unsigned int i;

    AcquireSRWLockExclusive(&g_lock);
    if (!(vtbl = writable_vtbl(obj, index)))
        goto done;
    for (i = 0; i < g_hook_count; i++)
        if (g_hooks[i].vtbl == vtbl && g_hooks[i].index == index)
        {
            ok = TRUE;
            goto done;
        }
    if (g_hook_count == ARRAYSIZE(g_hooks) || !vtbl[index] || vtbl[index] == hook
            || !VirtualProtect(&vtbl[index], sizeof(void *), PAGE_READWRITE, &old))
        goto done;
    g_hooks[g_hook_count].vtbl = vtbl;
    g_hooks[g_hook_count].index = index;
    g_hooks[g_hook_count].orig = vtbl[index];
    g_hook_count++;
    vtbl[index] = hook;
    VirtualProtect(&vtbl[index], sizeof(void *), old, &old);
    ok = TRUE;
done:
    ReleaseSRWLockExclusive(&g_lock);
    return ok;
}

/* ---------------------------------------------------------------- fog barrier (ours, vkd3d-proton's rule) */

/* Pipelines built from the fog shader, and the command lists that have one bound right now. Both stay tiny:
 * the game builds the shader into a handful of pipelines and binds it on a few lists at a time. */
static void *g_fog_psos[16];
static volatile LONG g_fog_pso_count;
static void *g_fog_lists[32];
static volatile LONG g_fog_list_count;
static SRWLOCK g_fog_lock = SRWLOCK_INIT;

static void note_pso(const void *code, size_t size, void *pso)
{
    if (!g_fog_barrier || !pso || !code || size < 32 || sm2_shader_hash(code, size) != FOG_SHADER_HASH)
        return;
    AcquireSRWLockExclusive(&g_fog_lock);
    if (g_fog_pso_count < (LONG)ARRAYSIZE(g_fog_psos))
    {
        g_fog_psos[g_fog_pso_count] = pso;
        InterlockedIncrement(&g_fog_pso_count);
    }
    ReleaseSRWLockExclusive(&g_fog_lock);
    log_msg("Fog shader pipeline %p: a UAV barrier will follow its dispatches", pso);
}

static void note_bound(void *list, void *pso)
{
    BOOL fog = FALSE;
    LONG i;

    if (!g_fog_pso_count && !g_fog_list_count)
        return;
    AcquireSRWLockExclusive(&g_fog_lock);
    for (i = 0; pso && i < g_fog_pso_count; i++)
        if (g_fog_psos[i] == pso)
            fog = TRUE;
    for (i = 0; i < g_fog_list_count; i++)
        if (g_fog_lists[i] == list)
            break;
    if (fog && i == g_fog_list_count && i < (LONG)ARRAYSIZE(g_fog_lists))
    {
        g_fog_lists[i] = list;
        g_fog_list_count++;
    }
    else if (!fog && i < g_fog_list_count)
    {
        g_fog_lists[i] = g_fog_lists[--g_fog_list_count];
    }
    ReleaseSRWLockExclusive(&g_fog_lock);
}

static BOOL fog_bound(void *list)
{
    BOOL found = FALSE;
    LONG i;

    if (!g_fog_list_count)
        return FALSE;
    AcquireSRWLockShared(&g_fog_lock);
    for (i = 0; i < g_fog_list_count && !found; i++)
        found = g_fog_lists[i] == list;
    ReleaseSRWLockShared(&g_fog_lock);
    return found;
}

static void STDMETHODCALLTYPE hk_SetPipelineState(ID3D12GraphicsCommandList *list, ID3D12PipelineState *pso)
{
    void (STDMETHODCALLTYPE *orig)(ID3D12GraphicsCommandList *, ID3D12PipelineState *)
            = orig_fn(list, LIST_IDX(SetPipelineState));

    note_bound(list, pso);
    orig(list, pso);
}

static HRESULT STDMETHODCALLTYPE hk_Reset(ID3D12GraphicsCommandList *list, ID3D12CommandAllocator *allocator,
        ID3D12PipelineState *pso)
{
    HRESULT (STDMETHODCALLTYPE *orig)(ID3D12GraphicsCommandList *, ID3D12CommandAllocator *, ID3D12PipelineState *)
            = orig_fn(list, LIST_IDX(Reset));

    note_bound(list, pso);
    return orig(list, allocator, pso);
}

static void STDMETHODCALLTYPE hk_Dispatch(ID3D12GraphicsCommandList *list, UINT x, UINT y, UINT z)
{
    void (STDMETHODCALLTYPE *orig)(ID3D12GraphicsCommandList *, UINT, UINT, UINT) = orig_fn(list, LIST_IDX(Dispatch));

    orig(list, x, y, z);
    if (fog_bound(list))
    {
        D3D12_RESOURCE_BARRIER barrier;

        memset(&barrier, 0, sizeof(barrier));
        barrier.Type = D3D12_RESOURCE_BARRIER_TYPE_UAV;
        barrier.UAV.pResource = NULL;
        ID3D12GraphicsCommandList_ResourceBarrier(list, 1, &barrier);
        if (InterlockedIncrement(&g_fog_barriers) == 1)
            log_msg("First fog barrier issued");
    }
}

static void hook_list(void *list)
{
    if (!g_fog_barrier || !list)
        return;
    if (!hook_slot(list, LIST_IDX(SetPipelineState), (void *)hk_SetPipelineState)
            || !hook_slot(list, LIST_IDX(Reset), (void *)hk_Reset)
            || !hook_slot(list, LIST_IDX(Dispatch), (void *)hk_Dispatch))
        log_msg("Couldn't hook command list %p: no fog barrier on it", list);
}

static HRESULT STDMETHODCALLTYPE hk_CreateCommandList(ID3D12Device *device, UINT mask, D3D12_COMMAND_LIST_TYPE type,
        ID3D12CommandAllocator *allocator, ID3D12PipelineState *pso, REFIID riid, void **list)
{
    HRESULT (STDMETHODCALLTYPE *orig)(ID3D12Device *, UINT, D3D12_COMMAND_LIST_TYPE, ID3D12CommandAllocator *,
            ID3D12PipelineState *, REFIID, void **) = orig_fn(device, DEV_IDX(CreateCommandList));
    HRESULT hr = orig(device, mask, type, allocator, pso, riid, list);

    if (SUCCEEDED(hr) && list && *list && type != D3D12_COMMAND_LIST_TYPE_COPY)
    {
        hook_list(*list);
        note_bound(*list, pso);
    }
    return hr;
}

static HRESULT STDMETHODCALLTYPE hk_CreateCommandList1(ID3D12Device4 *device, UINT mask, D3D12_COMMAND_LIST_TYPE type,
        D3D12_COMMAND_LIST_FLAGS flags, REFIID riid, void **list)
{
    HRESULT (STDMETHODCALLTYPE *orig)(ID3D12Device4 *, UINT, D3D12_COMMAND_LIST_TYPE, D3D12_COMMAND_LIST_FLAGS,
            REFIID, void **) = orig_fn(device, DEV_IDX(CreateCommandList1));
    HRESULT hr = orig(device, mask, type, flags, riid, list);

    if (SUCCEEDED(hr) && list && *list && type != D3D12_COMMAND_LIST_TYPE_COPY)
        hook_list(*list);
    return hr;
}

/* ---------------------------------------------------------------- the fix's device hooks (macprotips) */

/* The rewritten copy of a shader, if it is one of the fix's. */
static const void *replacement(const void *code, size_t size, size_t *out_size)
{
    uint64_t hash;
    unsigned int i;

    if (!code || size < 32)
        return NULL;
    hash = sm2_shader_hash(code, size);
    for (i = 0; i < g_shader_count; i++)
    {
        if (g_shaders[i].hash == hash)
        {
            *out_size = g_shaders[i].size;
            return g_shaders[i].data;
        }
    }
    return NULL;
}

static HRESULT STDMETHODCALLTYPE hk_CreateComputePipelineState(ID3D12Device *device,
        const D3D12_COMPUTE_PIPELINE_STATE_DESC *desc, REFIID riid, void **pso)
{
    HRESULT (STDMETHODCALLTYPE *orig)(ID3D12Device *, const D3D12_COMPUTE_PIPELINE_STATE_DESC *, REFIID, void **)
            = orig_fn(device, DEV_IDX(CreateComputePipelineState));
    const void *alt;
    size_t alt_size;
    HRESULT hr;

    if (desc && (alt = replacement(desc->CS.pShaderBytecode, desc->CS.BytecodeLength, &alt_size)))
    {
        D3D12_COMPUTE_PIPELINE_STATE_DESC copy = *desc;

        copy.CS.pShaderBytecode = alt;
        copy.CS.BytecodeLength = alt_size;
        hr = orig(device, &copy, riid, pso);
        log_msg("Replaced shader %016llx: %s", (unsigned long long)sm2_shader_hash(desc->CS.pShaderBytecode,
                desc->CS.BytecodeLength), SUCCEEDED(hr) ? "ok" : "FAILED, using the game's own");
        if (SUCCEEDED(hr))
        {
            InterlockedIncrement(&g_pipelines);
            return hr;
        }
    }
    hr = orig(device, desc, riid, pso);
    if (SUCCEEDED(hr) && desc && pso)
        note_pso(desc->CS.pShaderBytecode, desc->CS.BytecodeLength, *pso);
    return hr;
}

static HRESULT STDMETHODCALLTYPE hk_CreatePipelineState(ID3D12Device2 *device,
        const D3D12_PIPELINE_STATE_STREAM_DESC *desc, REFIID riid, void **pso)
{
    HRESULT (STDMETHODCALLTYPE *orig)(ID3D12Device2 *, const D3D12_PIPELINE_STATE_STREAM_DESC *, REFIID, void **)
            = orig_fn(device, DEV_IDX(CreatePipelineState));
    const void *code = NULL, *alt;
    size_t size = 0, alt_size;
    long at;
    BOOL compute = desc && sm2_stream_find_cs(desc->pPipelineStateSubobjectStream, desc->SizeInBytes, &code, &size)
            == SM2_STREAM_COMPUTE;
    HRESULT hr;

    if (compute && (alt = replacement(code, size, &alt_size))
            && (at = sm2_stream_cs_offset(desc->pPipelineStateSubobjectStream, desc->SizeInBytes)) >= 0)
    {
        BYTE *copy = malloc(desc->SizeInBytes);
        D3D12_PIPELINE_STATE_STREAM_DESC patched = *desc;
        UINT64 len = alt_size;

        if (copy)
        {
            memcpy(copy, desc->pPipelineStateSubobjectStream, desc->SizeInBytes);
            memcpy(copy + at + 8, &alt, sizeof(alt));
            memcpy(copy + at + 16, &len, sizeof(len));
            patched.pPipelineStateSubobjectStream = copy;
            hr = orig(device, &patched, riid, pso);
            free(copy);
            log_msg("Replaced shader %016llx: %s", (unsigned long long)sm2_shader_hash(code, size),
                    SUCCEEDED(hr) ? "ok" : "FAILED, using the game's own");
            if (SUCCEEDED(hr))
            {
                InterlockedIncrement(&g_pipelines);
                return hr;
            }
        }
    }
    hr = orig(device, desc, riid, pso);
    if (SUCCEEDED(hr) && compute && pso)
        note_pso(code, size, *pso);
    return hr;
}

static void STDMETHODCALLTYPE hk_CreateShaderResourceView(ID3D12Device *device, ID3D12Resource *resource,
        const D3D12_SHADER_RESOURCE_VIEW_DESC *desc, D3D12_CPU_DESCRIPTOR_HANDLE handle)
{
    void (STDMETHODCALLTYPE *orig)(ID3D12Device *, ID3D12Resource *, const D3D12_SHADER_RESOURCE_VIEW_DESC *,
            D3D12_CPU_DESCRIPTOR_HANDLE) = orig_fn(device, DEV_IDX(CreateShaderResourceView));

    if (desc && desc->ViewDimension == D3D12_SRV_DIMENSION_BUFFER && desc->Buffer.NumElements > WIDE_VIEW
            && !(desc->Buffer.Flags & D3D12_BUFFER_SRV_FLAG_RAW)
            && (desc->Format == DXGI_FORMAT_R32_UINT || desc->Format == DXGI_FORMAT_R32_SINT
                || desc->Format == DXGI_FORMAT_R32_FLOAT))
    {
        D3D12_SHADER_RESOURCE_VIEW_DESC raw = *desc;

        raw.Format = DXGI_FORMAT_R32_TYPELESS;
        raw.Buffer.Flags |= D3D12_BUFFER_SRV_FLAG_RAW;
        raw.Buffer.StructureByteStride = 0;
        if (InterlockedIncrement(&g_views) <= 4)
            log_msg("Wide typed view (%u elements) created as a raw view", desc->Buffer.NumElements);
        orig(device, resource, &raw, handle);
        return;
    }
    orig(device, resource, desc, handle);
}

static void STDMETHODCALLTYPE hk_CreateUnorderedAccessView(ID3D12Device *device, ID3D12Resource *resource,
        ID3D12Resource *counter, const D3D12_UNORDERED_ACCESS_VIEW_DESC *desc, D3D12_CPU_DESCRIPTOR_HANDLE handle)
{
    void (STDMETHODCALLTYPE *orig)(ID3D12Device *, ID3D12Resource *, ID3D12Resource *,
            const D3D12_UNORDERED_ACCESS_VIEW_DESC *, D3D12_CPU_DESCRIPTOR_HANDLE)
            = orig_fn(device, DEV_IDX(CreateUnorderedAccessView));

    if (desc && desc->ViewDimension == D3D12_UAV_DIMENSION_BUFFER && desc->Buffer.NumElements > WIDE_VIEW
            && !counter && !(desc->Buffer.Flags & D3D12_BUFFER_UAV_FLAG_RAW)
            && (desc->Format == DXGI_FORMAT_R32_UINT || desc->Format == DXGI_FORMAT_R32_SINT
                || desc->Format == DXGI_FORMAT_R32_FLOAT))
    {
        D3D12_UNORDERED_ACCESS_VIEW_DESC raw = *desc;

        raw.Format = DXGI_FORMAT_R32_TYPELESS;
        raw.Buffer.Flags |= D3D12_BUFFER_UAV_FLAG_RAW;
        raw.Buffer.StructureByteStride = 0;
        raw.Buffer.CounterOffsetInBytes = 0;
        if (InterlockedIncrement(&g_uavs) <= 4)
            log_msg("Wide typed UAV (%u elements) created as a raw view", desc->Buffer.NumElements);
        orig(device, resource, counter, &raw, handle);
        return;
    }
    orig(device, resource, counter, desc, handle);
}

static void hook_device(IUnknown *device)
{
    static const struct { const IID *iid; int version; } ifaces[] =
    {
        {&IID_ID3D12Device, 0}, {&IID_ID3D12Device1, 1}, {&IID_ID3D12Device2, 2}, {&IID_ID3D12Device3, 3},
        {&IID_ID3D12Device4, 4}, {&IID_ID3D12Device5, 5}, {&IID_ID3D12Device6, 6}, {&IID_ID3D12Device7, 7},
        {&IID_ID3D12Device8, 8}, {&IID_ID3D12Device9, 9}, {&IID_ID3D12Device10, 10},
    };
    unsigned int i;

    for (i = 0; i < ARRAYSIZE(ifaces); i++)
    {
        IUnknown *iface = NULL;

        if (FAILED(device->lpVtbl->QueryInterface(device, ifaces[i].iid, (void **)&iface)) || !iface)
            continue;
        hook_slot(iface, DEV_IDX(CreateComputePipelineState), (void *)hk_CreateComputePipelineState);
        hook_slot(iface, DEV_IDX(CreateShaderResourceView), (void *)hk_CreateShaderResourceView);
        hook_slot(iface, DEV_IDX(CreateUnorderedAccessView), (void *)hk_CreateUnorderedAccessView);
        if (ifaces[i].version >= 2)
            hook_slot(iface, DEV_IDX(CreatePipelineState), (void *)hk_CreatePipelineState);
        if (g_fog_barrier)
        {
            hook_slot(iface, DEV_IDX(CreateCommandList), (void *)hk_CreateCommandList);
            if (ifaces[i].version >= 4)
                hook_slot(iface, DEV_IDX(CreateCommandList1), (void *)hk_CreateCommandList1);
        }
        iface->lpVtbl->Release(iface);
    }
}

static HRESULT WINAPI carrier_D3D12CreateDevice(IUnknown *adapter, D3D_FEATURE_LEVEL level, REFIID riid, void **device)
{
    HRESULT hr;

    ensure_init();
    hr = g_create_device(adapter, level, riid, device);
    if (SUCCEEDED(hr) && g_active && device && *device)
    {
        hook_device(*device);
        log_msg("Device %p hooked", *device);
    }
    return hr;
}

/* ---------------------------------------------------------------- d3d12.dll export redirect (ours) */

/* A jump to carrier_D3D12CreateDevice placed within 4 GB above d3d12.dll's base, so its export-table entry
 * (a 32-bit RVA) can point at it: jmp qword ptr [rip+0] followed by the 8-byte target. */
static void *place_jump(BYTE *base, SIZE_T image_size, void *target)
{
    BYTE *at = (BYTE *)(((ULONG_PTR)base + image_size + 0xffff) & ~(ULONG_PTR)0xffff);
    MEMORY_BASIC_INFORMATION info;
    BYTE *code = NULL;
    DWORD old;

    while (at < base + 0xf0000000 && VirtualQuery(at, &info, sizeof(info)))
    {
        if (info.State == MEM_FREE
                && (code = VirtualAlloc(at, 0x1000, MEM_RESERVE | MEM_COMMIT, PAGE_EXECUTE_READWRITE)))
            break;
        at = (BYTE *)(((ULONG_PTR)info.BaseAddress + info.RegionSize + 0xffff) & ~(ULONG_PTR)0xffff);
    }
    if (!code)
        return NULL;
    code[0] = 0xff;
    code[1] = 0x25;
    memset(code + 2, 0, 4);
    memcpy(code + 6, &target, sizeof(target));
    VirtualProtect(code, 0x1000, PAGE_EXECUTE_READ, &old);
    FlushInstructionCache(GetCurrentProcess(), code, 14);
    return code;
}

/* Points d3d12.dll's D3D12CreateDevice export at this module; keeps the original. Runs under the loader lock
 * (from the notification), so it only touches memory. */
static void redirect_d3d12(BYTE *base)
{
    const IMAGE_DOS_HEADER *dos = (const IMAGE_DOS_HEADER *)base;
    const IMAGE_NT_HEADERS64 *nt;
    const IMAGE_DATA_DIRECTORY *dir;
    const IMAGE_EXPORT_DIRECTORY *exports;
    const DWORD *names;
    const WORD *ordinals;
    DWORD *functions, i, old;
    void *jump;

    if (g_redirected || dos->e_magic != IMAGE_DOS_SIGNATURE)
        return;
    nt = (const IMAGE_NT_HEADERS64 *)(base + dos->e_lfanew);
    dir = &nt->OptionalHeader.DataDirectory[IMAGE_DIRECTORY_ENTRY_EXPORT];
    if (!dir->VirtualAddress)
        return;
    exports = (const IMAGE_EXPORT_DIRECTORY *)(base + dir->VirtualAddress);
    names = (const DWORD *)(base + exports->AddressOfNames);
    ordinals = (const WORD *)(base + exports->AddressOfNameOrdinals);
    functions = (DWORD *)(base + exports->AddressOfFunctions);
    for (i = 0; i < exports->NumberOfNames; i++)
    {
        DWORD *slot;

        if (strcmp((const char *)(base + names[i]), "D3D12CreateDevice"))
            continue;
        slot = &functions[ordinals[i]];
        if (*slot >= dir->VirtualAddress && *slot < dir->VirtualAddress + dir->Size)
            return;   /* a forwarder string, not code: leave it alone */
        if (!(jump = place_jump(base, nt->OptionalHeader.SizeOfImage, (void *)carrier_D3D12CreateDevice)))
            return;
        g_create_device = (PFN_CREATE_DEVICE)(base + *slot);
        if (!VirtualProtect(slot, sizeof(*slot), PAGE_READWRITE, &old))
            return;
        *slot = (DWORD)((BYTE *)jump - base);
        VirtualProtect(slot, sizeof(*slot), old, &old);
        g_redirected = 1;
        return;
    }
}

/* LdrRegisterDllNotification's types (not in mingw's headers). */
typedef struct
{
    ULONG Flags;
    const UNICODE_STRING *FullDllName;
    const UNICODE_STRING *BaseDllName;
    void *DllBase;
    ULONG SizeOfImage;
} DLL_NOTIFICATION_DATA;
typedef void (CALLBACK *DLL_NOTIFICATION_FN)(ULONG reason, const DLL_NOTIFICATION_DATA *data, void *context);
typedef LONG (NTAPI *PFN_REGISTER_NOTIFICATION)(ULONG flags, DLL_NOTIFICATION_FN fn, void *context, void **cookie);
#define DLL_NOTIFICATION_LOADED 1

static BOOL is_d3d12(const UNICODE_STRING *name)
{
    return name && name->Length == 9 * sizeof(WCHAR) && !_wcsnicmp(name->Buffer, L"d3d12.dll", 9);
}

static void CALLBACK on_dll(ULONG reason, const DLL_NOTIFICATION_DATA *data, void *context)
{
    if (reason == DLL_NOTIFICATION_LOADED && data && is_d3d12(data->BaseDllName))
        redirect_d3d12(data->DllBase);
}

static void watch_for_d3d12(void)
{
    PFN_REGISTER_NOTIFICATION reg = (PFN_REGISTER_NOTIFICATION)(void *)GetProcAddress(GetModuleHandleW(L"ntdll.dll"),
            "LdrRegisterDllNotification");
    HMODULE loaded = GetModuleHandleW(L"d3d12.dll");
    void *cookie;

    if (loaded)
        redirect_d3d12((BYTE *)loaded);
    else if (reg)
        reg(0, on_dll, NULL, &cookie);
}

BOOL WINAPI DllMain(HINSTANCE instance, DWORD reason, void *reserved)
{
    if (reason == DLL_PROCESS_ATTACH)
    {
        g_self = instance;
        DisableThreadLibraryCalls(instance);
        watch_for_d3d12();
    }
    else if (reason == DLL_PROCESS_DETACH && g_log)
    {
        if (g_active)
            fprintf(g_log, "Exit: %ld shaders replaced, %ld wide views and %ld wide UAVs made raw, %ld fog barriers\n",
                    (long)g_pipelines, (long)g_views, (long)g_uavs, (long)g_fog_barriers);
        fclose(g_log);
        g_log = NULL;
    }
    return TRUE;
}
