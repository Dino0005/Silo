/*
 * Silo's pipeline cache for a game started from macOS Steam under GPTK: pipeline_cache.mm,
 * run inside the game's own process, where D3DMetal is loaded.
 *
 * Derived from MacGameFix's fixes/pbz-pipeline-cache/rosetta_pipeline_cache.mm
 * (Mathias Kowoll, GPL-3.0; MacGameFix cc9c13a, from NotProton's
 * experiments/fex-d3dmetal-bridge 4c8b173). Changed for Silo, 2026-11-24: Silo's
 * variable names and folder, the game named by Silo (SILO_PIPELINE_CACHE_GAME, a
 * Steam app id) rather than by the process, and no bridge worker to skip.
 * pipeline_cache.mm itself is unchanged.
 *
 * Metal's system cache, a fixed file of about 1.1 GB per app, fills: UNCHARTED's
 * stood at 1,140,781,056 bytes on 2026-11-23, and every shader it could not keep
 * was compiled again at every launch.
 *
 * Silo injects this library into the Wine processes of the launch (SteamLibrariesRunner)
 * when the game's "pipeline cache" switch is on. Nothing happens until D3DMetal itself
 * asks Metal for a device: MTLCreateSystemDefaultDevice and MTLCopyAllDevices are
 * interposed, and the first call made from D3DMetal's image starts the cache, after
 * the call has returned, outside any loader lock. Other processes are left alone.
 *
 * Archives go to <user cache>/io.github.dino0005.silo/pipelines/<game>/<GPU>-<OS build>/.
 * SILO_PIPELINE_CACHE_MAX_MB caps what is written (10240); SILO_PIPELINE_CACHE=0 keeps
 * only the counting.
 */
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <atomic>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <dlfcn.h>

extern "C" void pbz_pipeline_cache_configure(const char *prefix, const char *off, const char *cap, const char *root);
extern "C" void pbz_pipeline_cache_start(const char *game);
extern "C" void pbz_pipeline_cache_finish_within(const char *why, double seconds);

namespace {

std::atomic<bool> started;

/* wineserver kills a Wine process about a second after it starts to end, so the end
 * waits a little for pipelines still being written; what is cut off is compiled and
 * kept again next time, and the next start removes its folders and .part files. */
void finish_at_exit()
{
    pbz_pipeline_cache_finish_within("the game ended", 0.3);
}

/* Starts the cache the first time D3DMetal asks for a device. */
void start_for(const void *caller)
{
    if (started.load(std::memory_order_acquire)) return;
    Dl_info info;
    if (!dladdr(caller, &info) || !info.dli_fname || !std::strstr(info.dli_fname, "/D3DMetal")) return;
    if (started.exchange(true)) return;
    pbz_pipeline_cache_configure("silo", "SILO_PIPELINE_CACHE", "SILO_PIPELINE_CACHE_MAX_MB", "io.github.dino0005.silo");
    const char *game = std::getenv("SILO_PIPELINE_CACHE_GAME");
    if (!game || !*game) game = getprogname();
    std::fprintf(stderr, "silo: pipeline cache: starting for %s\n", game);
    pbz_pipeline_cache_start(game);
    std::atexit(finish_at_exit);
}

id<MTLDevice> interposed_create_device(void)
{
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    start_for(__builtin_return_address(0));
    return device;
}

NSArray<id<MTLDevice>> *interposed_copy_devices(void)
{
    NSArray<id<MTLDevice>> *devices = MTLCopyAllDevices();
    start_for(__builtin_return_address(0));
    return devices;
}

} // namespace

/* dyld's interposing: every other image's calls come here; this image's own go to Metal. */
__attribute__((used, section("__DATA,__interpose"))) static const struct
{
    const void *replacement;
    const void *original;
} interposers[] = {
    {reinterpret_cast<const void *>(interposed_create_device), reinterpret_cast<const void *>(MTLCreateSystemDefaultDevice)},
    {reinterpret_cast<const void *>(interposed_copy_devices), reinterpret_cast<const void *>(MTLCopyAllDevices)},
};
