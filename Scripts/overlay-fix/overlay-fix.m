// silo-overlay-fix.dylib — injected next to Steam's gameoverlayrenderer.dylib into a game started from macOS Steam
// (SteamOverlayFix.swift). Steam's overlay builds its render pipelines for a fixed set of formats (measured on
// SOULCALIBUR VI, 2026-11-13: BGRA8, BGRA8 sRGB, BGR10A2, RGBA16F) and draws with the BGRA8 one into whatever the
// game presents. D3DMetal presents RGB10A2, so the overlay's pipeline doesn't match the drawable and Metal writes
// garbage: the overlay came out as coloured noise. Here, when an encoder the overlay opens targets a format its
// pipeline wasn't built for, the pipeline is swapped for a copy built from the same descriptor with the target's
// format — Steam's drawing, the right format. Everything else (the game's own rendering) is left alone.
//
// Metal 4 (2026-11-19): Steam's overlay hooks only Metal 3's present —
// -[MTLCommandBuffer presentDrawable:] — and D3DMetal on Metal 4 presents with -[MTL4CommandQueue signalDrawable:] then
// -[CAMetalDrawable present], so the overlay never sees a frame (Spider-Man, RE Requiem, TLOU II: Shift+Tab opens it
// invisibly, the start toast flickers). The bridge (on; SILO_OVERLAY_BRIDGE=0 turns it off): when the MTL4 queue signals a drawable it also
// signals a shared event; that drawable's -present then goes through a Metal 3 command buffer on the same device that
// waits for the event and presents it — where the overlay draws — exactly once. SILO_OVERLAY_LOG=<file> logs which
// present calls the game makes. Own code; the idea of bridging the present is NotProton's overlay-shim (GPL, not copied).
//
// Installed lazily, on the first -[CAMetalLayer setPixelFormat:] (the game sets its layer's format before the overlay
// builds its pipelines), so Wine's helper processes, which get the same injection but never draw, never touch Metal.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static const void *kDescriptor = &kDescriptor, *kTarget = &kTarget, *kVariants = &kVariants;
static IMP origSetPixelFormat, origPipeline, origPipelineReflect, origEncoder, origSetPipeline;

// Whether the caller is Steam's overlay.
static BOOL fromOverlay(void *address) {
    Dl_info info;
    return dladdr(address, &info) && info.dli_fname && strstr(info.dli_fname, "gameoverlayrenderer");
}

static id remember(id pipeline, MTLRenderPipelineDescriptor *descriptor) {
    if (pipeline) objc_setAssociatedObject(pipeline, kDescriptor, [descriptor copy], OBJC_ASSOCIATION_RETAIN);
    return pipeline;
}

static id hPipeline(id self, SEL _cmd, MTLRenderPipelineDescriptor *d, NSError **e) {
    id p = ((id (*)(id, SEL, id, NSError **))origPipeline)(self, _cmd, d, e);
    return fromOverlay(__builtin_return_address(0)) ? remember(p, d) : p;
}

static id hPipelineReflect(id self, SEL _cmd, MTLRenderPipelineDescriptor *d, MTLPipelineOption o, id *r, NSError **e) {
    id p = ((id (*)(id, SEL, id, MTLPipelineOption, id *, NSError **))origPipelineReflect)(self, _cmd, d, o, r, e);
    return fromOverlay(__builtin_return_address(0)) ? remember(p, d) : p;
}

static id hEncoder(id self, SEL _cmd, MTLRenderPassDescriptor *pass) {
    id encoder = ((id (*)(id, SEL, id))origEncoder)(self, _cmd, pass);
    id<MTLTexture> target = pass.colorAttachments[0].texture;
    if (encoder && target && fromOverlay(__builtin_return_address(0)))
        objc_setAssociatedObject(encoder, kTarget, @(target.pixelFormat), OBJC_ASSOCIATION_RETAIN);
    return encoder;
}

static void hSetPipeline(id self, SEL _cmd, id<MTLRenderPipelineState> pipeline) {
    NSNumber *target = objc_getAssociatedObject(self, kTarget);
    MTLRenderPipelineDescriptor *descriptor = (target && pipeline) ? objc_getAssociatedObject(pipeline, kDescriptor) : nil;
    if (descriptor && descriptor.colorAttachments[0].pixelFormat != target.unsignedIntegerValue) {
        @synchronized (pipeline) {
            NSMutableDictionary *variants = objc_getAssociatedObject(pipeline, kVariants);
            if (!variants) {
                variants = [NSMutableDictionary new];
                objc_setAssociatedObject(pipeline, kVariants, variants, OBJC_ASSOCIATION_RETAIN);
            }
            id variant = variants[target];
            if (!variant) {
                MTLRenderPipelineDescriptor *copy = [descriptor copy];
                copy.colorAttachments[0].pixelFormat = target.unsignedIntegerValue;
                variant = ((id (*)(id, SEL, id, NSError **))origPipeline)(
                    pipeline.device, @selector(newRenderPipelineStateWithDescriptor:error:), copy, NULL);
                variants[target] = variant ?: [NSNull null];
            }
            if (variant != [NSNull null]) pipeline = variant;
        }
    }
    ((void (*)(id, SEL, id))origSetPipeline)(self, _cmd, pipeline);
}

static void swizzle(Class c, SEL s, IMP replacement, IMP *original) {
    Method m = c ? class_getInstanceMethod(c, s) : NULL;
    if (m) *original = method_setImplementation(m, replacement);
}

// MARK: - Metal 4 present bridge

static IMP origSignalDrawable, origPresent, origPresentAtTime, origPresentAfter, origPresentDrawable, origNextDrawable;
static const void *kSignaled = &kSignaled;
static BOOL bridgeOn;
static FILE *probeLog;
static id<MTLSharedEvent> bridgeEvent;
static id<MTLCommandQueue> bridgeQueue;
static uint64_t bridgeValue;
static unsigned long nSignal, nPresent, nBridged, nPresentAtTime, nPresentAfter, nPresentDrawable;

static void probe(const char *what) {
    if (!probeLog) return;
    unsigned long total = nPresent + nPresentAtTime + nPresentAfter + nPresentDrawable;
    if (total <= 5 || total % 600 == 0) {
        fprintf(probeLog, "%s | signalDrawable %lu, present %lu (bridged %lu), presentAtTime %lu, presentAfter %lu, "
                "cb presentDrawable %lu\n", what, nSignal, nPresent, nBridged, nPresentAtTime, nPresentAfter, nPresentDrawable);
        fflush(probeLog);
    }
}

static void hSignalDrawable(id self, SEL _cmd, id drawable) {
    ((void (*)(id, SEL, id))origSignalDrawable)(self, _cmd, drawable);
    nSignal++;
    if (!bridgeOn || !drawable) return;
    uint64_t value;
    @synchronized ([CAMetalLayer class]) {
        if (!bridgeEvent) {
            id<MTLDevice> device = ((id<MTL4CommandQueue>)self).device;
            bridgeEvent = [device newSharedEvent];
            bridgeQueue = [device newCommandQueue];
        }
        value = ++bridgeValue;
    }
    // After the drawable's own signal on the same queue: the event fires once the game's rendering of it is done.
    [(id<MTL4CommandQueue>)self signalEvent:bridgeEvent value:value];
    objc_setAssociatedObject(drawable, kSignaled, @(value), OBJC_ASSOCIATION_RETAIN);
}

// Presents `drawable` — signaled by the game's MTL4 queue at `value` — through a Metal 3 command buffer that waits for
// the game's rendering, so the overlay's present hook draws onto it. `duration` < 0: plain present. Returns NO when the
// drawable wasn't one of the bridged ones (the caller presents it itself).
static BOOL bridgePresent(id drawable, CFTimeInterval duration) {
    NSNumber *value = objc_getAssociatedObject(drawable, kSignaled);
    if (!value || !bridgeQueue) return NO;
    objc_setAssociatedObject(drawable, kSignaled, nil, OBJC_ASSOCIATION_RETAIN);   // the inner present passes through
    id<MTLCommandBuffer> buffer = [bridgeQueue commandBuffer];
    [buffer encodeWaitForEvent:bridgeEvent value:value.unsignedLongLongValue];
    // Always the plain present, even for presentAfterMinimumDuration:: that is the one the overlay draws on (measured on
    // Spider-Man, 2026-11-19: overlay and start toast shown, no stutter from launch to the main menu). Its hook isn't a
    // method swizzle on this class (method_getImplementation pointed into Metal), so it can't be detected up front.
    (void)duration;
    [buffer presentDrawable:drawable];
    [buffer commit];
    nBridged++;
    return YES;
}

static void hPresent(id self, SEL _cmd) {
    nPresent++;
    if (bridgePresent(self, -1)) { probe("present (bridged)"); return; }
    probe("present");
    ((void (*)(id, SEL))origPresent)(self, _cmd);
}

static void hPresentAtTime(id self, SEL _cmd, CFTimeInterval t) {
    nPresentAtTime++; probe("presentAtTime");
    ((void (*)(id, SEL, CFTimeInterval))origPresentAtTime)(self, _cmd, t);
}

static void hPresentAfter(id self, SEL _cmd, CFTimeInterval d) {
    nPresentAfter++;
    if (bridgePresent(self, d)) { probe("presentAfterMinimumDuration (bridged)"); return; }
    probe("presentAfterMinimumDuration");
    ((void (*)(id, SEL, CFTimeInterval))origPresentAfter)(self, _cmd, d);
}

static void hPresentDrawable(id self, SEL _cmd, id drawable) {
    if (!fromOverlay(__builtin_return_address(0))) { nPresentDrawable++; probe("cb presentDrawable"); }
    ((void (*)(id, SEL, id))origPresentDrawable)(self, _cmd, drawable);
}

// The drawable's concrete class is known once the layer hands one out.
static id hNextDrawable(CAMetalLayer *self, SEL _cmd) {
    id drawable = ((id (*)(id, SEL))origNextDrawable)(self, _cmd);
    static dispatch_once_t once;
    if (drawable) dispatch_once(&once, ^{
        Class c = [drawable class];
        // D3DMetal on Metal 4 presents with presentAfterMinimumDuration: (measured on Spider-Man, 2026-11-19: every frame).
        swizzle(c, @selector(present), (IMP)hPresent, &origPresent);
        swizzle(c, @selector(presentAfterMinimumDuration:), (IMP)hPresentAfter, &origPresentAfter);
        if (probeLog) {
            swizzle(c, @selector(presentAtTime:), (IMP)hPresentAtTime, &origPresentAtTime);
            fprintf(probeLog, "drawable class %s, bridge %s\n", class_getName(c), bridgeOn ? "on" : "off");
            fflush(probeLog);
        }
    });
    return drawable;
}

static void installBridge(id<MTLDevice> device) {
    const char *logPath = getenv("SILO_OVERLAY_LOG");
    if (logPath && *logPath) probeLog = fopen(logPath, "a");
    const char *bridge = getenv("SILO_OVERLAY_BRIDGE");
    bridgeOn = !(bridge && !strcmp(bridge, "0"));   // on unless switched off; inert on Metal 3 (no MTL4 signal)
    if (!bridgeOn && !probeLog) return;
    if ([device respondsToSelector:@selector(newMTL4CommandQueue)]) {
        id<MTL4CommandQueue> queue = [device newMTL4CommandQueue];
        swizzle([queue class], @selector(signalDrawable:), (IMP)hSignalDrawable, &origSignalDrawable);
    }
    swizzle([CAMetalLayer class], @selector(nextDrawable), (IMP)hNextDrawable, &origNextDrawable);
    if (probeLog) {
        id<MTLCommandBuffer> buffer = [[device newCommandQueue] commandBuffer];
        swizzle([buffer class], @selector(presentDrawable:), (IMP)hPresentDrawable, &origPresentDrawable);
        fprintf(probeLog, "installed: MTL4 queue hook %s\n", origSignalDrawable ? "yes" : "no");
        fflush(probeLog);
    }
}

// The concrete Metal classes come from a live device: a command buffer and a render encoder are made once to find them.
static void install(id<MTLDevice> device) {
    if (!device) return;
    swizzle([device class], @selector(newRenderPipelineStateWithDescriptor:error:), (IMP)hPipeline, &origPipeline);
    swizzle([device class], @selector(newRenderPipelineStateWithDescriptor:options:reflection:error:),
            (IMP)hPipelineReflect, &origPipelineReflect);
    if (!origPipeline) return;
    id<MTLCommandBuffer> buffer = [[device newCommandQueue] commandBuffer];
    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                                                  width:4 height:4 mipmapped:NO];
    td.usage = MTLTextureUsageRenderTarget;
    MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
    pass.colorAttachments[0].texture = [device newTextureWithDescriptor:td];
    id<MTLRenderCommandEncoder> encoder = [buffer renderCommandEncoderWithDescriptor:pass];
    swizzle([encoder class], @selector(setRenderPipelineState:), (IMP)hSetPipeline, &origSetPipeline);
    [encoder endEncoding];
    if (origSetPipeline) swizzle([buffer class], @selector(renderCommandEncoderWithDescriptor:), (IMP)hEncoder, &origEncoder);
}

static void hSetPixelFormat(CAMetalLayer *self, SEL _cmd, MTLPixelFormat format) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        id<MTLDevice> device = self.device ?: MTLCreateSystemDefaultDevice();
        install(device);
        installBridge(device);
    });
    ((void (*)(id, SEL, MTLPixelFormat))origSetPixelFormat)(self, _cmd, format);
}

__attribute__((constructor)) static void start(void) {
    swizzle([CAMetalLayer class], @selector(setPixelFormat:), (IMP)hSetPixelFormat, &origSetPixelFormat);
}
