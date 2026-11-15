// SPDX-License-Identifier: MIT
// Replacement OpenGLES.framework for the Bergamota Project (iOS 18.7.8 on the Poco F1).
//
// EAGLContext / EAGLSharegroup are implemented on top of Mesa's OSMesa frontend (gallium softpipe today,
// freedreno later: only libOSMesa changes). Every context is an OpenGL ES context (OSMesa profile 0x36, our
// Mesa patch) with a tiny dummy default framebuffer; real output goes through renderbuffers:
//   renderbufferStorage:fromDrawable:  -> glRenderbufferStorage at the drawable's pixel size
//   presentRenderbuffer:               -> read the renderbuffer back into an IOSurface (BGRA, rotating pool) and
//                                         hand it to the drawable (layer.contents = IOSurface)
//   attachImage:toCoreSurface:...      -> renderbuffer/texture <-> IOSurface association, flushed to the surface
//                                         on glFlush/glFinish/present (CoreAnimation's GLES renderer path)
//   texImageIOSurface:...              -> IOSurface pixels uploaded into the bound texture (copy)
#pragma clang diagnostic ignored "-Wobjc-designated-initializers"
#ifdef EAGL_INJECT
// Injection build (-DEAGL_INJECT): the system OpenGLES.framework lives in the dyld shared cache and cannot be replaced by path
// (dyld ignores DYLD_FRAMEWORK_PATH for cache dylibs). Our classes get other names here and, at load time, their methods are
// installed into the REAL EAGLContext / EAGLSharegroup classes (same single `_private` ivar), so every caller (QuartzCore
// included) reaches this implementation. See eagl_inject_patch() at the end of the file.
#define EAGLContext BGEAGLContext
#define EAGLSharegroup BGEAGLSharegroup
#endif
#import "eagl_private.h"
#import <objc/runtime.h>
#import <mach-o/dyld.h>
#import <pthread.h>
#import <sys/time.h>
#import <mach/mach.h>
#import <mach/vm_map.h>
#import <sys/stat.h>
#import <unistd.h>
#import <stdatomic.h>
#import <objc/message.h>
#import <math.h>
#include "osm.h"
#include "macro_ctx.h"
#import <OpenGLES/ES3/gl.h>
#import <OpenGLES/ES3/glext.h>
#import <CoreGraphics/CoreGraphics.h>
#include "gl_tab.h"


#ifndef GL_BGRA_EXT
#define GL_BGRA_EXT 0x80E1
#endif

#define EAGL_DEBUG(...) do { if (g_debug) fprintf(stderr, "EAGL(shim): " __VA_ARGS__); } while (0)
// Live IOSurface textures: iOS binds an IOSurface as texture storage, so a producer that writes the surface after the bind (glyph renderers, snapshot
// decoders, Control Center material) is seen at once. The shim copies at bind time; to keep the same behaviour every uploaded surface is remembered with its
// IOSurface seed and the texture is re-uploaded when it is bound again (glBindTexture) after the seed changed.
typedef struct { void *ctx; GLuint name; IOSurfaceRef surf; uint32_t seed, w, h, plane; GLenum ifmt, fmt, type; BOOL invert; BOOL wrapped; int verified; } LiveSrc;
#define MAX_LIVE 768
static LiveSrc g_live[MAX_LIVE]; static int g_nlive; static pthread_mutex_t g_live_lock = PTHREAD_MUTEX_INITIALIZER;
static int g_wrapsample;              // BGL_WRAPSAMPLE=1 (marker word "wrapsample"): sample client-memory IOSurfaces with the GPU instead of copying them (experimental)
static int fmtcopy_on(void) { static int v = -1; if (v < 0) { const char *s = getenv("BGL_FMTLESS_COPY"); v = !(s && s[0] == '0'); } return v; }   // default on: format-less surfaces take the clean+copy path, not the wrap
static int verify_on(void) { static int v = -1; if (v < 0) { const char *s = getenv("BGL_WRAPVERIFY"); v = s && s[0] == '1'; } return v; }         // BGL_WRAPVERIFY=1: compare GPU-sampled and CPU-read pixels right after a wrap
static int g_nowrap;                  // set while a wrapped texture is being converted back to a private copy
static int g_reupload;                // inside a re-upload: use glTexSubImage2D, keep the client's sampler state, do not register again
static unsigned g_live_reuploads;
extern void gl_unimpl(void);
static int g_direct = 1;            // display textures ARE the surface memory (default). BGL_NODIRECT=1 (boot-arg bgldirect=0, marker word "nodirect") falls back to texture + blit
static int g_dirty_track = 1;       // copy display-size attachments only when drawn into (default; BGL_SYNC_ALL=1 copies every attachment at every flush). Copying both double-buffered display textures every flush overwrote the idle surface with stale pixels: flicker and a missing wallpaper
static int g_debug, g_debug_frames;   // EAGL_SHIM_DEBUG=1: log + PIPE statistics; =2 also per-frame luminance and thumbnails
static volatile int g_target_attach;      // set once attachImage:<target> was used: the render server's convention (see texImageIOSurface)

#pragma GCC visibility push(default)
// --- constants -------------------------------------------------------------------------------------------
NSString *const kEAGLDrawablePropertyRetainedBacking = @"EAGLDrawablePropertyRetainedBacking";
NSString *const kEAGLDrawablePropertyColorFormat = @"EAGLDrawablePropertyColorFormat";
NSString *const kEAGLColorFormatRGBA8 = @"EAGLColorFormatRGBA8";
NSString *const kEAGLColorFormatRGB565 = @"EAGLColorFormatRGB565";
NSString *const kEAGLColorFormatSRGBA8 = @"EAGLColorFormatSRGBA8";
NSString *const kEAGLColorFormatRGBA_XR10_64BPP = @"EAGLColorFormatRGBA_XR10_64BPP";
NSString *const kEAGLColorFormatSRGBA_XR10_64BPP = @"EAGLColorFormatSRGBA_XR10_64BPP";
NSString *const kEAGLColorFormatSRGB_XR10 = @"EAGLColorFormatSRGB_XR10";
NSString *const kEAGLColorFormatSRGB_XR10_A8_2P = @"EAGLColorFormatSRGB_XR10_A8_2P";
NSString *const kEAGLContextPropertyAccelerated = @"EAGLContextPropertyAccelerated";
NSString *const kEAGLContextPropertyClientLabel = @"EAGLContextPropertyClientLabel";
NSString *const kEAGLContextPropertyClientRetainRelease = @"EAGLContextPropertyClientRetainRelease";
NSString *const kEAGLContextPropertySharedWithCompute = @"EAGLContextPropertySharedWithCompute";
NSString *const kEAGLContextPropertySharegroup = @"EAGLContextPropertySharegroup";
NSString *const kEAGLContextPropertyVisibleInDebugTools = @"EAGLContextPropertyVisibleInDebugTools";

__attribute__((visibility("default"))) void EAGLGetVersion(unsigned int *major, unsigned int *minor) {
    if (major) *major = EAGL_MAJOR_VERSION;
    if (minor) *minor = EAGL_MINOR_VERSION;
}
__attribute__((visibility("default"))) const char *EAGLShimVersionString(void) { return "Bergamota OpenGLES shim 0.1 (Mesa OSMesa/softpipe)"; }

#pragma GCC visibility pop

// --- private state ---------------------------------------------------------------------------------------
#define DUMMY_W 16
#define DUMMY_H 16
#define POOL_N 3
#define MAX_BIND 16

typedef struct {                    // renderbuffer bound to a drawable (renderbufferStorage:fromDrawable:)
    GLuint rb;
    id drawable;                    // retained
    uint32_t w, h;
    GLenum fmt;
    IOSurfaceRef pool[POOL_N];
    int next;
} DrawBind;

typedef struct {                    // attachImage:toCoreSurface:invertedRender:
    GLuint name;
    int kind;                       // 0 = a GL object name was given, 1 = texture bound at the given target, 2 = renderbuffer
    IOSurfaceRef surf;              // retained
    BOOL inverted;
    int direct;                     // the texture IS the surface memory (BGL_DIRECT): no blit, only finish + BO_SYNC
    int dirty;                      // drawn into (or newly attached) since the last sync: display-size attachments are copied only when dirty
} Attach;

struct _EAGLSharegroupPrivate {
    EAGLRenderingAPI api;
    pthread_mutex_t lock;
    void *live[64];                 // OSMesaContexts alive in this group (first one is the share root)
    int nlive;
};

struct _EAGLContextPrivate {
    osm_ctx osm;
    EAGLRenderingAPI api;
    EAGLSharegroup *sg;
    unsigned char *dummy;
    NSString *label;
    BOOL multithreaded;
    int params[64];
    DrawBind binds[MAX_BIND]; int nbinds;
    Attach att[MAX_BIND]; int natt;
    int cur_att;                    // index of the attachment the bound draw framebuffer renders into (colour 0), -1 = none
    BOOL target_nowrap;             // attachImage fallback: keep writable private storage (the wrap maps the surface read-only and draws into it are dropped)
    GLuint tmpfbo;
    GLuint bind2d;                  // last GL_TEXTURE_2D name bound on this context (any unit; cross-thread benign race)
    EAGLMacroContext *macro;
};

static pthread_key_t g_tls;
static pthread_once_t g_tls_once = PTHREAD_ONCE_INIT;
static void tls_init(void) { pthread_key_create(&g_tls, NULL); }

// osm_ctx -> EAGLContext registry: threads that glslot_gate borrowed a context onto have no TLS entry, but their
// hooks (dirty marking, attachment tracking, flush sync) must still see the context Mesa has current there.
static pthread_mutex_t g_ctxreg_lock = PTHREAD_MUTEX_INITIALIZER;
static struct { EAGLContext *ctx; void *osm; } g_ctxreg[16];
static void ctxreg_add(EAGLContext *c, void *osm) {
    pthread_mutex_lock(&g_ctxreg_lock);
    int slot = -1; for (int i = 0; i < 16; i++) { if (!g_ctxreg[i].ctx) { if (slot < 0) slot = i; } else if (g_ctxreg[i].osm == osm) { g_ctxreg[i].ctx = c; pthread_mutex_unlock(&g_ctxreg_lock); return; } }
    if (slot >= 0) { g_ctxreg[slot].ctx = c; g_ctxreg[slot].osm = osm; }
    pthread_mutex_unlock(&g_ctxreg_lock);
}
static void ctxreg_remove(void *osm) {
    pthread_mutex_lock(&g_ctxreg_lock);
    for (int i = 0; i < 16; i++) if (g_ctxreg[i].osm == osm) { g_ctxreg[i].ctx = NULL; g_ctxreg[i].osm = NULL; }
    pthread_mutex_unlock(&g_ctxreg_lock);
}

// --- helpers ---------------------------------------------------------------------------------------------
static IOSurfaceRef make_surface(uint32_t w, uint32_t h) {
    int32_t bpe = 4, fmt = 'BGRA';
    uint32_t bpr = (w * 4 + 63) & ~63u;
    CFNumberRef nw = CFNumberCreate(NULL, kCFNumberSInt32Type, &(int32_t){(int32_t)w});
    CFNumberRef nh = CFNumberCreate(NULL, kCFNumberSInt32Type, &(int32_t){(int32_t)h});
    CFNumberRef nb = CFNumberCreate(NULL, kCFNumberSInt32Type, &bpe);
    CFNumberRef nf = CFNumberCreate(NULL, kCFNumberSInt32Type, &fmt);
    CFNumberRef nr = CFNumberCreate(NULL, kCFNumberSInt32Type, &(int32_t){(int32_t)bpr});
    const void *keys[] = { kIOSurfaceWidth, kIOSurfaceHeight, kIOSurfaceBytesPerElement, kIOSurfacePixelFormat, kIOSurfaceBytesPerRow };
    const void *vals[] = { nw, nh, nb, nf, nr };
    CFDictionaryRef d = CFDictionaryCreate(NULL, keys, vals, 5, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    IOSurfaceRef s = IOSurfaceCreate(d);
    CFRelease(d); CFRelease(nw); CFRelease(nh); CFRelease(nb); CFRelease(nf); CFRelease(nr);
    return s;
}

static EAGLContext *cur_ctx(void) {
    pthread_once(&g_tls_once, tls_init);
    EAGLContext *c = (EAGLContext *)pthread_getspecific(g_tls);
    if (c) return c;
    // borrowed thread (glslot_gate made a context Mesa-current here): the hooks must see it too
    void *o = osm_cur_ctx();
    if (o) {
        pthread_mutex_lock(&g_ctxreg_lock);
        for (int i = 0; i < 16; i++) if (g_ctxreg[i].osm == o) { c = g_ctxreg[i].ctx; break; }
        pthread_mutex_unlock(&g_ctxreg_lock);
    }
    return c;
}
__attribute__((visibility("hidden"))) void *eagl_shim_cur_ctx_ptr(void) { return (void *)cur_ctx(); }   // macro_ctx.c trace enrichment: which context issues each call

// CoreAnimation issues GL through the EAGLMacroContext slots with the target context in x0 (rend = _EAGLContextPrivate).
// Its worker threads do so with NO context current: Apple's driver marshals the call to the context rend identifies,
// Mesa drops it as a no-op (this is how the lock-screen clock draws vanished). Borrow rend's Mesa context for this
// thread before the call reaches Mesa. CA's render and worker phases are sequential (trace-verified), so the borrow
// never races a render in flight; the render thread keeps its own current-context binding untouched.
__attribute__((visibility("hidden"))) void glslot_gate(void *r) {
    struct _EAGLContextPrivate *p = r;
    if (!p || !p->osm || osm_cur_ctx() == p->osm) return;   // render-thread fast path: already current here
    if (!osm_make_current(p->osm, p->dummy, DUMMY_W, DUMMY_H)) return;
    static unsigned n; if (g_debug && n++ < 60) EAGL_DEBUG("glslot_gate: borrowed ctx %p onto a context-less thread\n", p->osm);
}

// Copy an RGBA w*h bottom-up GL readback into a BGRA IOSurface, top-down (or bottom-up when `keep` is set).
// A display/swap-chain IOSurface can be mapped read-only in this process (a write then dies with SIGBUS / KERN_PROTECTION_FAILURE, seen in
// backboardd): check the mapping before the CPU fallback writes into it.
static BOOL mapping_writable(const void *p, size_t len) {
    // Walk the VM regions covering [p, p+len): every one must exist and be writable (a surface mapping may consist of several regions; the first
    // version required ONE region for the whole range and so skipped legitimate writes: the text/icons of the UI went missing).
    vm_address_t cur = (vm_address_t)p, end = cur + len;
    while (cur < end) {
        vm_address_t addr = cur;
        vm_size_t size = 0;
        vm_region_basic_info_data_64_t info;
        mach_msg_type_number_t cnt = VM_REGION_BASIC_INFO_COUNT_64;
        mach_port_t obj;
        if (vm_region_64(mach_task_self(), &addr, &size, VM_REGION_BASIC_INFO_64, (vm_region_info_t)&info, &cnt, &obj) != KERN_SUCCESS) return NO;
        if (addr > cur) return NO;
        if (!(info.protection & VM_PROT_WRITE)) {
            // read-only now, but the mapping may allow write (max protection): raise it. Client-memory surfaces of other processes (the Control
            // Center modules' render targets) arrive this way; skipping their sync left them black.
            static int logged; if (g_debug && logged++ < 8) fprintf(stderr, "EAGL(shim): read-only mapping %p+%zx prot %d max %d\n", (void *)cur, (size_t)size, info.protection, info.max_protection);
            if (!(info.max_protection & VM_PROT_WRITE) || vm_protect(mach_task_self(), addr > cur ? addr : cur, size - (cur - addr), FALSE, info.protection | VM_PROT_WRITE) != KERN_SUCCESS) return NO;
        }
        cur = addr + size;
    }
    return YES;
}

static void rgba_to_surface(const uint8_t *src, uint32_t w, uint32_t h, IOSurfaceRef s, BOOL flip, BOOL opaque) {
    kern_return_t lk = IOSurfaceLock(s, 0, NULL);
    uint8_t *dst = lk == KERN_SUCCESS ? IOSurfaceGetBaseAddress(s) : NULL;
    size_t bpr = IOSurfaceGetBytesPerRow(s);
    BOOL via_alias = NO;
    if (!dst || !mapping_writable(dst, bpr * IOSurfaceGetHeight(s))) {
        // read-only client memory (Control Center platters, live icons): the kernel gives a writable CPU alias of it (abi_minor 2)
        void *ab = NULL; unsigned abpr = 0, aw = 0, ah = 0;
        // opt-in (BGL_ALIAS=1): read-only surfaces here are mostly the clients' own backing stores (text, labels);
        // writing the render server's result into them doubled and smeared every label on the phone
        static int alias_on = -1;
        if (alias_on < 0) { const char *e = getenv("BGL_ALIAS"); alias_on = e && e[0] == '1'; }
        if (alias_on && osm_sweet_surface_alias(IOSurfaceGetID(s), &ab, &abpr, &aw, &ah)) { dst = ab; bpr = abpr; via_alias = YES; }
        else {
            if (lk == KERN_SUCCESS) IOSurfaceUnlock(s, 0, NULL);
            EAGL_DEBUG("CPU sync skipped: surface %u is not mapped writable here (no kernel alias)\n", IOSurfaceGetID(s));
            return;
        }
    }
    size_t sw = IOSurfaceGetWidth(s), sh = IOSurfaceGetHeight(s);
    uint32_t cw = w < sw ? w : (uint32_t)sw, ch = h < sh ? h : (uint32_t)sh;
    for (uint32_t y = 0; y < ch; y++) {
        const uint32_t *sp = (const uint32_t *)(src + (size_t)(flip ? (h - 1 - y) : y) * w * 4);
        uint32_t *dp = (uint32_t *)(dst + y * bpr);
        for (uint32_t x = 0; x < cw; x++) {
            uint32_t p = sp[x];                         // memory R G B A (little endian: 0xAABBGGRR)
            uint32_t r = p & 0xff, b = (p >> 16) & 0xff;
            dp[x] = (p & 0xff00ff00u) | (r << 16) | b | (opaque ? 0xff000000u : 0);
        }
    }
    if (via_alias) osm_sweet_alias_sync(IOSurfaceGetID(s));
    if (lk == KERN_SUCCESS) IOSurfaceUnlock(s, 0, NULL);
}

// glTexImage2D(NULL): CA assumes the texture memory is cleared (iOS guarantees that); Mesa hands out recycled
// GPU memory holding the pixels of earlier textures, which shows as garbage/noisy blocks where nothing was drawn
// over them (Control Center platters, widgets, damage regions while moving). Clear the just-defined texture
// through the public GL - scratch FBO + glClear, exactly the path CA itself uses every frame. The old
// pipe->clear_texture zero (OSMesaSweetZeroTexture) is NOT used: it stopped GPU submission on the phone.
__attribute__((visibility("default"))) void eagl_zero_current_tex2d(void) {
    GLint tex = 0, fbo = 0, sc = 0, sb[4] = {0, 0, 0, 0};
    float cc[4] = {0.0f, 0.0f, 0.0f, 0.0f};
    unsigned char cm[4] = {0, 0, 0, 0};
    glGetIntegerv(GL_TEXTURE_BINDING_2D, &tex);
    if (!tex) return;
    glGetIntegerv(GL_DRAW_FRAMEBUFFER_BINDING, &fbo);
    glGetIntegerv(GL_SCISSOR_TEST, &sc);
    glGetIntegerv(GL_SCISSOR_BOX, sb);
    glGetFloatv(GL_COLOR_CLEAR_VALUE, cc);
    glGetBooleanv(GL_COLOR_WRITEMASK, cm);
    GLuint z = 0;
    glGenFramebuffers(1, &z);
    glBindFramebuffer(GL_FRAMEBUFFER, z);
    glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, tex, 0);
    if (glCheckFramebufferStatus(GL_FRAMEBUFFER) == GL_FRAMEBUFFER_COMPLETE) {
        glDisable(GL_SCISSOR_TEST);
        glColorMask(GL_TRUE, GL_TRUE, GL_TRUE, GL_TRUE);
        glClearColor(0.0f, 0.0f, 0.0f, 0.0f);
        glClear(GL_COLOR_BUFFER_BIT);
    }
    glBindFramebuffer(GL_FRAMEBUFFER, fbo);
    glDeleteFramebuffers(1, &z);
    if (sc) { glEnable(GL_SCISSOR_TEST); glScissor(sb[0], sb[1], sb[2], sb[3]); }
    glColorMask(cm[0], cm[1], cm[2], cm[3]);
    glClearColor(cc[0], cc[1], cc[2], cc[3]);
}

// BGL_WRAPVERIFY / adaptive wrap decision: draw a just-wrapped texture through a minimal passthrough shader into a scratch
// 16x16 FBO, read it back, and compare with the CPU's view (IOSurfaceLock) of the same memory. Surfaces produced on the GPU
// (mesa-air clients: CC re-renders, platter border masks) are invisible to the CPU but sample fine; CPU-produced ones
// (format-less module icons: rich colours in memory) sample BLACK through a linear GPU import. The probe tells the two apart.
static int wrap_probe(GLuint tex, IOSurfaceRef surf, int kind, uint32_t w, uint32_t h, int *gr, int *ga, int *cr, int *ca) {
    static GLuint prog = 0, fbo = 0, scratch = 0, loc = 0, tried = 0, ok = 0;
    static const char *vsrc = "attribute vec2 p; varying vec2 uv; void main(){ uv = p*0.5+0.5; gl_Position = vec4(p, 0.0, 1.0); }";
    static const char *fsrc = "precision mediump float; varying vec2 uv; uniform sampler2D t; void main(){ gl_FragColor = texture2D(t, uv); }";
    *gr = *ga = *cr = *ca = 0;
    if (!tried) {
        tried = 1;
        GLuint vs = glCreateShader(0x8B31 /* GL_VERTEX_SHADER */), fs = glCreateShader(0x8B30 /* GL_FRAGMENT_SHADER */);
        GLint slen = (GLint)strlen(vsrc), flen = (GLint)strlen(fsrc);
        glShaderSource(vs, 1, &vsrc, &slen); glShaderSource(fs, 1, &fsrc, &flen);
        glCompileShader(vs); glCompileShader(fs);
        prog = glCreateProgram();
        glAttachShader(prog, vs); glAttachShader(prog, fs);
        glLinkProgram(prog);
        GLint linked = 0; glGetProgramiv(prog, 0x8B82 /* GL_LINK_STATUS */, &linked);
        if (!linked) { char log[512] = ""; glGetProgramInfoLog(prog, sizeof log - 1, NULL, log); EAGL_DEBUG("wrap-probe: probe program failed to link: %s\n", log); return 0; }
        glDeleteShader(vs); glDeleteShader(fs);
        loc = (GLuint)glGetUniformLocation(prog, "t");
        glGenTextures(1, &scratch);
        glBindTexture(GL_TEXTURE_2D, scratch);
        glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, 16, 16, 0, GL_RGBA, 0x1401, NULL);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR); glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE); glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
        glGenFramebuffers(1, &fbo);
        glBindFramebuffer(GL_FRAMEBUFFER, fbo);
        glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, scratch, 0);
        ok = glCheckFramebufferStatus(GL_FRAMEBUFFER) == 0x8CD5 /* GL_FRAMEBUFFER_COMPLETE */;
        if (!ok) EAGL_DEBUG("wrap-probe: scratch framebuffer incomplete\n");
        glBindFramebuffer(GL_FRAMEBUFFER, 0);
        glBindTexture(GL_TEXTURE_2D, 0);
    }
    if (!ok) return 0;
    GLint sProg = 0, sFbo = 0, sView[4] = {0}, sActive = 0, sTex = 0, sBlend = 0, sScissor = 0, sAttrEn = 0, sAttrSize = 0, sAttrStride = 0, sAttrType = 0, sAttrNorm = 0;
    void *sAttrPtr = NULL;
    glGetIntegerv(0x8B8D /* GL_CURRENT_PROGRAM */, &sProg);
    glGetIntegerv(GL_FRAMEBUFFER_BINDING, &sFbo);
    glGetIntegerv(GL_VIEWPORT, sView);
    glGetIntegerv(0x84E0 /* GL_ACTIVE_TEXTURE */, &sActive);
    glActiveTexture(GL_TEXTURE0);
    glGetIntegerv(GL_TEXTURE_BINDING_2D, &sTex);
    glGetIntegerv(GL_BLEND, &sBlend);
    glGetIntegerv(GL_SCISSOR_TEST, &sScissor);
    glGetVertexAttribiv(0, 0x8622 /* ARRAY_ENABLED */, &sAttrEn);
    glGetVertexAttribiv(0, 0x8623 /* ARRAY_SIZE */, &sAttrSize);
    glGetVertexAttribiv(0, 0x8624 /* ARRAY_STRIDE */, &sAttrStride);
    glGetVertexAttribiv(0, 0x8625 /* ARRAY_TYPE */, &sAttrType);
    glGetVertexAttribiv(0, 0x886A /* ARRAY_NORMALIZED */, &sAttrNorm);
    glGetVertexAttribPointerv(0, 0x8645 /* ARRAY_POINTER */, &sAttrPtr);
    glDisable(GL_BLEND); glDisable(GL_SCISSOR_TEST);
    glUseProgram(prog);
    glBindTexture(GL_TEXTURE_2D, tex);
    glUniform1i((GLint)loc, 0);
    glBindFramebuffer(GL_FRAMEBUFFER, fbo);
    glViewport(0, 0, 16, 16);
    GLfloat quad[8] = { -1, -1, 1, -1, -1, 1, 1, 1 };
    glEnableVertexAttribArray(0);
    glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, 0, quad);
    glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
    GLubyte px[16 * 16 * 4];
    glReadPixels(0, 0, 16, 16, GL_RGBA, 0x1401, px);
    int grgb = 0, gal = 0;
    for (int i = 0; i < 256; i++) { if (px[i*4] | px[i*4+1] | px[i*4+2]) grgb++; if (px[i*4+3]) gal++; }
    glBindTexture(GL_TEXTURE_2D, (GLuint)sTex);
    glActiveTexture((GLenum)sActive);
    glUseProgram((GLuint)sProg);
    glBindFramebuffer(GL_FRAMEBUFFER, (GLuint)sFbo);
    glViewport(sView[0], sView[1], sView[2], sView[3]);
    if (sBlend) glEnable(GL_BLEND);
    if (sScissor) glEnable(GL_SCISSOR_TEST);
    if (sAttrEn) glEnableVertexAttribArray(0); else glDisableVertexAttribArray(0);
    glVertexAttribPointer(0, (GLint)sAttrSize, (GLenum)sAttrType, (GLboolean)sAttrNorm, (GLsizei)sAttrStride, sAttrPtr);
    int crgb = 0, cal = 0;
    uint32_t cpuCentre = 0;                                     // bpp bytes of the centre pixel (padded with zero)
    const size_t bpp = kind == 1 || kind == 2 ? 1 : kind == 3 ? 2 : kind == 6 ? 8 : 4;
    if (bpp <= 4 && IOSurfaceLock(surf, kIOSurfaceLockReadOnly, NULL) == KERN_SUCCESS) {
        const uint8_t *base = (const uint8_t *)IOSurfaceGetBaseAddress(surf);
        size_t bpr = IOSurfaceGetBytesPerRow(surf);
        uint32_t x0 = w > 16 ? (w - 16) / 2 : 0, y0 = h > 16 ? (h - 16) / 2 : 0;
        for (uint32_t y = 0; y < 16 && y0 + y < h; y++)
            for (uint32_t x = 0; x < 16 && x0 + x < w; x++) {
                const uint8_t *q = base + (size_t)(y0 + y) * bpr + (size_t)(x0 + x) * bpp;
                uint32_t px4 = 0; memcpy(&px4, q, bpp);
                if (bpp < 4 ? px4 : (px4 & 0x00ffffffu)) crgb++;
                if (bpp == 4 ? (px4 >> 24) : px4) cal++;
            }
        memcpy(&cpuCentre, base + (size_t)(h / 2) * bpr + (size_t)(w / 2) * bpp, bpp);
        IOSurfaceUnlock(surf, kIOSurfaceLockReadOnly, NULL);
    }
    *gr = grgb; *ga = gal; *cr = crgb; *ca = cal;
    (void)cpuCentre;
    return 1;
}

// Logging wrapper (BGL_WRAPVERIFY=1) for regular wraps.
static void eagl_wrap_verify(GLuint tex, IOSurfaceRef surf, int kind, uint32_t fourcc, uint32_t w, uint32_t h) {
    int gr, ga, cr, ca;
    if (!wrap_probe(tex, surf, kind, w, h, &gr, &ga, &cr, &ca)) return;
    EAGL_DEBUG("wrap-verify: surface %u kind %d %ux%u fourcc %08x: GPU rgb %d/256 a %d/256, CPU rgb %d/256 a %d/256\n",
               IOSurfaceGetID(surf), kind, w, h, fourcc, gr, ga, cr, ca);
}

// Wrap-vs-copy decision by looking at the surface memory through both paths (GPU import sample vs CPU read).
// Format-less surfaces (fourcc 0, fmtless=1): wrap only when the GPU import samples real content - GPU-produced ones
// (borders, re-rendered modules) are only visible through the wrap, CPU-produced ones sample black and must be copied.
// Fourcc'd surfaces (fmtless=0): copy only when the GPU import is blind AND the CPU sees content - the CC backdrop
// snapshots (828x1792 BGRA) are CPU-written and feed every backdrop blur, so a blind wrap paints all glass black;
// when both paths see nothing the wrap is kept so surfaces the GPU fills later stay live. The scratch import also
// performs the kernel SBO cache clean, so the copy path that follows reads fresh memory either way.
static int wrap_decide(IOSurfaceRef surf, int kind, uint32_t w, uint32_t h, int fmtless) {
    uint32_t sid = IOSurfaceGetID(surf);
    GLint sActive = 0, sTex = 0;
    glGetIntegerv(0x84E0 /* GL_ACTIVE_TEXTURE */, &sActive);
    glActiveTexture(GL_TEXTURE0);
    glGetIntegerv(GL_TEXTURE_BINDING_2D, &sTex);
    GLuint scratch = 0;
    glGenTextures(1, &scratch);
    glBindTexture(GL_TEXTURE_2D, scratch);
    int wrap = 1, gr = 0, ga = 0, cr = 0, ca = 0;
    if (osm_sweet_wrap_texture(scratch, sid, kind, w, h) && wrap_probe(scratch, surf, kind, w, h, &gr, &ga, &cr, &ca)) {
        int gpu_content = (kind == 1 || kind == 2) ? ga >= 4 : gr >= 4;   // A8/L8 carry the image in alpha; the rest in rgb
        int cpu_content = (kind == 1 || kind == 2) ? ca >= 4 : cr >= 4;
        wrap = fmtless ? gpu_content : (gpu_content || !cpu_content);
        EAGL_DEBUG("texImageIOSurface: surface %u %s%ux%u kind %d: GPU %d/%d CPU %d/%d -> %s\n",
                   sid, fmtless ? "format-less " : "", w, h, kind, gr, ga, cr, ca, wrap ? "wrap" : "CPU copy");
    }
    osm_sweet_forget(sid);
    glDeleteTextures(1, &scratch);
    glBindTexture(GL_TEXTURE_2D, (GLuint)sTex);
    glActiveTexture((GLenum)sActive);
    return wrap;
}

// Re-upload of a decided-copy format-less surface: the SBO clean of a throwaway import makes the CPU read below fresh.
static void fmtless_clean(IOSurfaceRef surf, int kind, uint32_t w, uint32_t h) {
    if (!kind) return;
    uint32_t sid = IOSurfaceGetID(surf);
    GLint sActive = 0, sTex = 0;
    glGetIntegerv(0x84E0 /* GL_ACTIVE_TEXTURE */, &sActive);
    glActiveTexture(GL_TEXTURE0);
    glGetIntegerv(GL_TEXTURE_BINDING_2D, &sTex);
    GLuint scratch = 0;
    glGenTextures(1, &scratch);
    glBindTexture(GL_TEXTURE_2D, scratch);
    osm_sweet_wrap_texture(scratch, sid, kind, w, h);
    osm_sweet_forget(sid);
    glDeleteTextures(1, &scratch);
    glBindTexture(GL_TEXTURE_2D, (GLuint)sTex);
    glActiveTexture((GLenum)sActive);
}

// Read back the renderbuffer (or texture level 0) `name` of the current context into a malloc'ed RGBA buffer.
static uint8_t *read_image(EAGLContext *c, GLuint name, BOOL isTexture, uint32_t hintw, uint32_t hinth, uint32_t *ow, uint32_t *oh) {
    struct _EAGLContextPrivate *p = c->_private;
    GLint oldRead = 0, oldPackAlign = 4, oldRb = 0, oldTex = 0;
    glGetIntegerv(GL_FRAMEBUFFER_BINDING, &oldRead);    // GL_FRAMEBUFFER, not READ_FRAMEBUFFER: binding only the read side leaves the texture attached to the still-bound draw fbo = feedback loop, and reads come back zero
    glGetIntegerv(GL_PACK_ALIGNMENT, &oldPackAlign);
    if (!p->tmpfbo) glGenFramebuffers(1, &p->tmpfbo);
    glBindFramebuffer(GL_FRAMEBUFFER, p->tmpfbo);
    GLint w = 0, h = 0;
    if (isTexture) {
        glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, name, 0);
        w = (GLint)hintw; h = (GLint)hinth;     // ES has no level-size query; the IOSurface gives the size
        (void)oldTex;
    } else {
        glGetIntegerv(GL_RENDERBUFFER_BINDING, &oldRb);
        glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_RENDERBUFFER, name);
        glBindRenderbuffer(GL_RENDERBUFFER, name);
        glGetRenderbufferParameteriv(GL_RENDERBUFFER, GL_RENDERBUFFER_WIDTH, &w);
        glGetRenderbufferParameteriv(GL_RENDERBUFFER, GL_RENDERBUFFER_HEIGHT, &h);
        glBindRenderbuffer(GL_RENDERBUFFER, oldRb);
    }
    uint8_t *buf = NULL;
    if (w > 0 && h > 0 && glCheckFramebufferStatus(GL_FRAMEBUFFER) == GL_FRAMEBUFFER_COMPLETE) {
        buf = malloc((size_t)w * h * 4);
        if (buf) {
            glPixelStorei(GL_PACK_ALIGNMENT, 4);
            glReadBuffer(GL_COLOR_ATTACHMENT0);
            glReadPixels(0, 0, w, h, GL_RGBA, GL_UNSIGNED_BYTE, buf);
        }
    }
    if (isTexture) glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, 0, 0);
    else glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_RENDERBUFFER, 0);
    glBindFramebuffer(GL_FRAMEBUFFER, oldRead);
    glPixelStorei(GL_PACK_ALIGNMENT, oldPackAlign);
    *ow = (uint32_t)w; *oh = (uint32_t)h;
    return buf;
}

// Debug dump (EAGL_SHIM_DEBUG=1): frames 1, 10 and 60 of the attached-image sync, and any time /private/var/tmp/bgl-dump-now exists, are
// written as PPM files to /private/var/tmp/bgl-dump/: "-gl" = what the GL side holds (renderbuffer/texture read back), "-surf" = what the
// CPU sees in the IOSurface right after our sync. The first pixels and the surface geometry go to the log.
static void dump_ppm(const char *path, const uint8_t *rgba_or_bgra, uint32_t w, uint32_t h, size_t stride, int bgra, BOOL flip) {
    FILE *f = fopen(path, "wb");
    if (!f) return;
    fprintf(f, "P6\n%u %u\n255\n", w, h);
    for (uint32_t y = 0; y < h; y++) {
        const uint8_t *row = rgba_or_bgra + (size_t)(flip ? h - 1 - y : y) * stride;
        for (uint32_t x = 0; x < w; x++) {
            const uint8_t *q = row + x * 4;
            fputc(bgra ? q[2] : q[0], f); fputc(q[1], f); fputc(bgra ? q[0] : q[2], f);
        }
    }
    fclose(f);
}
static void maybe_dump(EAGLContext *c, int idx, BOOL isTex, uint32_t gw, uint32_t gh, BOOL gpu_path) {
    static int frame;
    struct _EAGLContextPrivate *p = c->_private;
    Attach *a = &p->att[idx];
    if (idx == 0) frame++;
    int now = access("/private/var/tmp/bgl-dump-now", F_OK) == 0;
    if (now && idx == 0) unlink("/private/var/tmp/bgl-dump-now");     // one-shot: a left-over trigger must not dump every frame (it did, after a reboot)
    if (!(frame == 1 || frame == 10 || frame == 60 || now)) return;
    mkdir("/private/var/tmp/bgl-dump", 0777);
    uint32_t w, h;
    uint8_t *buf = read_image(c, a->name, isTex, gw, gh, &w, &h);
    char path[256];
    if (buf) { snprintf(path, sizeof path, "/private/var/tmp/bgl-dump/f%d-a%d-gl.ppm", frame, idx); dump_ppm(path, buf, w, h, (size_t)w * 4, 0, YES); }
    kern_return_t dlk = IOSurfaceLock(a->surf, kIOSurfaceLockReadOnly, NULL);
    const uint8_t *sp = dlk == KERN_SUCCESS ? IOSurfaceGetBaseAddress(a->surf) : NULL;
    if (!sp) { fprintf(stderr, "EAGL(shim): dump frame %d: surface %u has no CPU mapping (lock %x)\n", frame, IOSurfaceGetID(a->surf), dlk); if (dlk == KERN_SUCCESS) IOSurfaceUnlock(a->surf, kIOSurfaceLockReadOnly, NULL); free(buf); return; }
    size_t bpr = IOSurfaceGetBytesPerRow(a->surf);
    uint32_t sw = (uint32_t)IOSurfaceGetWidth(a->surf), sh = (uint32_t)IOSurfaceGetHeight(a->surf);
    OSType pf = IOSurfaceGetPixelFormat(a->surf);
    fprintf(stderr, "EAGL(shim): dump frame %d attach %d name %u %s: surface %u %ux%u fmt %08x stride %zu inverted %d gpu_blit %d, GL image %ux%u; first pixels (bytes) %02x%02x%02x%02x %02x%02x%02x%02x, centre %02x%02x%02x%02x\n",
            frame, idx, a->name, isTex ? "texture" : "renderbuffer", IOSurfaceGetID(a->surf), sw, sh, (unsigned)pf, bpr, a->inverted, gpu_path, w, h,
            sp[0], sp[1], sp[2], sp[3], sp[4], sp[5], sp[6], sp[7],
            sp[(sh / 2) * bpr + (sw / 2) * 4], sp[(sh / 2) * bpr + (sw / 2) * 4 + 1], sp[(sh / 2) * bpr + (sw / 2) * 4 + 2], sp[(sh / 2) * bpr + (sw / 2) * 4 + 3]);
    if (pf == 'BGRA') { snprintf(path, sizeof path, "/private/var/tmp/bgl-dump/f%d-a%d-surf.ppm", frame, idx); dump_ppm(path, sp, sw, sh, bpr, 1, NO); }
    IOSurfaceUnlock(a->surf, kIOSurfaceLockReadOnly, NULL);
    free(buf);
}

// Per-frame statistics for display-size surfaces (EAGL_SHIM_DEBUG): time since the previous sync, duration of the blit, and a sampled average
// luminance / fraction of black samples of what the CPU sees in the surface afterwards. A flashing display shows up as black or stale frames.
static double now_ms(void) { struct timeval tv; gettimeofday(&tv, NULL); return tv.tv_sec * 1e3 + tv.tv_usec / 1e3; }
static void frame_stats(Attach *a, double t_start, double t_end, int gpu) {
    static double last_t, t0; static int n;
    size_t w = IOSurfaceGetWidth(a->surf), h = IOSurfaceGetHeight(a->surf);
    if (w < 1000 || h < 2000 || n > 3000 || !g_debug_frames) return;
    if (!t0) t0 = t_start;
    double lum = -1, black = -1;
    kern_return_t lk = IOSurfaceLock(a->surf, kIOSurfaceLockReadOnly, NULL);
    const uint8_t *sp = lk == KERN_SUCCESS ? IOSurfaceGetBaseAddress(a->surf) : NULL;
    if (sp && IOSurfaceGetPixelFormat(a->surf) == 'BGRA') {
        size_t bpr = IOSurfaceGetBytesPerRow(a->surf), cnt = 0, blk = 0; double sum = 0;
        for (size_t y = 3; y < h; y += 61) for (size_t x = 5; x < w; x += 53) { const uint8_t *q = sp + y * bpr + x * 4; sum += (q[0] + q[1] + q[2]) / 3.0; if (q[0] + q[1] + q[2] < 6) blk++; cnt++; }
        lum = sum / cnt; black = (double)blk / cnt;
    }
    if (lk == KERN_SUCCESS) IOSurfaceUnlock(a->surf, kIOSurfaceLockReadOnly, NULL);
    // thumbnails (1/16 scale) of the first 80 syncs: /private/var/tmp/bgl-thumbs.bin = repeated { u32 index, u32 surface, u32 w, u32 h, w*h*3 RGB } (contact sheet on the Mac)
    {
        static uint8_t *tb; static size_t tlen; enum { TW = 71, TH = 153, MAXF = 80 };
        if (n < MAXF && sp == NULL) { /* surface unreadable: nothing */ }
        if (n < MAXF) {
            if (!tb) tb = malloc((size_t)MAXF * (16 + TW * TH * 3));
            kern_return_t lk2 = IOSurfaceLock(a->surf, kIOSurfaceLockReadOnly, NULL);
            const uint8_t *sp2 = lk2 == KERN_SUCCESS ? IOSurfaceGetBaseAddress(a->surf) : NULL;
            if (tb && sp2 && IOSurfaceGetPixelFormat(a->surf) == 'BGRA') {
                size_t bpr = IOSurfaceGetBytesPerRow(a->surf);
                uint32_t *hd = (uint32_t *)(tb + tlen); hd[0] = n + 1; hd[1] = IOSurfaceGetID(a->surf); hd[2] = TW; hd[3] = TH;
                uint8_t *o = tb + tlen + 16;
                for (int y = 0; y < TH; y++) for (int x = 0; x < TW; x++) { const uint8_t *q = sp2 + (size_t)(y * 16) * bpr + (size_t)(x * 16) * 4; *o++ = q[2]; *o++ = q[1]; *o++ = q[0]; }
                tlen += 16 + TW * TH * 3;
                if (n + 1 == MAXF) { FILE *f = fopen("/private/var/tmp/bgl-thumbs.bin", "wb"); if (f) { fwrite(tb, 1, tlen, f); fclose(f); } fprintf(stderr, "EAGL(shim): thumbnails written (%zu bytes)\n", tlen); }
            }
            if (lk2 == KERN_SUCCESS) IOSurfaceUnlock(a->surf, kIOSurfaceLockReadOnly, NULL);
        }
    }
    fprintf(stderr, "EAGL(shim): FS #%d t=%.0f dt=%.1f blit=%.1fms surf=%u gpu=%d lum=%.1f black=%.2f\n", ++n, t_end - t0, last_t ? t_start - last_t : 0.0, t_end - t_start, IOSurfaceGetID(a->surf), gpu, lum, black);
    last_t = t_start;
}

// Pipeline statistics (EAGL_SHIM_DEBUG): per interval of 60 display-size syncs, where the time goes. glflush = time inside Mesa's glFlush (batch
// submit), blit = enqueue / render-wait (GPU time of the client's drawing, forced by a finish) / copy-wait (GPU time of the blit) / BO_SYNC,
// cpu = surfaces copied through the CPU (read_image + rgba_to_surface). In this mode the extra finish makes frames slower than they are normally.
static unsigned g_mark_hit, g_mark_miss, g_draw_seen;
static double g_ps_direct_ms; static int g_ps_direct_n;
static double g_ps_flush_ms, g_ps_cpu_ms; static int g_ps_cpu_n, g_ps_syncs, g_ps_skipped;
static void pipe_stats_report(void) {
    static double last[8], last_flush, last_cpu, last_t; static int last_cpu_n, last_syncs;
    double st[8]; osm_sweet_stats(st, 8);
    double now = now_ms(), dn = g_ps_syncs - last_syncs; if (dn < 1) return;
    fprintf(stderr, "EAGL(shim): PIPE %d syncs in %.0f ms (%.1f ms/sync): glFlush %.2f | gpu blits %.0f refused %.0f | render-wait %.2f enqueue %.2f copy-wait %.2f bo_sync %.2f lookup %.2f | cpu copies %d %.2f ms (per sync) | direct display syncs %d %.2f ms each | display copies skipped (clean) %d | draws marking an attachment %u, other draws %u\n",
            (int)dn, now - last_t, (now - last_t) / dn, (g_ps_flush_ms - last_flush) / dn, st[0] - last[0], st[6] - last[6],
            (st[1] - last[1]) / dn, (st[2] - last[2]) / dn, (st[3] - last[3]) / dn, (st[4] - last[4]) / dn, (st[5] - last[5]) / dn,
            g_ps_cpu_n - last_cpu_n, (g_ps_cpu_ms - last_cpu) / dn, g_ps_direct_n, g_ps_direct_n ? g_ps_direct_ms / g_ps_direct_n : 0.0, g_ps_skipped, g_mark_hit, g_mark_miss);
    memcpy(last, st, sizeof st); last_flush = g_ps_flush_ms; last_cpu = g_ps_cpu_ms; last_t = now; last_cpu_n = g_ps_cpu_n; last_syncs = g_ps_syncs;
}

// Flush every attachImage: association of this context into its IOSurface.
// frames mode: compare what the GPU rendered (glReadPixels of the texture = the surface memory seen by the GPU) with what the CPU reads from the surface
// right after the sync. Mismatches mean stale cache lines / missing sync on this side; none means the surface is coherent for the CPU and any artefact
// on screen comes from later (the kernel's copy to the panel, or a surface that is being rendered into while it is copied).
static void verify_direct(EAGLContext *c, Attach *a) {
    static int n; if (n++ >= 300) return;
    { static unsigned ne; if (ne++ < 6) EAGL_DEBUG("verify enter n=%d surface %u\n", n - 1, IOSurfaceGetID(a->surf)); }
    uint32_t w = 0, h = 0, sw = (uint32_t)IOSurfaceGetWidth(a->surf), sh = (uint32_t)IOSurfaceGetHeight(a->surf);
    uint8_t *buf = read_image(c, a->name, YES, sw, sh, &w, &h);
    if (!buf) { EAGL_DEBUG("VERIFY surface %u: read_image failed (tex %u %ux%u)\n", IOSurfaceGetID(a->surf), a->name, sw, sh); return; }
    { static unsigned nr; if (nr++ < 6) EAGL_DEBUG("verify readback ok %ux%u surface %u\n", w, h, IOSurfaceGetID(a->surf)); }
    if (IOSurfaceLock(a->surf, kIOSurfaceLockReadOnly, NULL) != KERN_SUCCESS) { EAGL_DEBUG("VERIFY surface %u: surface lock failed\n", IOSurfaceGetID(a->surf)); free(buf); return; }
    const uint8_t *sp = IOSurfaceGetBaseAddress(a->surf); size_t bpr = IOSurfaceGetBytesPerRow(a->surf);
    size_t bad = 0, badrows = 0, first_x = 0, first_y = 0; BOOL found = NO;
    for (uint32_t y = 0; y < h && y < sh; y++) {
        size_t rowbad = 0;
        for (uint32_t x = 0; x < w && x < sw; x++) {
            const uint8_t *g = buf + ((size_t)y * w + x) * 4, *q = sp + y * bpr + (size_t)x * 4;     // g = RGBA, q = BGRA, same row order (no flip for target-form attaches)
            if (g[0] != q[2] || g[1] != q[1] || g[2] != q[0] || g[3] != q[3]) { rowbad++; if (!found) { found = YES; first_x = x; first_y = y; } }
        }
        bad += rowbad; if (rowbad) badrows++;
    }
    fprintf(stderr, "EAGL(shim): VERIFY surface %u: %zu mismatching pixels in %zu rows of %ux%u%s", IOSurfaceGetID(a->surf), bad, badrows, w, h, bad ? "" : "\n");
    if (bad) fprintf(stderr, ", first at (%zu,%zu): gpu %02x%02x%02x%02x cpu(bgra) %02x%02x%02x%02x\n", first_x, first_y,
                     buf[(first_y * w + first_x) * 4], buf[(first_y * w + first_x) * 4 + 1], buf[(first_y * w + first_x) * 4 + 2], buf[(first_y * w + first_x) * 4 + 3],
                     sp[first_y * bpr + first_x * 4], sp[first_y * bpr + first_x * 4 + 1], sp[first_y * bpr + first_x * 4 + 2], sp[first_y * bpr + first_x * 4 + 3]);
    IOSurfaceUnlock(a->surf, kIOSurfaceLockReadOnly, NULL); free(buf);
}

static void (*mesa_glFlush)(void), (*mesa_glFinish)(void);   // tentative: defined with the flush wrappers below; sync_att needs the finish first

static void glyph_survival_check(void);   // defined with the flip probes: did the glyph draw's pixels survive to the flush?
static void sync_att(EAGLContext *c, int i) {
    struct _EAGLContextPrivate *p = c->_private;
    Attach *a = &p->att[i];
        a->dirty = 0;
        if (a->direct) {
            double td = g_debug ? now_ms() : 0; osm_sweet_direct_sync(IOSurfaceGetID(a->surf)); if (g_debug) { g_ps_direct_ms += now_ms() - td; g_ps_direct_n++; }
            { static unsigned nd; if (g_debug && nd++ < 4000) EAGL_DEBUG("direct_sync surface %u (dirty flush)\n", IOSurfaceGetID(a->surf)); }
            if (g_debug_frames) verify_direct(c, a);
            glyph_survival_check();
            return;
        }
        mesa_glFinish();   // glFlush only SUBMITTED the batch (the clock's digits read back as all-zero for exactly this reason: the GPU was still rendering when the sync copied the texture)
        BOOL isTex = a->kind ? (a->kind == 1) : (glIsTexture(a->name) && !glIsRenderbuffer(a->name));
        // Hardware path: the GPU copies the image into the surface (no readback); GL rows are bottom-up, `inverted` means the surface wants them as they are.
        double t_start = g_debug ? now_ms() : 0;
        BOOL flip = a->kind ? a->inverted : !a->inverted;      // target-form attach (the render server): YES = rows flipped, NO = as GL has them (seen on the phone: NO + flip drew the UI upside down)
        if (osm_sweet_active() && (uint64_t)IOSurfaceGetWidth(a->surf) * IOSurfaceGetHeight(a->surf) >= 1000000 && osm_sweet_blit(a->name, isTex, IOSurfaceGetID(a->surf), flip, NO)) {   // GPU blit only for display-size: its writes into pitch-aligned smaller surfaces (772x164 clock, bpr 3328) silently left the surface empty while returning success; the CPU readback below is the proven path for small surfaces
            if (g_debug) { frame_stats(a, t_start, now_ms(), 1); maybe_dump(c, i, isTex, (uint32_t)IOSurfaceGetWidth(a->surf), (uint32_t)IOSurfaceGetHeight(a->surf), YES); }
            return;
        }
        uint32_t w, h;
        double t_cpu0 = g_debug ? now_ms() : 0;
        uint8_t *buf = NULL;
        {   // fast path: the attachment's framebuffer is typically still bound when CA flushes (trace-verified). Reading the bound fb returns the
            // rendered pixels, while re-attaching the texture to the scratch fb reads all-zero on fd6 (only the original fb binding reaches the
            // rendered storage; seen on the 772x164 clock: probe-read = 308/2048 bytes, scratch-read = 0).
            GLint cb = 0, att_type = 0, att_name = 0;
            glGetIntegerv(GL_FRAMEBUFFER_BINDING, &cb);
            if (cb) {
                glGetFramebufferAttachmentParameteriv(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_FRAMEBUFFER_ATTACHMENT_OBJECT_TYPE, &att_type);
                glGetFramebufferAttachmentParameteriv(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_FRAMEBUFFER_ATTACHMENT_OBJECT_NAME, &att_name);
                if (a->kind != 2 && att_type == GL_TEXTURE && att_name && (GLuint)att_name == a->name) {
                    w = (uint32_t)IOSurfaceGetWidth(a->surf); h = (uint32_t)IOSurfaceGetHeight(a->surf);
                    buf = malloc((size_t)w * h * 4);
                    if (buf) {
                        GLint oldPa = 4; glGetIntegerv(GL_PACK_ALIGNMENT, &oldPa);
                        glPixelStorei(GL_PACK_ALIGNMENT, 4);
                        glReadBuffer(GL_COLOR_ATTACHMENT0);
                        glReadPixels(0, 0, (GLint)w, (GLint)h, GL_RGBA, GL_UNSIGNED_BYTE, buf);
                        glPixelStorei(GL_PACK_ALIGNMENT, oldPa);
                    }
                }
            }
        }
        if (!buf) buf = read_image(c, a->name, isTex, (uint32_t)IOSurfaceGetWidth(a->surf), (uint32_t)IOSurfaceGetHeight(a->surf), &w, &h);
        if (buf) {
            if (g_debug) { static unsigned nq; if (nq++ < 60) { size_t tot = (size_t)w * h * 4, nz = 0; size_t y0 = 0, y1 = 0; for (size_t y = 0; y < h; y++) { size_t rn = 0; for (size_t x = 0; x < w * 4; x++) if (buf[y * w * 4 + x]) rn++; if (rn) { nz += rn; if (!y0) y0 = y; y1 = y; } } EAGL_DEBUG("cpu-sync surface %u: GL image %ux%u, %zu of %zu bytes non-zero, rows %zu-%zu\n", IOSurfaceGetID(a->surf), w, h, nz, tot, y0, y1); } }
            // GL rows are bottom-up; a "normal" surface is top-down. invertedRender means CA already drew it flipped.
            rgba_to_surface(buf, w, h, a->surf, flip, NO);
            free(buf);
        }
        if (g_debug) { g_ps_cpu_ms += now_ms() - t_cpu0; g_ps_cpu_n++; }
        if (g_debug) { frame_stats(a, t_start, now_ms(), 0); maybe_dump(c, i, isTex, (uint32_t)IOSurfaceGetWidth(a->surf), (uint32_t)IOSurfaceGetHeight(a->surf), NO); }
}

static void sync_attached(EAGLContext *c) {
    struct _EAGLContextPrivate *p = c->_private;
    // Safety net: GL work happened but nothing was attributed to an attachment (a render path the tracking does not see): copy everything this flush.
    BOOL force_all = NO;
    if (g_dirty_track) {
        BOOL any = NO; for (int i = 0; i < p->natt; i++) if (p->att[i].dirty) any = YES;
        force_all = !any && g_draw_seen > 0 && p->cur_att < 0;
        g_draw_seen = 0;
    }
    for (int i = 0; i < p->natt; i++) {
        Attach *a = &p->att[i];
        if (g_dirty_track && !force_all && !a->dirty && IOSurfaceGetWidth(a->surf) * IOSurfaceGetHeight(a->surf) >= 1000000) { g_ps_skipped++; continue; }   // display buffer nobody drew into
        sync_att(c, i);
    }
}

// glFlush / glFinish wrappers installed over the Mesa entry points (see eagl_install_hooks).
static void (*mesa_glFlush)(void), (*mesa_glFinish)(void);
static void pipe_count_sync(EAGLContext *c) {
    if (!g_debug || !c->_private->natt) return;
    size_t w = 0, h = 0; for (int i = 0; i < c->_private->natt; i++) { size_t aw = IOSurfaceGetWidth(c->_private->att[i].surf); if (aw > w) { w = aw; h = IOSurfaceGetHeight(c->_private->att[i].surf); } }
    if (w >= 1000 && h >= 2000 && ++g_ps_syncs % 60 == 0) pipe_stats_report();
}
static void shim_glFlush(void) {
    // Wrapped client-memory surfaces: the seed check at bind time misses producer writes while a texture stays
    // bound (CA's render server binds once and draws many frames) - the GPU then samples stale cache lines
    // (the pixel-mess of the first wrapsample boot). Clean every wrapped surface's producer writes here,
    // before the batch reaches the GPU, so it never samples old bytes.
    pthread_mutex_lock(&g_live_lock);
    for (int i = 0; i < g_nlive; i++) if (g_live[i].wrapped && g_live[i].surf) osm_sweet_wrap_sync(IOSurfaceGetID(g_live[i].surf));
    pthread_mutex_unlock(&g_live_lock);
    double t = g_debug ? now_ms() : 0; mesa_glFlush(); if (g_debug) g_ps_flush_ms += now_ms() - t; EAGLContext *c = cur_ctx(); if (c && c->_private->natt) { sync_attached(c); pipe_count_sync(c); } }
static void shim_glFinish(void) { double t = g_debug ? now_ms() : 0; mesa_glFinish(); if (g_debug) g_ps_flush_ms += now_ms() - t; EAGLContext *c = cur_ctx(); if (c && c->_private->natt) { sync_attached(c); pipe_count_sync(c); } }

// Dirty tracking of the display-size attachments: the render server draws into one texture per frame (through an FBO) and flushes; copying both of its
// double-buffered display textures at every flush doubled the cost of a frame. Draw/clear entry points mark the attachment the bound FBO renders into,
// FBO binding changes recompute which attachment that is, and sync_attached copies display-size attachments only when marked.
static BOOL att_is_tex(Attach *a) { return a->kind ? a->kind == 1 : (glIsTexture(a->name) && !glIsRenderbuffer(a->name)); }
static void tex_mark_defined(void *ctx, GLuint name);
static void update_cur_target(EAGLContext *c) {
    struct _EAGLContextPrivate *p = c->_private;
    p->cur_att = -1;
    if (!p->natt) return;
    GLint fb = 0, type = 0, name = 0;
    glGetIntegerv(GL_FRAMEBUFFER_BINDING, &fb);
    if (!fb) { if (g_debug) { static int n; if (n++ < 20) fprintf(stderr, "EAGL(shim): FBO tracking: no framebuffer bound (%d attachments)\n", p->natt); } return; }
    glGetFramebufferAttachmentParameteriv(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_FRAMEBUFFER_ATTACHMENT_OBJECT_TYPE, &type);
    glGetFramebufferAttachmentParameteriv(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_FRAMEBUFFER_ATTACHMENT_OBJECT_NAME, &name);
    if (type != GL_TEXTURE && type != GL_RENDERBUFFER) return;
    if (type == GL_TEXTURE) tex_mark_defined(c, (GLuint)name);      // render targets (bound without any upload): defined by being attached
    for (int i = 0; i < p->natt; i++) if ((GLint)p->att[i].name == name && att_is_tex(&p->att[i]) == (type == GL_TEXTURE)) { p->cur_att = i; break; }
    if (g_debug) { static int n; if (n++ < 60) fprintf(stderr, "EAGL(shim): [ctx %p] FBO %d colour0 type 0x%x name %d -> attachment %d (of %d)\n", c, fb, type, name, p->cur_att, p->natt); }
}
static inline void mark_cur_dirty(void) { EAGLContext *c = cur_ctx(); if (c && c->_private->cur_att >= 0 && c->_private->cur_att < c->_private->natt) { c->_private->att[c->_private->cur_att].dirty = 1; g_mark_hit++; } else g_mark_miss++; g_draw_seen++; }
static void (*o_DrawArrays)(GLenum, GLint, GLsizei);
// Context-less GL calls: CoreAnimation's glyph workers issue GL on threads with no current context; Mesa drops them
// ("function is no-op"). The hooks below are the only place the shim still sees them - log which entry points get
// dropped (bounded) so we can tell a dropped bind (harmless, the helper replays it) from a dropped DRAW (element
// stays invisible no matter what the upload does).
static void ctxless_warn(const char *what) {
    static unsigned n;
    if (!cur_ctx() && n < 400) { n++; EAGL_DEBUG("GL %s on a CONTEXT-LESS thread: dropped by Mesa\n", what); }
}
static void (*o_DrawElements)(GLenum, GLsizei, GLenum, const void *);
static void draw_probe(const char *what, GLsizei count) {
    static int n; if (n >= 12) return;
    GLint vp[4]; glGetIntegerv(GL_VIEWPORT, vp);
    if (vp[2] != 772 || vp[3] != 164) return;
    n++;
    glFinish();
    uint8_t pb[2048] = {0};
    glReadPixels(vp[2] / 2 - 64, vp[3] / 2 - 2, 128, 4, GL_RGBA, GL_UNSIGNED_BYTE, pb);
    size_t nz = 0; for (size_t q = 0; q < sizeof pb; q++) if (pb[q]) nz++;
    GLint fb = 0; glGetIntegerv(GL_FRAMEBUFFER_BINDING, &fb);
    EAGL_DEBUG("draw-probe (%s, count %d): fbo %d, %zu of %zu bytes non-zero in centre 128x4 strip\n", what, count, fb, nz, sizeof pb);
}
// Composite-side probe: the server draws a CPU-copied live texture (the clock, CC icons) into the display flip ONCE and the
// element stays invisible. Capture the whole flip before/after such draws: a real draw changes thousands of bytes, a no-op
// draw changes none - that separates "the upload samples empty" from "the draw output was discarded/overwritten".
static int flip_pre_on; static uint8_t *flip_pre_buf; static size_t flip_pre_nz; static GLuint flip_pre_tex; static uint32_t flip_pre_w, flip_pre_h;
static int flip_gate(GLuint *otex, uint32_t *ow, uint32_t *oh) {
    static int n; if (n >= 40) return 0;
    GLint vp[4]; glGetIntegerv(GL_VIEWPORT, vp);
    if (vp[2] != 828 || vp[3] != 1792) return 0;
    EAGLContext *c = cur_ctx(); if (!c) return 0;
    GLint sAct = 0; glGetIntegerv(0x84E0 /* GL_ACTIVE_TEXTURE */, &sAct);
    glActiveTexture(GL_TEXTURE0);
    GLint tex = 0; glGetIntegerv(GL_TEXTURE_BINDING_2D, &tex);
    glActiveTexture((GLenum)sAct);
    if (!tex) return 0;
    {   // fire once per distinct texture: repetitive per-frame draws (30+ per texture) would burn any global cap before
        // the interesting textures (glyph lines like the 79x53 date line - same size class as the 64x64 boot splashes,
        // which is why a size window cannot separate them) ever get their single shot
        static GLuint seen[64]; static int nseen;
        for (int i = 0; i < nseen; i++) if (seen[i] == (GLuint)tex) return 0;
        if (nseen < 64) seen[nseen++] = (GLuint)tex;
    }
    int hit = 0; uint32_t w = 0, h = 0;
    pthread_mutex_lock(&g_live_lock);
    for (int i = 0; i < g_nlive; i++) if (g_live[i].ctx == c && g_live[i].name == (GLuint)tex && !g_live[i].wrapped) {
        w = g_live[i].w; h = g_live[i].h;
        uint32_t px = (uint32_t)w * h;
        hit = px >= 100;   // any live CPU-copied texture (glyphs, lines, layers) - dedupe above handles repetition
        break;
    }
    pthread_mutex_unlock(&g_live_lock);
    if (!hit) return 0;
    n++;
    *otex = (GLuint)tex; *ow = w; *oh = h;
    return 1;
}
static size_t flip_read(uint8_t *dst) {
    glFinish();
    glPixelStorei(GL_PACK_ALIGNMENT, 4);
    glReadPixels(0, 0, 828, 1792, GL_RGBA, GL_UNSIGNED_BYTE, dst);
    size_t nz = 0; for (size_t q = 0; q < (size_t)828 * 1792 * 4; q++) if (dst[q]) nz++;
    return nz;
}
static void flip_delta_begin(void) {
    flip_pre_on = 0;
    if (!g_debug) return;
    GLuint tex; uint32_t w, h;
    if (!flip_gate(&tex, &w, &h)) return;
    if (!flip_pre_buf) flip_pre_buf = malloc((size_t)828 * 1792 * 4);
    if (!flip_pre_buf) return;
    flip_pre_nz = flip_read(flip_pre_buf); flip_pre_on = 1; flip_pre_tex = tex; flip_pre_w = w; flip_pre_h = h;
}
// Glyph-survival probe: a glyph draw paints real RGB into a display flip (flip-draw), yet nothing shows on screen.
// Later same-frame draws (backdrop snapshots, full-screen fills) may bury it before the flush - or it reaches the
// surface intact and the loss is below GL. Record the glyph draw's changed pixels and re-read them at that flip's
// flush (sync time) to see which fate it met.
static int g_gw_on; static GLint g_gw_fbo; static size_t g_gw_n; static size_t *g_gw_idx; static uint8_t *g_gw_pre; static uint8_t *g_gw_now;
static void flip_delta_end(const char *what, GLsizei count) {
    if (!flip_pre_on) return; flip_pre_on = 0;
    static uint8_t *post; if (!post) post = malloc((size_t)828 * 1792 * 4);
    if (!post) return;
    size_t nz = flip_read(post);
    size_t chg = 0, chgA = 0; for (size_t q = 0; q < (size_t)828 * 1792 * 4; q += 4) {
        if (post[q] != flip_pre_buf[q] || post[q+1] != flip_pre_buf[q+1] || post[q+2] != flip_pre_buf[q+2]) chg++;
        else if (post[q+3] != flip_pre_buf[q+3]) chgA++;
    }
    GLint fb = 0; glGetIntegerv(GL_FRAMEBUFFER_BINDING, &fb);
    EAGL_DEBUG("flip-draw (%s, count %d): tex %u (%ux%u) into fbo %d: non-zero before %zu after %zu, %zu px RGB-changed, %zu px alpha-only\n",
               what, count, flip_pre_tex, flip_pre_w, flip_pre_h, fb, flip_pre_nz, nz, chg, chgA);
    if (chg && chg < 5000 && !g_gw_on) {     // a small real-color draw (glyph/text): watch its pixels until the flush
        if (!g_gw_idx) { g_gw_idx = malloc(sizeof(size_t) * 8192); g_gw_pre = malloc((size_t)828 * 1792 * 4); g_gw_now = malloc((size_t)828 * 1792 * 4); }
        if (g_gw_idx && g_gw_pre && g_gw_now) {
            g_gw_n = 0;
            for (size_t q = 0; q < (size_t)828 * 1792 * 4 && g_gw_n < 8192; q += 4)
                if (post[q] != flip_pre_buf[q] || post[q+1] != flip_pre_buf[q+1] || post[q+2] != flip_pre_buf[q+2]) g_gw_idx[g_gw_n++] = q;
            if (g_gw_n) { memcpy(g_gw_pre, flip_pre_buf, (size_t)828 * 1792 * 4); g_gw_fbo = fb; g_gw_on = 1; }
        }
    }
}
static void glyph_survival_check(void) {
    if (!g_gw_on) return;
    GLint fb = 0; glGetIntegerv(GL_FRAMEBUFFER_BINDING, &fb);
    if (fb != g_gw_fbo) return;                     // only check at the watched flip's own sync
    g_gw_on = 0;
    glFinish();
    glPixelStorei(GL_PACK_ALIGNMENT, 4);
    glReadPixels(0, 0, 828, 1792, GL_RGBA, GL_UNSIGNED_BYTE, g_gw_now);
    size_t alive = 0; for (size_t i = 0; i < g_gw_n; i++) {
        size_t q = g_gw_idx[i];
        if (g_gw_now[q] != g_gw_pre[q] || g_gw_now[q+1] != g_gw_pre[q+1] || g_gw_now[q+2] != g_gw_pre[q+2]) alive++;
    }
    EAGL_DEBUG("glyph-survival: %zu of %zu changed px still present at flush of fbo %d\n", alive, g_gw_n, fb);
}
// Feedback-loop renders: CA's GLES renderer repeatedly draws a texture INTO the framebuffer that same texture is
// attached to (progressive accumulation: the clock/date caches, CC glass passes, e.g. units (140,139) into fbo 42 = tex
// 139). Apple's driver executes these sampling the pre-draw content; Mesa's spec validation raises INVALID_OPERATION
// and SILENTLY DROPS the draw - the caches never accumulate and every element built this way stays empty (missing
// lock-screen time/date, CC icons). Fix: snapshot the attachment into a scratch texture and point the sampling units
// at the snapshot for the duration of the draw - exactly Apple's semantics, no feedback.
static GLuint fbfix_scratch; static GLint fbfix_units[4], fbfix_names[4]; static int fbfix_n;
static void feedback_fix_begin(void) {
    fbfix_n = 0;
    GLint fb = 0; glGetIntegerv(GL_FRAMEBUFFER_BINDING, &fb);
    if (!fb) return;
    GLint attType = 0, attName = 0;
    glGetFramebufferAttachmentParameteriv(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_FRAMEBUFFER_ATTACHMENT_OBJECT_TYPE, &attType);
    if (attType != GL_TEXTURE) return;
    glGetFramebufferAttachmentParameteriv(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_FRAMEBUFFER_ATTACHMENT_OBJECT_NAME, &attName);
    if (!attName) return;
    GLint sAct = 0; glGetIntegerv(0x84E0 /* GL_ACTIVE_TEXTURE */, &sAct);
    for (int u = 0; u < 4; u++) {
        glActiveTexture((GLenum)(GL_TEXTURE0 + u));
        GLint t = 0; glGetIntegerv(GL_TEXTURE_BINDING_2D, &t);
        if (t != attName) continue;
        GLint vp[4]; glGetIntegerv(GL_VIEWPORT, vp);       // the target's size: CA's viewport matches its render target
        if (vp[2] <= 0 || vp[3] <= 0) continue;
        if (!fbfix_scratch) { glGenTextures(1, &fbfix_scratch); }
        glBindTexture(GL_TEXTURE_2D, fbfix_scratch);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
        glCopyTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, 0, 0, vp[2], vp[3], 0);   // snapshot the pre-draw content
        fbfix_units[fbfix_n] = u; fbfix_names[fbfix_n] = t; fbfix_n++;
        { static unsigned nf; if (g_debug && nf++ < 20) EAGL_DEBUG("feedback-fix: draw would sample texture %u attached to the target fb - snapshot to scratch for units incl. unit %d (%dx%d)\n", attName, u, vp[2], vp[3]); }
    }
    glActiveTexture((GLenum)sAct);
}
static void feedback_fix_end(void) {
    if (!fbfix_n) return;
    GLint sAct = 0; glGetIntegerv(0x84E0 /* GL_ACTIVE_TEXTURE */, &sAct);
    for (int i = 0; i < fbfix_n; i++) {
        glActiveTexture((GLenum)(GL_TEXTURE0 + fbfix_units[i]));
        glBindTexture(GL_TEXTURE_2D, (GLuint)fbfix_names[i]);
    }
    glActiveTexture((GLenum)sAct);
    fbfix_n = 0;
}
static void h_DrawArrays(GLenum a, GLint b, GLsizei c) { ctxless_warn("glDrawArrays"); mark_cur_dirty(); flip_delta_begin(); feedback_fix_begin(); o_DrawArrays(a, b, c); feedback_fix_end(); if (g_debug) draw_probe("arrays", c); flip_delta_end("arrays", c); }
static void h_DrawElements(GLenum a, GLsizei b, GLenum c, const void *d) { ctxless_warn("glDrawElements"); mark_cur_dirty(); flip_delta_begin(); feedback_fix_begin(); o_DrawElements(a, b, c, d); feedback_fix_end(); if (g_debug) draw_probe("elements", b); flip_delta_end("elements", b); }
static void (*o_DrawArraysInstanced)(GLenum, GLint, GLsizei, GLsizei);
static void h_DrawArraysInstanced(GLenum a, GLint b, GLsizei c, GLsizei d) { ctxless_warn("glDrawArraysInstanced"); mark_cur_dirty(); o_DrawArraysInstanced(a, b, c, d); }
static void (*o_DrawElementsInstanced)(GLenum, GLsizei, GLenum, const void *, GLsizei);
static void h_DrawElementsInstanced(GLenum a, GLsizei b, GLenum c, const void *d, GLsizei e) { ctxless_warn("glDrawElementsInstanced"); mark_cur_dirty(); o_DrawElementsInstanced(a, b, c, d, e); }
static void (*o_DrawRangeElements)(GLenum, GLuint, GLuint, GLsizei, GLenum, const void *);
static void h_DrawRangeElements(GLenum a, GLuint b, GLuint c, GLsizei d, GLenum e, const void *f) { ctxless_warn("glDrawRangeElements"); mark_cur_dirty(); o_DrawRangeElements(a, b, c, d, e, f); }
static void (*o_Clear)(GLbitfield);
static void diag_fbo(void) {      // debug: say why a framebuffer the render server draws into is incomplete
    static int n; if (!g_debug || n >= 40) return;
    GLenum st = glCheckFramebufferStatus(GL_FRAMEBUFFER);
    if (st == GL_FRAMEBUFFER_COMPLETE) return;
    n++;
    GLint fb = 0, t0 = 0, n0 = 0, r = 0, g = 0, b = 0, a = 0, td = 0, nd = 0, ts = 0, ns = 0, w = 0;
    glGetIntegerv(GL_FRAMEBUFFER_BINDING, &fb);
    glGetFramebufferAttachmentParameteriv(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_FRAMEBUFFER_ATTACHMENT_OBJECT_TYPE, &t0);
    glGetFramebufferAttachmentParameteriv(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_FRAMEBUFFER_ATTACHMENT_OBJECT_NAME, &n0);
    glGetFramebufferAttachmentParameteriv(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, 0x8212, &r);
    glGetFramebufferAttachmentParameteriv(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, 0x8213, &g);
    glGetFramebufferAttachmentParameteriv(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, 0x8214, &b);
    glGetFramebufferAttachmentParameteriv(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, 0x8215, &a);
    glGetFramebufferAttachmentParameteriv(GL_FRAMEBUFFER, GL_DEPTH_ATTACHMENT, GL_FRAMEBUFFER_ATTACHMENT_OBJECT_TYPE, &td);
    glGetFramebufferAttachmentParameteriv(GL_FRAMEBUFFER, GL_DEPTH_ATTACHMENT, GL_FRAMEBUFFER_ATTACHMENT_OBJECT_NAME, &nd);
    glGetFramebufferAttachmentParameteriv(GL_FRAMEBUFFER, GL_STENCIL_ATTACHMENT, GL_FRAMEBUFFER_ATTACHMENT_OBJECT_TYPE, &ts);
    glGetFramebufferAttachmentParameteriv(GL_FRAMEBUFFER, GL_STENCIL_ATTACHMENT, GL_FRAMEBUFFER_ATTACHMENT_OBJECT_NAME, &ns);
    (void)w;
    fprintf(stderr, "EAGL(shim): INCOMPLETE FBO %d status 0x%x: colour0 type 0x%x name %d bits %d/%d/%d/%d, depth type 0x%x name %d, stencil type 0x%x name %d\n", fb, st, t0, n0, r, g, b, a, td, nd, ts, ns);
}
static void h_Clear(GLbitfield m) { ctxless_warn("glClear"); mark_cur_dirty(); diag_fbo(); o_Clear(m); }
static void (*o_ClearBufferfv)(GLenum, GLint, const GLfloat *);
static void h_ClearBufferfv(GLenum a, GLint b, const GLfloat *c) { mark_cur_dirty(); o_ClearBufferfv(a, b, c); }
static void mark_bound_texture_dirty(void) {     // texture writes (upload / copy) land in the texture bound to GL_TEXTURE_2D
    EAGLContext *c = cur_ctx(); if (!c || !c->_private->natt) return;
    GLint t = 0; glGetIntegerv(GL_TEXTURE_BINDING_2D, &t);
    for (int i = 0; i < c->_private->natt; i++) if ((GLint)c->_private->att[i].name == t && att_is_tex(&c->_private->att[i])) c->_private->att[i].dirty = 1;
    g_draw_seen++;
}
static void (*o_ClearBufferiv)(GLenum, GLint, const GLint *);
static void h_ClearBufferiv(GLenum a, GLint b, const GLint *c) { mark_cur_dirty(); o_ClearBufferiv(a, b, c); }
static void (*o_ClearBufferuiv)(GLenum, GLint, const GLuint *);
static void h_ClearBufferuiv(GLenum a, GLint b, const GLuint *c) { mark_cur_dirty(); o_ClearBufferuiv(a, b, c); }
static void (*o_ClearBufferfi)(GLenum, GLint, GLfloat, GLint);
static void h_ClearBufferfi(GLenum a, GLint b, GLfloat c, GLint d) { mark_cur_dirty(); o_ClearBufferfi(a, b, c, d); }
static void (*o_BlitFramebuffer)(GLint, GLint, GLint, GLint, GLint, GLint, GLint, GLint, GLbitfield, GLenum);
static void h_BlitFramebuffer(GLint a, GLint b, GLint c, GLint d, GLint e, GLint f, GLint g, GLint h, GLbitfield i, GLenum j) { ctxless_warn("glBlitFramebuffer"); mark_cur_dirty(); o_BlitFramebuffer(a, b, c, d, e, f, g, h, i, j); }
static void (*o_CopyTexImage2D)(GLenum, GLint, GLenum, GLint, GLint, GLsizei, GLsizei, GLint);
static void h_CopyTexImage2D(GLenum a, GLint b, GLenum c, GLint d, GLint e, GLsizei f, GLsizei g, GLint h) { o_CopyTexImage2D(a, b, c, d, e, f, g, h); mark_bound_texture_dirty(); }
static void (*o_CopyTexSubImage2D)(GLenum, GLint, GLint, GLint, GLint, GLint, GLsizei, GLsizei);
static void h_CopyTexSubImage2D(GLenum a, GLint b, GLint c, GLint d, GLint e, GLint f, GLsizei g, GLsizei h) { o_CopyTexSubImage2D(a, b, c, d, e, f, g, h); mark_bound_texture_dirty(); }
static void (*o_TexSubImage2D)(GLenum, GLint, GLint, GLint, GLsizei, GLsizei, GLenum, GLenum, const void *);
static void unwrap_bound_texture(void) {      // a write into a texture that samples client memory in place must not reach that (read-only) memory: give it private storage first
    EAGLContext *c = cur_ctx(); if (!c || !g_nlive) return;
    GLint t = 0; glGetIntegerv(GL_TEXTURE_BINDING_2D, &t);
    LiveSrc e; BOOL hit = NO;
    pthread_mutex_lock(&g_live_lock);
    for (int i = 0; i < g_nlive; i++) if (g_live[i].ctx == (void *)c && g_live[i].name == (GLuint)t && g_live[i].wrapped) { e = g_live[i]; CFRetain(e.surf); CFRelease(g_live[i].surf); g_live[i] = g_live[--g_nlive]; hit = YES; break; }
    pthread_mutex_unlock(&g_live_lock);
    if (!hit) return;
    g_nowrap = 1; [c texImageIOSurface:e.surf target:GL_TEXTURE_2D internalFormat:e.ifmt width:e.w height:e.h format:e.fmt type:e.type plane:e.plane invert:e.invert]; g_nowrap = 0;
    CFRelease(e.surf);
}
static void h_TexSubImage2D(GLenum a, GLint b, GLint c, GLint d, GLsizei e, GLsizei f, GLenum g, GLenum h, const void *i) { if (a == GL_TEXTURE_2D) unwrap_bound_texture(); o_TexSubImage2D(a, b, c, d, e, f, g, h, i); mark_bound_texture_dirty(); }
static void (*o_GenerateMipmap)(GLenum);
// Log-only probe (it turned out CA never calls this on the phone): mip generation would render into the smaller levels,
// which a wrapped (read-only) import cannot take. If this ever fires with wrapped 1, the unwrap needs a GPU-side copy,
// not the CPU re-read of the IOSurface (which is blind for GPU-produced surfaces).
static void h_GenerateMipmap(GLenum target) {
    if (target == GL_TEXTURE_2D) {
        EAGLContext *c = cur_ctx();
        GLint t = 0; glGetIntegerv(GL_TEXTURE_BINDING_2D, &t);
        int wrapped = 0;
        if (c) {
            pthread_mutex_lock(&g_live_lock);
            for (int i = 0; i < g_nlive; i++) if (g_live[i].ctx == (void *)c && g_live[i].name == (GLuint)t && g_live[i].wrapped) { wrapped = 1; break; }
            pthread_mutex_unlock(&g_live_lock);
        }
        if (g_debug) EAGL_DEBUG("glGenerateMipmap on texture %u (wrapped %d)\n", (unsigned)t, wrapped);
    }
    o_GenerateMipmap(target);
}
static void (*o_BindTexture)(GLenum, GLuint);
static __thread GLuint t_orphan_bind2d = 0;   // a GL_TEXTURE_2D bind seen on a thread with NO current context: Mesa drops
                                              // it, but CA's glyph workers bind the destination texture this way right
                                              // before calling texImageIOSurface: for a context that is not current.
// FALSIFIED EXPERIMENT (2026-11-16): force-initializing "never defined" sampler textures with 1x1 white turned the
// whole UI white - textures 2..27 (boot splash) get their content through a path this file cannot see, and unit-1
// textures like 87 sample black BY DESIGN (black is CA's neutral there). Never re-add any draw-time texture init.
static struct { void *ctx; GLuint name; } g_texdef[512]; static int g_ntexdef;
static void tex_mark_defined(void *ctx, GLuint name) {
    if (!ctx || !name) return;
    pthread_mutex_lock(&g_live_lock);
    int hit = 0; for (int i = 0; i < g_ntexdef; i++) if (g_texdef[i].ctx == ctx && g_texdef[i].name == name) { hit = 1; break; }
    if (!hit && g_ntexdef < 512) { g_texdef[g_ntexdef].ctx = ctx; g_texdef[g_ntexdef].name = name; g_ntexdef++; }
    pthread_mutex_unlock(&g_live_lock);
}
static void h_BindTexture(GLenum target, GLuint name) {
    o_BindTexture(target, name);
    if (target != GL_TEXTURE_2D || !name) return;
    EAGLContext *c = cur_ctx();
    if (!c) { t_orphan_bind2d = name; static unsigned nb; if (nb++ < 200) EAGL_DEBUG("glBindTexture(2D, %u) on a CONTEXT-LESS thread: dropped (remembered as upload destination)\n", name); return; }
    c->_private->bind2d = name;
    if (!g_nlive) return;
    LiveSrc e; BOOL hit = NO;
    pthread_mutex_lock(&g_live_lock);
    for (int i = 0; i < g_nlive; i++) if (g_live[i].ctx == c && g_live[i].name == name) {
        uint32_t now = IOSurfaceGetSeed(g_live[i].surf);
        if (now != g_live[i].seed) { g_live[i].seed = now; e = g_live[i]; hit = YES; }
        break;
    }
    pthread_mutex_unlock(&g_live_lock);
    if (!hit) return;
    if (e.wrapped) { osm_sweet_wrap_sync(IOSurfaceGetID(e.surf)); return; }     // GPU samples the memory itself: only clean the producer's cache lines
    g_reupload = 1;
    [c texImageIOSurface:e.surf target:GL_TEXTURE_2D internalFormat:e.ifmt width:e.w height:e.h format:e.fmt type:e.type plane:e.plane invert:e.invert];
    g_reupload = 0; g_live_reuploads++;
    if (g_debug) { static int n; if (n++ < 100) fprintf(stderr, "EAGL(shim): live surface %u re-uploaded into texture %u (seed changed)\n", IOSurfaceGetID(e.surf), name); }
}
static void (*o_DeleteTextures)(GLsizei, const GLuint *);
static void h_DeleteTextures(GLsizei n, const GLuint *t) {
    // A display texture that was drawn into but not yet copied (CoreAnimation recreates them) would lose its pixels: copy it out before it goes.
    EAGLContext *c = cur_ctx();
    if (c) for (GLsizei i = 0; i < n; i++) for (int k = 0; k < c->_private->natt; k++) {
        Attach *a = &c->_private->att[k];
        if (a->name != t[i]) continue;
        if (g_debug) fprintf(stderr, "EAGL(shim): [ctx %p] glDeleteTextures(%u) deletes an attached texture (surface %u, dirty %d, kind %d direct %d)\n",
                             c, t[i], IOSurfaceGetID(a->surf), a->dirty, a->kind, a->direct);
        if (a->kind == 2 || !att_is_tex(a)) continue;
        BOOL big = IOSurfaceGetWidth(a->surf) * IOSurfaceGetHeight(a->surf) >= 1000000;
        if (g_dirty_track && a->dirty && big) sync_att(c, k);
        // The texture is going away: its attachment must too. A stale entry kept copying a deleted (empty) texture over a live display surface
        // every flush (surface black after CoreAnimation tore down its buffers: display sleep/wake, app switches).
        osm_sweet_forget(IOSurfaceGetID(a->surf)); CFRelease(a->surf);
        c->_private->att[k] = c->_private->att[--c->_private->natt];
        k--;
    }
    if (c) { c->_private->cur_att = -1; }
    pthread_mutex_lock(&g_live_lock);
    for (GLsizei i = 0; i < n; i++) for (int k = 0; k < g_nlive; k++) if (g_live[k].ctx == (void *)c && g_live[k].name == t[i]) {
        CFRelease(g_live[k].surf); g_live[k] = g_live[--g_nlive]; k--;
    }
    pthread_mutex_unlock(&g_live_lock);
    o_DeleteTextures(n, t);
    if (c) update_cur_target(c);
}
static void (*o_BindFramebuffer)(GLenum, GLuint);
static void h_BindFramebuffer(GLenum t, GLuint f) { o_BindFramebuffer(t, f); EAGLContext *c = cur_ctx(); if (c) update_cur_target(c); }
static void (*o_FramebufferTexture2D)(GLenum, GLenum, GLenum, GLuint, GLint);
static void h_FramebufferTexture2D(GLenum a, GLenum b, GLenum c, GLuint d, GLint e) { o_FramebufferTexture2D(a, b, c, d, e); EAGLContext *x = cur_ctx(); if (x) update_cur_target(x); }
static void (*o_FramebufferRenderbuffer)(GLenum, GLenum, GLenum, GLuint);
static void h_FramebufferRenderbuffer(GLenum a, GLenum b, GLenum c, GLuint d) { o_FramebufferRenderbuffer(a, b, c, d); EAGLContext *x = cur_ctx(); if (x) update_cur_target(x); }
static void (*o_DeleteFramebuffers)(GLsizei, const GLuint *);
static void h_DeleteFramebuffers(GLsizei n, const GLuint *f) { o_DeleteFramebuffers(n, f); EAGLContext *x = cur_ctx(); if (x) update_cur_target(x); }
static const struct { const char *name; void **orig; void *hook; } g_dirty_hooks[] = {
    { "glDrawArrays", (void **)&o_DrawArrays, h_DrawArrays }, { "glDrawElements", (void **)&o_DrawElements, h_DrawElements },
    { "glDrawArraysInstanced", (void **)&o_DrawArraysInstanced, h_DrawArraysInstanced }, { "glDrawElementsInstanced", (void **)&o_DrawElementsInstanced, h_DrawElementsInstanced },
    { "glDrawRangeElements", (void **)&o_DrawRangeElements, h_DrawRangeElements }, { "glClear", (void **)&o_Clear, h_Clear }, { "glClearBufferfv", (void **)&o_ClearBufferfv, h_ClearBufferfv },
    { "glClearBufferiv", (void **)&o_ClearBufferiv, h_ClearBufferiv }, { "glClearBufferuiv", (void **)&o_ClearBufferuiv, h_ClearBufferuiv }, { "glClearBufferfi", (void **)&o_ClearBufferfi, h_ClearBufferfi },
    { "glBlitFramebuffer", (void **)&o_BlitFramebuffer, h_BlitFramebuffer }, { "glCopyTexImage2D", (void **)&o_CopyTexImage2D, h_CopyTexImage2D },
    { "glCopyTexSubImage2D", (void **)&o_CopyTexSubImage2D, h_CopyTexSubImage2D }, { "glTexSubImage2D", (void **)&o_TexSubImage2D, h_TexSubImage2D },
    { "glGenerateMipmap", (void **)&o_GenerateMipmap, h_GenerateMipmap },
    { "glDeleteTextures", (void **)&o_DeleteTextures, h_DeleteTextures }, { "glBindTexture", (void **)&o_BindTexture, h_BindTexture },
    { "glBindFramebuffer", (void **)&o_BindFramebuffer, h_BindFramebuffer }, { "glFramebufferTexture2D", (void **)&o_FramebufferTexture2D, h_FramebufferTexture2D },
    { "glFramebufferRenderbuffer", (void **)&o_FramebufferRenderbuffer, h_FramebufferRenderbuffer }, { "glDeleteFramebuffers", (void **)&o_DeleteFramebuffers, h_DeleteFramebuffers },
};

static void eagl_install_hooks(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gl_resolve_all();
        for (int i = 0; i < gl_nfuncs; i++) {
            if (!strcmp(gl_names[i], "glFlush")) { mesa_glFlush = gl_tab[i]; gl_tab[i] = (void *)shim_glFlush; }
            if (!strcmp(gl_names[i], "glFinish")) { mesa_glFinish = gl_tab[i]; gl_tab[i] = (void *)shim_glFinish; }
        }
        g_debug = getenv("EAGL_SHIM_DEBUG") != NULL; g_debug_frames = g_debug && !strcmp(getenv("EAGL_SHIM_DEBUG"), "2");
        g_dirty_track = !getenv("BGL_SYNC_ALL");
        g_direct = !getenv("BGL_NODIRECT"); g_wrapsample = !(getenv("BGL_NOWRAP") && getenv("BGL_NOWRAP")[0] == '1');   /* GPU sampling of client-memory IOSurfaces by default: the CPU copy path reads them stale/zero (CC black boxes, blank widgets); BGL_NOWRAP=1 restores the copy path */
        if (g_dirty_track) {
            // every alias of an entry point is hooked (glBindFramebuffer / glBindFramebufferOES / ...: the render server's slots may use either spelling)
            static const char *const sfx[] = { "", "OES", "EXT", "ARB", "APPLE", "ANGLE" };
            for (int i = 0; i < gl_nfuncs; i++)
                for (unsigned k = 0; k < sizeof g_dirty_hooks / sizeof g_dirty_hooks[0]; k++) {
                    size_t n = strlen(g_dirty_hooks[k].name);
                    if (strncmp(gl_names[i], g_dirty_hooks[k].name, n) || gl_tab[i] == (void *)gl_unimpl) continue;
                    BOOL ok = NO; for (unsigned q = 0; q < 6; q++) if (!strcmp(gl_names[i] + n, sfx[q])) ok = YES;
                    if (!ok) continue;
                    if (!*g_dirty_hooks[k].orig) *g_dirty_hooks[k].orig = gl_tab[i];
                    if (g_debug) fprintf(stderr, "EAGL(shim): dirty-tracking hook on %s\n", gl_names[i]);
                    gl_tab[i] = g_dirty_hooks[k].hook;
                }
            for (unsigned k = 0; k < sizeof g_dirty_hooks / sizeof g_dirty_hooks[0]; k++) if (!*g_dirty_hooks[k].orig) g_dirty_track = 0;   // an entry point missing: cannot track reliably
        }
        if (g_debug) {                  // list the exported entry points Mesa could not provide
            int n = 0;
            for (int i = 0; i < gl_nfuncs; i++) if (gl_tab[i] == (void *)gl_unimpl) { fprintf(stderr, "EAGL(shim): unresolved %s\n", gl_names[i]); n++; }
            fprintf(stderr, "EAGL(shim): %d/%d entry points forwarded to Mesa, %d unresolved\n", gl_nfuncs - n, gl_nfuncs, n);
        }
    });
}

// --- EAGLSharegroup --------------------------------------------------------------------------------------
@implementation EAGLSharegroup
- (instancetype)initWithAPI:(EAGLRenderingAPI)api sharedWithCompute:(BOOL)compute {
    if ((self = [super init])) {
        _private = calloc(1, sizeof *_private);
        _private->api = api;
        pthread_mutex_init(&_private->lock, NULL);
    }
    return self;
}
- (instancetype)initWithAPI:(EAGLRenderingAPI)api { return [self initWithAPI:api sharedWithCompute:NO]; }
- (instancetype)init { return [self initWithAPI:kEAGLRenderingAPIOpenGLES2]; }
- (NSUInteger)APIs { return 1u << (_private->api); }
- (void *)getGLIShared { return _private; }
- (NSString *)debugLabel { return objc_getAssociatedObject(self, @selector(debugLabel)); }
- (void)setDebugLabel:(NSString *)l { objc_setAssociatedObject(self, @selector(debugLabel), l, OBJC_ASSOCIATION_COPY_NONATOMIC); }
- (void)dealloc { if (_private) { pthread_mutex_destroy(&_private->lock); free(_private); } [super dealloc]; }
@end

// --- EAGLContext -----------------------------------------------------------------------------------------
@implementation EAGLContext

- (instancetype)initWithAPI:(EAGLRenderingAPI)api { return [self initWithAPI:api properties:nil]; }
- (instancetype)initWithAPI:(EAGLRenderingAPI)api sharegroup:(EAGLSharegroup *)sg {
    return [self initWithAPI:api properties:sg ? @{ kEAGLContextPropertySharegroup : sg } : nil];
}
- (instancetype)initWithAPI:(EAGLRenderingAPI)api sharedWithCompute:(BOOL)compute {
    return [self initWithAPI:api properties:@{ kEAGLContextPropertySharedWithCompute : @(compute) }];
}
- (instancetype)init { return nil; }

- (instancetype)initWithAPI:(EAGLRenderingAPI)api properties:(NSDictionary *)props {
    eagl_install_hooks();
    if (api < kEAGLRenderingAPIOpenGLES1 || api > kEAGLRenderingAPIOpenGLES3) { [self release]; return nil; }
    if ((self = [super init])) {
        struct _EAGLContextPrivate *p = calloc(1, sizeof *p);
        _private = p;
        p->api = api;
        p->dummy = calloc(DUMMY_W * DUMMY_H, 4);
        EAGLSharegroup *sg = props[kEAGLContextPropertySharegroup];
        p->sg = sg ? [sg retain] : [[EAGLSharegroup alloc] initWithAPI:api];
        NSString *lbl = props[kEAGLContextPropertyClientLabel];
        if ([lbl isKindOfClass:[NSString class]]) p->label = [lbl copy];
        struct _EAGLSharegroupPrivate *g = p->sg->_private;
        pthread_mutex_lock(&g->lock);
        osm_ctx share = g->nlive ? g->live[0] : NULL;
        p->osm = osm_create(api == kEAGLRenderingAPIOpenGLES1 ? 1 : (int)api, share);
        if (p->osm && g->nlive < 64) g->live[g->nlive++] = p->osm;
        pthread_mutex_unlock(&g->lock);
        if (!p->osm) { EAGL_DEBUG("OSMesaCreateContextAttribs failed (api %d)\n", (int)api); [self release]; return nil; }
        EAGL_DEBUG("context %p created api %d sharegroup %p osm %p shared-with %p\n", self, (int)api, p->sg, p->osm, share);
        ctxreg_add(self, p->osm);   // cur_ctx() fallback for glslot_gate-borrowed threads
        p->macro = macro_ctx_new(p);   // rend = our private block; the slots ignore it (Mesa uses the thread's current context)
    }
    return self;
}

- (void)dealloc {
    struct _EAGLContextPrivate *p = _private;
    pthread_mutex_lock(&g_live_lock);
    for (int k = 0; k < g_nlive; k++) if (g_live[k].ctx == (void *)self) { CFRelease(g_live[k].surf); g_live[k] = g_live[--g_nlive]; k--; }
    pthread_mutex_unlock(&g_live_lock);
    EAGL_DEBUG("context %p dealloc (%d attachments, osm %p)\n", self, p ? p->natt : -1, p ? p->osm : NULL);
    if (p) {
        if (cur_ctx() == self) [EAGLContext setCurrentContext:nil];
        ctxreg_remove(p->osm);
        for (int i = 0; i < p->nbinds; i++) {
            [p->binds[i].drawable release];
            for (int k = 0; k < POOL_N; k++) if (p->binds[i].pool[k]) { osm_sweet_forget(IOSurfaceGetID(p->binds[i].pool[k])); CFRelease(p->binds[i].pool[k]); }
        }
        for (int i = 0; i < p->natt; i++) if (p->att[i].surf) { osm_sweet_forget(IOSurfaceGetID(p->att[i].surf)); CFRelease(p->att[i].surf); }
        if (p->sg) {
            struct _EAGLSharegroupPrivate *g = p->sg->_private;
            pthread_mutex_lock(&g->lock);
            for (int i = 0; i < g->nlive; i++) if (g->live[i] == p->osm) { g->live[i] = g->live[--g->nlive]; break; }
            pthread_mutex_unlock(&g->lock);
        }
        if (p->osm) osm_destroy(p->osm);
        [p->sg release]; [p->label release];
        free(p->dummy); macro_ctx_free(p->macro); free(p);
        _private = NULL;
    }
    [super dealloc];
}

+ (BOOL)setCurrentContext:(EAGLContext *)ctx {
    pthread_once(&g_tls_once, tls_init);
    EAGLContext *old = pthread_getspecific(g_tls);
    if (ctx) {
        struct _EAGLContextPrivate *p = ctx->_private;
        if (!osm_make_current(p->osm, p->dummy, DUMMY_W, DUMMY_H)) return NO;
        [ctx retain];
    } else {
        osm_make_current(NULL, NULL, 0, 0);
    }
    pthread_setspecific(g_tls, ctx);
    [old release];
    return YES;
}
+ (EAGLContext *)currentContext { return [[cur_ctx() retain] autorelease]; }

- (EAGLRenderingAPI)API { return _private->api; }
- (EAGLSharegroup *)sharegroup { return _private->sg; }
- (NSString *)debugLabel { return _private->label; }
- (void)setDebugLabel:(NSString *)l { [_private->label release]; _private->label = [l copy]; }
- (BOOL)isMultiThreaded { return _private->multithreaded; }
- (void)setMultiThreaded:(BOOL)m { _private->multithreaded = m; }

// Private parameter store: CoreAnimation reads/writes a few integer parameters; unknown ones just round-trip.
- (NSUInteger)setParameter:(uint32_t)param to:(int *)value { if (param < 64 && value) _private->params[param] = *value; return 0; }
- (NSUInteger)getParameter:(uint32_t)param to:(int *)value { if (value) *value = param < 64 ? _private->params[param] : 0; return 0; }

- (EAGLMacroContext *)getMacroContextPrivate { return _private->macro; }
- (EAGLMacroContext *)GetMacroContextPrivate { return _private->macro; }
+ (EAGLMacroContext *)GetMacroContextPrivate { EAGLContext *c = cur_ctx(); return c ? c->_private->macro : NULL; }

- (BOOL)setBlockFence:(void (^)(void))block onQueue:(dispatch_queue_t)queue {
    EAGLContext *c = cur_ctx();
    if (c == self) shim_glFinish();
    if (block && queue) dispatch_async(queue, block);
    return YES;
}

// --- drawables ---
static DrawBind *find_bind(struct _EAGLContextPrivate *p, GLuint rb) {
    for (int i = 0; i < p->nbinds; i++) if (p->binds[i].rb == rb) return &p->binds[i];
    return NULL;
}

- (BOOL)renderbufferStorage:(NSUInteger)target fromDrawable:(id<EAGLDrawable>)drawable {
    struct _EAGLContextPrivate *p = _private;
    if (cur_ctx() != self || target != GL_RENDERBUFFER) return NO;
    GLint rb = 0;
    glGetIntegerv(GL_RENDERBUFFER_BINDING, &rb);
    if (!rb) return NO;
    DrawBind *b = find_bind(p, rb);
    if (!drawable) {                                    // drop the storage
        glRenderbufferStorage(GL_RENDERBUFFER, GL_RGBA8, 0, 0);
        if (b) {
            [b->drawable release]; b->drawable = nil;
            for (int k = 0; k < POOL_N; k++) if (b->pool[k]) { osm_sweet_forget(IOSurfaceGetID(b->pool[k])); CFRelease(b->pool[k]); b->pool[k] = NULL; }
            *b = p->binds[--p->nbinds];
        }
        return YES;
    }
    CGRect r = CGRectZero; CGFloat scale = 1;
    id d = (id)drawable;
    if ([d respondsToSelector:@selector(bounds)]) r = ((CGRect (*)(id, SEL))objc_msgSend)(d, @selector(bounds));
    if ([d respondsToSelector:@selector(contentsScale)]) scale = ((CGFloat (*)(id, SEL))objc_msgSend)(d, @selector(contentsScale));
    if (scale <= 0) scale = 1;
    uint32_t w = (uint32_t)ceil(r.size.width * scale), h = (uint32_t)ceil(r.size.height * scale);
    if (!w || !h) return NO;
    GLenum fmt = GL_RGBA8;
    NSDictionary *props = [d respondsToSelector:@selector(drawableProperties)] ? [d drawableProperties] : nil;
    NSString *cf = props[kEAGLDrawablePropertyColorFormat];
    if ([cf isEqual:kEAGLColorFormatRGB565]) fmt = GL_RGB565;
    else if ([cf isEqual:kEAGLColorFormatSRGBA8]) fmt = GL_SRGB8_ALPHA8;
    glRenderbufferStorage(GL_RENDERBUFFER, fmt, w, h);
    if (glGetError() != GL_NO_ERROR) return NO;
    if (!b) {
        if (p->nbinds >= MAX_BIND) return NO;
        b = &p->binds[p->nbinds++];
        memset(b, 0, sizeof *b);
        b->rb = rb;
    }
    if (b->drawable != d) { [b->drawable release]; b->drawable = [d retain]; }
    if (b->w != w || b->h != h) {
        for (int k = 0; k < POOL_N; k++) if (b->pool[k]) { osm_sweet_forget(IOSurfaceGetID(b->pool[k])); CFRelease(b->pool[k]); b->pool[k] = NULL; }
    }
    b->w = w; b->h = h; b->fmt = fmt;
    EAGL_DEBUG("renderbuffer %d <- drawable %ux%u\n", rb, w, h);
    return YES;
}

- (BOOL)presentRenderbuffer:(NSUInteger)target {
    struct _EAGLContextPrivate *p = _private;
    if (cur_ctx() != self || target != GL_RENDERBUFFER) return NO;
    GLint rb = 0;
    glGetIntegerv(GL_RENDERBUFFER_BINDING, &rb);
    DrawBind *b = rb ? find_bind(p, rb) : NULL;
    if (!b) return NO;
    BOOL opaque = YES;
    if ([b->drawable respondsToSelector:@selector(isOpaque)]) opaque = ((BOOL (*)(id, SEL))objc_msgSend)(b->drawable, @selector(isOpaque));
    IOSurfaceRef s = b->pool[b->next];
    if (!s) s = b->pool[b->next] = make_surface(b->w, b->h);
    b->next = (b->next + 1) % POOL_N;
    if (!s) return NO;
    if (!(osm_sweet_active() && osm_sweet_blit((unsigned)rb, 0, IOSurfaceGetID(s), 1, opaque))) {     // CPU fallback (softpipe, or a surface the GPU cannot use)
        uint32_t w, h;
        uint8_t *buf = read_image(self, rb, NO, 0, 0, &w, &h);
        if (!buf) return NO;
        rgba_to_surface(buf, w, h, s, YES, opaque);
        free(buf);
    }
    if ([b->drawable respondsToSelector:@selector(setContents:)])
        ((void (*)(id, SEL, id))objc_msgSend)(b->drawable, @selector(setContents:), (id)s);
    return YES;
}
- (BOOL)presentRenderbuffer:(NSUInteger)target atTime:(CFTimeInterval)t { return [self presentRenderbuffer:target]; }
- (BOOL)presentRenderbuffer:(NSUInteger)target afterMinimumDuration:(CFTimeInterval)d { return [self presentRenderbuffer:target]; }

// --- IOSurface ---
- (BOOL)attachImage:(NSUInteger)image toCoreSurface:(IOSurfaceRef)surface invertedRender:(BOOL)inverted {
    // `image` is a GL TARGET (CoreAnimation passes GL_TEXTURE_2D = 3553, found by dumping the server's calls on the phone): the image
    // currently bound at that target gets the IOSurface as its storage. A plain object name (our own tests) is still accepted.
    struct _EAGLContextPrivate *p = _private;
    int kind = 0;
    BOOL direct = NO;
    GLuint name = (GLuint)image;
    if (surface && (image == GL_TEXTURE_2D || image == GL_RENDERBUFFER || image == 0x84f5)) g_target_attach = 1;
    if (surface && (image == GL_TEXTURE_2D || image == GL_RENDERBUFFER || image == 0x84f5 /* TEXTURE_RECTANGLE */)) {
        GLint bound = 0;
        if (image == GL_RENDERBUFFER) { glGetIntegerv(GL_RENDERBUFFER_BINDING, &bound); kind = 2; }
        else { glGetIntegerv(GL_TEXTURE_BINDING_2D, &bound); kind = 1; }
        if (!bound) return NO;
        name = (GLuint)bound;
        uint32_t w = (uint32_t)IOSurfaceGetWidth(surface), h = (uint32_t)IOSurfaceGetHeight(surface);
        if (kind == 2) glRenderbufferStorage(GL_RENDERBUFFER, GL_RGBA8, w, h);
        else {
            glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, w, h, 0, GL_RGBA, GL_UNSIGNED_BYTE, NULL);
            glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
            glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
            glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
            glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
            if (g_direct && !inverted && osm_sweet_active() && IOSurfaceGetPixelFormat(surface) == 'BGRA' && (IOSurfaceGetBytesPerRow(surface) & 63u) == 0 && IOSurfaceGetWidth(surface) * IOSurfaceGetHeight(surface) >= 1000000 && osm_sweet_attach_direct(name, IOSurfaceGetID(surface))) direct = YES;   // direct (zero-copy) only for display-size surfaces: worker-thread renders into smaller direct-attached textures left the surface empty (lock-screen clock 772x164, glyphs), while the same worker's renders into normal textures + GPU blit sync land fine (verified by readback); the render server's flips (828x1792) are the only proven-working direct case
            // keep what the surface already shows: CoreAnimation redraws only the damaged part of a swap-chain buffer
            else if (IOSurfaceGetPixelFormat(surface) == 'BGRA') {
                p->target_nowrap = YES;      // render-target attachment: the texture is drawn into, so it must not become a read-only in-place wrap of the surface
                [self texImageIOSurface:surface target:GL_TEXTURE_2D internalFormat:GL_RGBA width:w height:h format:GL_BGRA_EXT type:GL_UNSIGNED_BYTE plane:0 invert:!inverted];   // same row order as the sync
                p->target_nowrap = NO;
            }
        }
        if (glGetError() != GL_NO_ERROR) EAGL_DEBUG("attachImage: storage for %ux%u failed\n", w, h);
    }
    int idx = -1;
    for (int i = 0; i < p->natt; i++) if (p->att[i].name == name && p->att[i].kind == kind) idx = i;
    if (!surface) {                                     // detach
        if (idx >= 0) { osm_sweet_forget(IOSurfaceGetID(p->att[idx].surf)); CFRelease(p->att[idx].surf); p->att[idx] = p->att[--p->natt]; update_cur_target(self); }
        return YES;
    }
    if (idx < 0) {
        if (p->natt >= MAX_BIND) return NO;
        idx = p->natt++;
    } else { osm_sweet_forget(IOSurfaceGetID(p->att[idx].surf)); CFRelease(p->att[idx].surf); }
    p->att[idx].name = name; p->att[idx].kind = kind; p->att[idx].surf = (IOSurfaceRef)CFRetain(surface); p->att[idx].inverted = inverted; p->att[idx].dirty = 1; p->att[idx].direct = direct;
    // CoreAnimation attaches a NEW texture to the same display surface every frame; the earlier textures keep older pixels. Syncing them all wrote
    // those stale images over the surface in array order (the flicker, the black wallpaper): only the latest attachment of a surface is valid.
    for (int j = p->natt - 1; j >= 0; j--) {
        if (j == idx || IOSurfaceGetID(p->att[j].surf) != IOSurfaceGetID(surface)) continue;
        CFRelease(p->att[j].surf);
        if (idx == p->natt - 1) idx = j;      // the last entry moves into slot j
        p->att[j] = p->att[--p->natt];
    }
    update_cur_target(self);
    if (g_debug && IOSurfaceGetWidth(surface) * IOSurfaceGetHeight(surface) >= 4096 && IOSurfaceLock(surface, kIOSurfaceLockReadOnly, NULL) == KERN_SUCCESS) {
        const uint8_t *sp = IOSurfaceGetBaseAddress(surface); size_t bpr = IOSurfaceGetBytesPerRow(surface), sh2 = IOSurfaceGetHeight(surface), sw2 = IOSurfaceGetWidth(surface);
        // read the samples through the kernel: a direct CPU read of a GPU-only mapping faults (the es3 crash loop)
        uint32_t first[4] = {0}, centre[4] = {0}; vm_size_t got = 0; BOOL ok1 = NO, ok2 = NO;
        if (sp) {
            ok1 = vm_read_overwrite(mach_task_self(), (vm_address_t)sp, 4, (vm_address_t)first, &got) == KERN_SUCCESS && got == 4;
            got = 0;
            ok2 = vm_read_overwrite(mach_task_self(), (vm_address_t)(sp + (sh2 / 2) * bpr + (sw2 / 2) * 4), 4, (vm_address_t)centre, &got) == KERN_SUCCESS && got == 4;
            if (ok1) fprintf(stderr, "EAGL(shim): attach: surface %u (%zux%zu) holds first %02x%02x%02x%02x centre %02x%02x%02x%02x (direct %d, centre read %d)\n", IOSurfaceGetID(surface), sw2, sh2,
                             first[0], first[1], first[2], first[3], centre[0], centre[1], centre[2], centre[3], direct, ok2);
        }
        IOSurfaceUnlock(surface, kIOSurfaceLockReadOnly, NULL);
    }
    EAGL_DEBUG("[ctx %p] attachImage %lu -> %s %u, IOSurface %u (%zux%zu) inverted=%d\n", self, (unsigned long)image, kind == 2 ? "renderbuffer" : kind == 1 ? "texture" : "object", name,
               IOSurfaceGetID(surface), IOSurfaceGetWidth(surface), IOSurfaceGetHeight(surface), inverted);
    return YES;
}

- (BOOL)texImageIOSurface:(IOSurfaceRef)ioSurface target:(NSUInteger)target internalFormat:(NSUInteger)internalFormat
                    width:(uint32_t)width height:(uint32_t)height format:(NSUInteger)format type:(NSUInteger)type
                    plane:(uint32_t)plane {
    return [self texImageIOSurface:ioSurface target:target internalFormat:internalFormat width:width height:height
                            format:format type:type plane:plane invert:YES];   // public form: rows as stored
}

// Glyph/mask uploads (lock-screen clock digits, CC icon masks) arrive on worker threads with NO current context, for
// a context that may be current on another thread (the glyph context's FBO setup ran with it current). Refusing them
// (old reason 1) leaves the texture empty and the element invisible; borrowing the target context with
// setCurrentContext crashed backboardd (a Mesa context must never be current on two threads). Instead: upload through
// a shim-private helper context that shares the target's sharegroup - texture names resolve to the same objects - and
// is only ever current while g_upctx_lock is held. The destination texture is whichever the caller bound (a bind on a
// context-less thread is recorded by h_BindTexture as t_orphan_bind2d), else the target's own last bound 2D texture.
static pthread_mutex_t g_upctx_lock = PTHREAD_MUTEX_INITIALIZER;
static struct { EAGLContext *target, *helper; } g_upctx[4];
static __thread int g_helper_active;   // the Body runs with the helper (not the receiver) current

static EAGLContext *upctx_for(EAGLContext *target) {
    for (int i = 0; i < 4; i++) if (g_upctx[i].target == target && g_upctx[i].helper) return g_upctx[i].helper;
    EAGLContext *h = [[EAGLContext alloc] initWithAPI:target->_private->api sharegroup:target.sharegroup];
    if (!h) return NULL;
    int slot = -1; for (int i = 0; i < 4; i++) if (!g_upctx[i].helper) { slot = i; break; }
    if (slot < 0) { [g_upctx[0].helper release]; slot = 0; }   // bounded (CA uses one glyph context); targets live forever
    g_upctx[slot].target = target; g_upctx[slot].helper = h;
    return h;
}

- (BOOL)texImageIOSurface:(IOSurfaceRef)ioSurface target:(NSUInteger)target internalFormat:(NSUInteger)internalFormat
                    width:(uint32_t)width height:(uint32_t)height format:(NSUInteger)format type:(NSUInteger)type
                    plane:(uint32_t)plane invert:(BOOL)invert {
    if (ioSurface && cur_ctx() != self) {
        if (osm_cur_ctx() == self->_private->osm) {   // glslot_gate already borrowed this context onto the thread: run in place
            g_helper_active = 1;
            BOOL r = [self texImageIOSurfaceBody:ioSurface target:target internalFormat:internalFormat width:width height:height
                                         format:format type:type plane:plane invert:invert];
            g_helper_active = 0;
            return r;
        }
        GLuint dst = t_orphan_bind2d ? t_orphan_bind2d : self->_private->bind2d;
        if (dst) {
            pthread_mutex_lock(&g_upctx_lock);
            EAGLContext *h = upctx_for(self);
            BOOL r = NO, ran = NO;
            if (h) {
                [EAGLContext setCurrentContext:h];
                if (o_BindTexture) o_BindTexture(GL_TEXTURE_2D, dst); else glBindTexture(GL_TEXTURE_2D, dst);
                g_helper_active = 1;
                r = [self texImageIOSurfaceBody:ioSurface target:target internalFormat:internalFormat width:width height:height
                                         format:format type:type plane:plane invert:invert];
                g_helper_active = 0;
                [EAGLContext setCurrentContext:nil];
                ran = YES;
                EAGL_DEBUG("texImageIOSurface: surface %u -> texture %u via helper ctx %p (target %p not current here)\n",
                           IOSurfaceGetID(ioSurface), dst, h, self);
            }
            pthread_mutex_unlock(&g_upctx_lock);
            if (ran) { t_orphan_bind2d = 0; return r; }
        }
        EAGL_DEBUG("texImageIOSurface: surface %u fourcc %08x %ux%u for NON-CURRENT ctx %p (cur %p, dst tex %u): refused\n",
                   IOSurfaceGetID(ioSurface), (unsigned)IOSurfaceGetPixelFormat(ioSurface), width, height, self, cur_ctx(), dst);
        return NO;
    }
    return [self texImageIOSurfaceBody:ioSurface target:target internalFormat:internalFormat width:width height:height
                                  format:format type:type plane:plane invert:invert];
}

- (BOOL)texImageIOSurfaceBody:(IOSurfaceRef)ioSurface target:(NSUInteger)target internalFormat:(NSUInteger)internalFormat
                    width:(uint32_t)width height:(uint32_t)height format:(NSUInteger)format type:(NSUInteger)type
                    plane:(uint32_t)plane invert:(BOOL)invert {
    if (ioSurface) EAGL_DEBUG("texImageIOSurface source: surface %u fourcc %08x planes %zu %zux%zu bpr %zu\n", IOSurfaceGetID(ioSurface), (unsigned)IOSurfaceGetPixelFormat(ioSurface), IOSurfaceGetPlaneCount(ioSurface), IOSurfaceGetWidth(ioSurface), IOSurfaceGetHeight(ioSurface), IOSurfaceGetBytesPerRow(ioSurface));
    if (g_debug && ioSurface && IOSurfaceGetWidth(ioSurface) * IOSurfaceGetHeight(ioSurface) >= 400000 && IOSurfaceLock(ioSurface, kIOSurfaceLockReadOnly, NULL) == KERN_SUCCESS) {
        const uint8_t *q = IOSurfaceGetBaseAddress(ioSurface); size_t qb = IOSurfaceGetBytesPerRow(ioSurface), qh = IOSurfaceGetHeight(ioSurface), qw = IOSurfaceGetWidth(ioSurface), nz = 0, tot = 0;
        if (q) { for (size_t y = 3; y < qh; y += 37) for (size_t x = 5; x < qw * 4 && x < qb; x += 41) { tot++; if (q[y * qb + x]) nz++; } }
        fprintf(stderr, "EAGL(shim): source content: surface %u non-zero samples %zu of %zu (mapped %d) alloc-size %zu\n", IOSurfaceGetID(ioSurface), nz, tot, q != NULL, IOSurfaceGetAllocSize(ioSurface));
        IOSurfaceUnlock(ioSurface, kIOSurfaceLockReadOnly, NULL);
    }
    EAGL_DEBUG("texImageIOSurface %p target 0x%lx ifmt 0x%lx %ux%u fmt 0x%lx type 0x%lx invert %d\n", ioSurface, (unsigned long)target, (unsigned long)internalFormat, width, height, (unsigned long)format, (unsigned long)type, invert);
    const uint32_t seed_at_copy = ioSurface ? IOSurfaceGetSeed(ioSurface) : 0;     // taken before the copy: a write during it is picked up at the next bind
    if ((cur_ctx() != self && !g_helper_active) || !ioSurface || (plane != 0 && plane >= IOSurfaceGetPlaneCount(ioSurface))) do { EAGL_DEBUG("texImageIOSurface: refused (reason 1) surface %u fourcc %08x planes %zu\n", ioSurface ? IOSurfaceGetID(ioSurface) : 0, ioSurface ? (unsigned)IOSurfaceGetPixelFormat(ioSurface) : 0, ioSurface ? IOSurfaceGetPlaneCount(ioSurface) : (size_t)0); return NO; } while (0);
    OSType pf = IOSurfaceGetPixelFormat(ioSurface);
    // multi-plane surfaces (420 video-like snapshots: Y and CbCr planes uploaded as separate textures): geometry and memory of the requested plane
    const BOOL planar = IOSurfaceGetPlaneCount(ioSurface) > 0;
    if (plane) EAGL_DEBUG("texImageIOSurface: plane %u of surface %u (%zu planes) %zux%zu bpr %zu\n", plane, IOSurfaceGetID(ioSurface), IOSurfaceGetPlaneCount(ioSurface), IOSurfaceGetWidthOfPlane(ioSurface, plane), IOSurfaceGetHeightOfPlane(ioSurface, plane), IOSurfaceGetBytesPerRowOfPlane(ioSurface, plane));
    size_t sw = planar ? IOSurfaceGetWidthOfPlane(ioSurface, plane) : IOSurfaceGetWidth(ioSurface), sh = planar ? IOSurfaceGetHeightOfPlane(ioSurface, plane) : IOSurfaceGetHeight(ioSurface);
    uint32_t w = width < sw ? width : (uint32_t)sw, h = height < sh ? height : (uint32_t)sh;
    if (!w || !h) do { EAGL_DEBUG("texImageIOSurface: refused (reason 2) surface %u fourcc %08x planes %zu\n", ioSurface ? IOSurfaceGetID(ioSurface) : 0, ioSurface ? (unsigned)IOSurfaceGetPixelFormat(ioSurface) : 0, ioSurface ? IOSurfaceGetPlaneCount(ioSurface) : (size_t)0); return NO; } while (0);
    // Bytes per texel from the GL format/type CoreAnimation asks for (it uploads A8 masks, LA8, RGBA half float gradients, BGRA ...).
    size_t comps = 0, csz = 1;
    switch (format) {
    case 0x1906: case 0x1909: case 0x1903: comps = 1; break;                 // ALPHA, LUMINANCE, RED
    case 0x190a: case 0x8227: comps = 2; break;                              // LUMINANCE_ALPHA, RG
    case 0x1907: comps = 3; break;                                           // RGB
    case 0x1908: case GL_BGRA_EXT: comps = 4; break;                         // RGBA, BGRA
    default: do { EAGL_DEBUG("texImageIOSurface: refused (reason 3) surface %u fourcc %08x planes %zu\n", ioSurface ? IOSurfaceGetID(ioSurface) : 0, ioSurface ? (unsigned)IOSurfaceGetPixelFormat(ioSurface) : 0, ioSurface ? IOSurfaceGetPlaneCount(ioSurface) : (size_t)0); return NO; } while (0);
    }
    switch (type) {
    case 0x1401: csz = 1; break;                                             // UNSIGNED_BYTE
    case 0x140b: case 0x8d61: csz = 2; break;                                // HALF_FLOAT(_OES)
    case 0x1406: csz = 4; break;                                             // FLOAT
    case 0x8363: case 0x8033: case 0x8034: comps = 1; csz = 2; break;        // packed 16 bit
    case 0x8368: comps = 1; csz = 4; break;                                  // UNSIGNED_INT_2_10_10_10_REV
    default: do { EAGL_DEBUG("texImageIOSurface: refused (reason 4) surface %u fourcc %08x planes %zu\n", ioSurface ? IOSurfaceGetID(ioSurface) : 0, ioSurface ? (unsigned)IOSurfaceGetPixelFormat(ioSurface) : 0, ioSurface ? IOSurfaceGetPlaneCount(ioSurface) : (size_t)0); return NO; } while (0);
    }
    size_t bpp = comps * csz, bpr = planar ? IOSurfaceGetBytesPerRowOfPlane(ioSurface, plane) : IOSurfaceGetBytesPerRow(ioSurface);
    if (w * bpp > bpr) do { EAGL_DEBUG("texImageIOSurface: refused (reason 5) surface %u fourcc %08x planes %zu\n", ioSurface ? IOSurfaceGetID(ioSurface) : 0, ioSurface ? (unsigned)IOSurfaceGetPixelFormat(ioSurface) : 0, ioSurface ? IOSurfaceGetPlaneCount(ioSurface) : (size_t)0); return NO; } while (0);
    BOOL bgra8 = (format == GL_BGRA_EXT && type == 0x1401);                  // swizzled to RGBA below (portable across ES implementations)
    int kind = 0;
    if (type == 0x1401) kind = format == 0x1906 ? 1 : format == 0x1909 ? 2 : format == 0x190a ? 3 : format == 0x1908 ? 4 : format == GL_BGRA_EXT ? 5 : 0;
    else if ((type == 0x140b || type == 0x8d61) && format == 0x1908) kind = 6;
    // Format-less surfaces (fourcc 0) wrap or copy adaptively: the first definition probes the memory through both paths
    // (see wrap_decide). GPU-produced ones (borders, re-rendered modules) are only visible to the wrap; CPU-produced
    // ones (module icons) sample black through the GPU import and must be copied. Fourcc'd surfaces take the same
    // probe with the both-empty-keeps-wrap rule (CC backdrop snapshots must not wrap blind). Decisions stick via the
    // g_live entry: wrapped entries sync on re-upload, copy entries re-clean + re-copy (fmtless_clean).
    int fmt_copy = 0;
    if (ioSurface && fmtcopy_on() && g_wrapsample && !g_nowrap && !planar && osm_sweet_active() && kind) {
        int fmtless = IOSurfaceGetPixelFormat(ioSurface) == 0;
        int known = 0;
        if (g_reupload) { known = 1; fmt_copy = 1; }             // a re-upload only happens for copy entries (wrapped ones sync instead)
        else {
            GLint wb0 = 0; glGetIntegerv(GL_TEXTURE_BINDING_2D, &wb0);
            if (wb0) {
                pthread_mutex_lock(&g_live_lock);
                for (int i = 0; i < g_nlive; i++) if (g_live[i].ctx == self && g_live[i].name == (GLuint)wb0 && g_live[i].surf == ioSurface) { known = 1; fmt_copy = !g_live[i].wrapped; break; }
                pthread_mutex_unlock(&g_live_lock);
                if (!known) fmt_copy = !wrap_decide(ioSurface, kind, w, h, fmtless);
            }
        }
        if (fmt_copy) fmtless_clean(ioSurface, kind, w, h);      // the SBO clean of the throwaway import makes the CPU read below fresh
    }
    // Zero-copy sampling (opt-in): kind of the GL upload that the GPU can sample straight from the surface memory (A8, L8, LA8, RGBA8, BGRA8, RGBA16F)
    if (!fmt_copy && g_wrapsample && !g_nowrap && !g_reupload && !self->_private->target_nowrap && (GLenum)target == GL_TEXTURE_2D && !planar && osm_sweet_active()) {
        GLint wb = 0; glGetIntegerv(GL_TEXTURE_BINDING_2D, &wb);
        if (kind && wb && osm_sweet_wrap_texture((unsigned)wb, IOSurfaceGetID(ioSurface), kind, w, h)) {
            pthread_mutex_lock(&g_live_lock);
            int k = -1; for (int i = 0; i < g_nlive; i++) if (g_live[i].ctx == self && g_live[i].name == (GLuint)wb) { k = i; break; }
            if (k < 0 && g_nlive < MAX_LIVE) { k = g_nlive++; memset(&g_live[k], 0, sizeof g_live[k]); }
            if (k >= 0) {
                if (g_live[k].surf && g_live[k].surf != ioSurface) CFRelease(g_live[k].surf);
                if (g_live[k].surf != ioSurface) CFRetain(ioSurface);
                g_live[k] = (LiveSrc){ self, (GLuint)wb, ioSurface, seed_at_copy, w, h, plane, (GLenum)internalFormat, (GLenum)format, (GLenum)type, invert, YES };
            }
            pthread_mutex_unlock(&g_live_lock);
            glTexParameteri((GLenum)target, GL_TEXTURE_MIN_FILTER, GL_LINEAR); glTexParameteri((GLenum)target, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
            glTexParameteri((GLenum)target, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE); glTexParameteri((GLenum)target, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
            EAGL_DEBUG("texImageIOSurface: surface %u sampled by the GPU in place (kind %d)\n", IOSurfaceGetID(ioSurface), kind);
            if (verify_on() && k >= 0 && !g_live[k].verified) {
                g_live[k].verified = 1;
                eagl_wrap_verify((GLuint)wb, ioSurface, kind, (uint32_t)IOSurfaceGetPixelFormat(ioSurface), w, h);
            }
            return k >= 0;
        }
    }
    uint8_t *tmp = malloc((size_t)w * h * bpp);
    if (!tmp) do { EAGL_DEBUG("texImageIOSurface: refused (reason 6) surface %u fourcc %08x planes %zu\n", ioSurface ? IOSurfaceGetID(ioSurface) : 0, ioSurface ? (unsigned)IOSurfaceGetPixelFormat(ioSurface) : 0, ioSurface ? IOSurfaceGetPlaneCount(ioSurface) : (size_t)0); return NO; } while (0);
    kern_return_t lk = IOSurfaceLock(ioSurface, kIOSurfaceLockReadOnly, NULL);
    const uint8_t *src = lk == KERN_SUCCESS ? (planar ? IOSurfaceGetBaseAddressOfPlane(ioSurface, plane) : IOSurfaceGetBaseAddress(ioSurface)) : NULL;
    if (g_debug && src) { size_t nz = 0, tot = (size_t)w * h * bpp < 65536 ? (size_t)w * h * bpp : 65536; for (size_t i = 0; i < tot; i++) if (src[(i / (w * bpp)) * bpr + i % (w * bpp)]) nz++; EAGL_DEBUG("texImageIOSurface: surface %u plane %u content: %zu of %zu bytes non-zero\n", IOSurfaceGetID(ioSurface), plane, nz, tot); }
    if (!src) {                         // not CPU-mappable here (the render server's display surfaces): nothing to read
        if (lk == KERN_SUCCESS) IOSurfaceUnlock(ioSurface, kIOSurfaceLockReadOnly, NULL);
        EAGL_DEBUG("texImageIOSurface: surface %u has no CPU mapping (lock %x)\n", IOSurfaceGetID(ioSurface), lk);
        free(tmp);
        do { EAGL_DEBUG("texImageIOSurface: refused (reason 7) surface %u fourcc %08x planes %zu\n", ioSurface ? IOSurfaceGetID(ioSurface) : 0, ioSurface ? (unsigned)IOSurfaceGetPixelFormat(ioSurface) : 0, ioSurface ? IOSurfaceGetPlaneCount(ioSurface) : (size_t)0); return NO; } while (0);
    }
    for (uint32_t y = 0; y < h; y++) {
        const uint8_t *sp = src + ((invert || g_target_attach) ? y : (h - 1 - y)) * bpr;   // render server (target-form attach): images keep their native top-down rows; CARenderer-style clients: flipped unless invert
        uint8_t *dp = tmp + (size_t)y * w * bpp;
        if (bgra8) for (uint32_t x = 0; x < w; x++) { uint32_t q = ((const uint32_t *)sp)[x]; ((uint32_t *)dp)[x] = (q & 0xff00ff00u) | ((q & 0xff) << 16) | ((q >> 16) & 0xff); }
        else memcpy(dp, sp, (size_t)w * bpp);
    }
    IOSurfaceUnlock(ioSurface, kIOSurfaceLockReadOnly, NULL);
    (void)pf;
    GLint oldAlign = 4, oldRow = 0;
    glGetIntegerv(GL_UNPACK_ALIGNMENT, &oldAlign);
    glGetIntegerv(GL_UNPACK_ROW_LENGTH, &oldRow);
    glPixelStorei(GL_UNPACK_ALIGNMENT, 1);
    glPixelStorei(GL_UNPACK_ROW_LENGTH, 0);
    GLenum ifmt = internalFormat == GL_BGRA_EXT ? GL_RGBA : (GLenum)internalFormat;
    if (g_reupload) glTexSubImage2D((GLenum)target, 0, 0, 0, w, h, bgra8 ? GL_RGBA : (GLenum)format, (GLenum)type, tmp);
    else glTexImage2D((GLenum)target, 0, ifmt, w, h, 0, bgra8 ? GL_RGBA : (GLenum)format, (GLenum)type, tmp);
    GLenum err = glGetError();
    if (err != GL_NO_ERROR) {
        GLint imm = -1, pbo = -1;
        glGetTexParameteriv((GLenum)target, 0x912f /* GL_TEXTURE_IMMUTABLE_FORMAT */, &imm);
        glGetIntegerv(GL_PIXEL_UNPACK_BUFFER_BINDING, &pbo);
        EAGL_DEBUG("  glTexImage2D failed 0x%x (ifmt 0x%lx fmt 0x%lx type 0x%lx tex-immutable %d pbo %d reupload %d)\n", err, (unsigned long)internalFormat, (unsigned long)format, (unsigned long)type, imm, pbo, g_reupload);
    }
    if (g_debug && kind >= 4 && (uint32_t)w * h >= 100) {      // color-surface copies (glyph quads AND big layers): does the uploaded texture SAMPLE its content?
        static int nu; if (nu++ < 30) {
            GLint vt = 0; glGetIntegerv(GL_TEXTURE_BINDING_2D, &vt);
            int gr = 0, ga = 0, cr = 0, ca = 0;
            if (wrap_probe((GLuint)vt, ioSurface, kind, w, h, &gr, &ga, &cr, &ca))
                EAGL_DEBUG("upload-verify: surface %u kind %d tex %u (%ux%u): after CPU copy the texture samples rgb %d/256 a %d/256 (source CPU rgb %d a %d)\n",
                           IOSurfaceGetID(ioSurface), kind, vt, w, h, gr, ga, cr, ca);
        }
    }
    if (g_debug && kind >= 1 && kind <= 3) {      // glyph-mask uploads (A8/L8/LA8): verify the data really reached the GL texture
        static int nv; if (nv++ < 6) {
            GLint vt = 0; glGetIntegerv(GL_TEXTURE_BINDING_2D, &vt);
            uint32_t rw = 0, rh = 0;
            uint8_t *vb = read_image(self, (GLuint)vt, YES, w, h, &rw, &rh);
            if (!vb) EAGL_DEBUG("mask-verify surface %u kind %d: read_image failed (not renderable?)\n", IOSurfaceGetID(ioSurface), kind);
            else { size_t nz = 0, tot = (size_t)rw * rh * 4; for (size_t q = 0; q < tot; q++) if (vb[q]) nz++; EAGL_DEBUG("mask-verify surface %u kind %d tex %u: GL texture %ux%u, %zu of %zu bytes non-zero\n", IOSurfaceGetID(ioSurface), kind, vt, rw, rh, nz, tot); free(vb); }
        }
    }
    // IOSurface textures have no mip chain: make the texture complete with sane defaults (the client overrides them if it cares).
    if (!g_reupload) {
        glTexParameteri((GLenum)target, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
        glTexParameteri((GLenum)target, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
        glTexParameteri((GLenum)target, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
        glTexParameteri((GLenum)target, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    }
    if (!g_reupload && err == GL_NO_ERROR && (GLenum)target == GL_TEXTURE_2D) {      // remember it for seed checks
        GLint bound = 0; glGetIntegerv(GL_TEXTURE_BINDING_2D, &bound);
        tex_mark_defined(self, (GLuint)bound);
        pthread_mutex_lock(&g_live_lock);
        int k = -1; for (int i = 0; i < g_nlive; i++) if (g_live[i].ctx == self && g_live[i].name == (GLuint)bound) { k = i; break; }
        if (bound && k < 0 && g_nlive < MAX_LIVE) { k = g_nlive++; memset(&g_live[k], 0, sizeof g_live[k]); }
        if (bound && k >= 0) {
            if (g_live[k].surf && g_live[k].surf != ioSurface) CFRelease(g_live[k].surf);
            if (g_live[k].surf != ioSurface) CFRetain(ioSurface);
            g_live[k] = (LiveSrc){ self, (GLuint)bound, ioSurface, seed_at_copy, w, h, plane, (GLenum)internalFormat, (GLenum)format, (GLenum)type, invert };
        }
        pthread_mutex_unlock(&g_live_lock);
    }
    glPixelStorei(GL_UNPACK_ALIGNMENT, oldAlign);
    glPixelStorei(GL_UNPACK_ROW_LENGTH, oldRow);
    free(tmp);
    return err == GL_NO_ERROR;
}

@end

#pragma GCC visibility push(default)
// --- C SPI exported by Apple's OpenGLES.framework -------------------------------------------------------
EAGLMacroContext *EAGLGetCurrentMacroContextPrivate(void) {
    EAGLContext *c = cur_ctx();
    return c ? [c getMacroContextPrivate] : NULL;
}
void *GLIContextFromEAGLContext(EAGLContext *c) { return c ? (void *)c->_private : NULL; }
void EAGLMemoryNotificationRecycling(void) {}
// GLC* dispatch-selection entry points: no function-table swapping behind Mesa; accept and ignore.
void GLCBackDispatch(void) {}
void GLCFrontDispatch(void) {}
void *GLCGetProfilerStorage(void) { return NULL; }
void GLCRestoreDispatch(void) {}
void GLCRestoreDispatchFunction(void) {}
void GLCSelectDispatchBounded(void) {}
void GLCSelectDispatchFunction(void) {}
void GLCSetCompilationPerformanceCallback(void) {}
void GLCSetProfilerStorage(void) {}
#pragma GCC visibility pop

#ifdef EAGL_INJECT
static int patch_class(Class ours, const char *realName) {
    Class real = objc_getClass(realName);
    if (!real || !ours) return 0;
    for (int meta = 0; meta < 2; meta++) {
        Class from = meta ? object_getClass(ours) : ours, to = meta ? object_getClass(real) : real;
        unsigned n = 0;
        Method *ms = class_copyMethodList(from, &n);
        for (unsigned i = 0; i < n; i++)
            class_replaceMethod(to, method_getName(ms[i]), method_getImplementation(ms[i]), method_getTypeEncoding(ms[i]));
        free(ms);
        if (getenv("EAGL_SHIM_DEBUG")) fprintf(stderr, "EAGL(shim): patched %u %s methods of %s\n", n, meta ? "class" : "instance", realName);
    }
    return 1;
}
// The inserted library initializes before the process links OpenGLES in some cases: patch as soon as the real classes exist
// (now, or when a later image load brings them), exactly once.
static void try_patch(void) {
    static int done;
    if (done) return;
    if (objc_getClass("EAGLContext") && objc_getClass("EAGLSharegroup")) {
        patch_class(objc_getClass("BGEAGLContext"), "EAGLContext");
        patch_class(objc_getClass("BGEAGLSharegroup"), "EAGLSharegroup");
        done = 1;
    }
}
static void on_image(const struct mach_header *mh, intptr_t slide) { (void)mh; (void)slide; try_patch(); }
__attribute__((constructor)) static void eagl_inject_patch(void) {
    try_patch();
    _dyld_register_func_for_add_image(on_image);
}
#endif

// Extra environment from a file (launchd gives us no way to setenv): lines "KEY=VALUE" in /private/var/tmp/bgl-env are applied
// before anything here reads its environment; variables already set (by bgl-launch's marker logic) always win.
__attribute__((constructor)) static void eagl_env_file(void) {
    FILE *f = fopen("/private/var/tmp/bgl-env", "r");
    if (!f) return;
    char line[256];
    while (fgets(line, sizeof line, f)) {
        char *nl = strchr(line, '\n'); if (nl) *nl = 0;
        char *eq = strchr(line, '='); if (!eq || eq == line) continue;
        *eq = 0;
        if (getenv(line)) continue;
        setenv(line, eq + 1, 0);
    }
    fclose(f);
}
