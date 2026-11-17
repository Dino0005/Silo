// silo-overlay-fix.dylib — injected next to Steam's gameoverlayrenderer.dylib into a game started from macOS Steam
// (SteamOverlayFix.swift). Steam's overlay builds its render pipelines for a fixed set of formats (measured on
// SOULCALIBUR VI, 2026-11-13: BGRA8, BGRA8 sRGB, BGR10A2, RGBA16F) and draws with the BGRA8 one into whatever the
// game presents. D3DMetal presents RGB10A2, so the overlay's pipeline doesn't match the drawable and Metal writes
// garbage: the overlay came out as coloured noise. Here, when an encoder the overlay opens targets a format its
// pipeline wasn't built for, the pipeline is swapped for a copy built from the same descriptor with the target's
// format — Steam's drawing, the right format. Everything else (the game's own rendering) is left alone.
//
// Installed lazily, on the first -[CAMetalLayer setPixelFormat:] (the game sets its layer's format before the overlay
// builds its pipelines), so Wine's helper processes, which get the same injection but never draw, never touch Metal.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#include <dlfcn.h>
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
    dispatch_once(&once, ^{ install(self.device ?: MTLCreateSystemDefaultDevice()); });
    ((void (*)(id, SEL, MTLPixelFormat))origSetPixelFormat)(self, _cmd, format);
}

__attribute__((constructor)) static void start(void) {
    swizzle([CAMetalLayer class], @selector(setPixelFormat:), (IMP)hSetPixelFormat, &origSetPixelFormat);
}
