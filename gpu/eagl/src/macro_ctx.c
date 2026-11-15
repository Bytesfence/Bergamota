// SPDX-License-Identifier: MIT
// EAGLMacroContext: the structure QuartzCore's GLES renderer gets from -[EAGLContext getMacroContextPrivate] and calls
// GL through, as `((fn)ctx->slot[off])(ctx->rend, args...)`. Layout (22H352, see docs/GPU_EAGL.md): rend at +0, one function
// pointer per entry point at the offsets in macro_slots[] (the same order as macOS's gliDispatch.h for the first ~340 slots,
// Apple's own ES extension after that). Our slots point at forwarders into the same Mesa entry points the gl* exports use.
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <sys/stat.h>
#include "gl_tab.h"
#include "macro_ctx.h"
#include "osm.h"

static void macro_unmapped(void) { static int n; if (n++ < 5) fprintf(stderr, "OpenGLES(shim): call through an unmapped EAGLMacroContext slot\n"); }

extern void *const mt_thunks[];
extern void glslot_gate(void *r);     /* eagl.m: make rend's context current on this thread before the call reaches Mesa */
static volatile int g_trace_on;
__attribute__((visibility("default"))) void EAGLShimSetTrace(int on) { g_trace_on = on; }
static void *target(const char *name);   // resolved in the wrappers section below
// Burst tracing: while EAGL_TRACE routes the macro slots through this hook, the actual logging stays off until
// /private/var/tmp/bgl-trace exists (checked every 1024 calls): ssh in, touch the file, capture a second or two of
// every GL call with draw context (program, bound texture, draw FBO), then remove the file again.
void gl_trace_hook(int idx, long a, long b, long c, long d) {
    static unsigned cnt;
    if (!g_trace_on) {
        if (!strcmp(gl_names[idx], "glShaderSource") && c && getenv("EAGL_TRACE_SHADERS")) {
            const char *const *src = (const char *const *)c;
            for (long i = 0; i < b; i++) fprintf(stderr, "---- shader %ld source %ld\n%s\n----\n", a, i, src[i]);
            return;
        }
        if ((++cnt & 1023) == 0) {
            struct stat st;
            g_trace_on = stat("/private/var/tmp/bgl-trace", &st) == 0;
        }
        if (!g_trace_on) return;
        fprintf(stderr, "EAGL(shim): trace ON\n");
    }
    fprintf(stderr, "GL %s(0x%lx, 0x%lx, 0x%lx, 0x%lx)\n", gl_names[idx], a, b, c, d);
    const char *n = gl_names[idx];
    /* per-unit 2D bindings tracked from the traced calls (multi-texture: unit 0 alone lies) */
    static __thread unsigned tu_act;
    static __thread unsigned tu_bind[8];
    if (!strcmp(n, "glActiveTexture") && a >= 0x84c0 && a < 0x84c8) tu_act = a - 0x84c0;
    if (!strcmp(n, "glBindTexture") && a == 0xde1 && tu_act < 8) tu_bind[tu_act] = b;
    if (!strcmp(n, "glUniform4fv") && c) {
        const float *f = (const float *)c;
        fprintf(stderr, "   u4 loc %ld: %g %g %g %g\n", a, f[0], f[1], f[2], f[3]);
    }
    if (!strcmp(n, "glDrawArrays") || !strcmp(n, "glDrawElements") || !strcmp(n, "glClear") || !strcmp(n, "glBlitFramebuffer")) {
        static void (*gi)(unsigned, int *); if (!gi) { void **tt = 0; gi = (void (*)(unsigned, int *))target("glGetIntegerv"); (void)tt; }
        static void (*gf)(unsigned, float *); if (!gf) gf = (void (*)(unsigned, float *))target("glGetFloatv");
        if (gi) {
            int prog = 0, tex = 0, fbo = 0, vp[4] = {0};
            float clr[4] = {0};
            gi(0x8B8D /* GL_CURRENT_PROGRAM */, &prog);
            gi(0x8069 /* GL_TEXTURE_BINDING_2D */, &tex);
            gi(0x8CA6 /* GL_DRAW_FRAMEBUFFER_BINDING */, &fbo);
            gi(0x0BA2 /* GL_VIEWPORT */, vp);
            if (gf) gf(0x0C22 /* GL_COLOR_CLEAR_VALUE */, clr);
            extern void *eagl_shim_cur_ctx_ptr(void);
            fprintf(stderr, "   ctx: cctx %p prog %u tex2d %u fbo %u vp %d,%d %ux%u clr %g,%g,%g,%g units %u,%u,%u,%u\n",
                    eagl_shim_cur_ctx_ptr(), (unsigned)prog, (unsigned)tex, (unsigned)fbo, vp[0], vp[1], vp[2], vp[3],
                    clr[0], clr[1], clr[2], clr[3], tu_bind[0], tu_bind[1], tu_bind[2], tu_bind[3]);
        }
    }
}

void *macro_ctx_new(void *rend) {
    void *const *thunks = getenv("EAGL_TRACE") ? mt_thunks : ms_thunks;
    void **m = calloc(1, MACRO_CTX_SIZE);
    if (!m) return NULL;
    m[0] = rend;
    for (unsigned o = 8; o + 8 <= MACRO_CTX_SIZE; o += 8) m[o / 8] = (void *)macro_unmapped;
    for (int s = 0; s < macro_nslots; s++) {
        int k = -1;
        for (int i = 0; i < gl_nfuncs; i++) if (!strcmp(gl_names[i], macro_slots[s].name)) { k = i; break; }
        if (k >= 0 && macro_slots[s].off + 8 <= MACRO_CTX_SIZE) {
            // aliases (glFoo / glFooOES) share a slot: prefer the entry without a vendor suffix
            void **dst = &m[macro_slots[s].off / 8];
            if (*dst == (void *)macro_unmapped || strlen(gl_names[k]) < 64) *dst = thunks[k];
        }
    }
    return m;
}
void macro_ctx_free(void *m) { free(m); }

// --- wrappers for entry points with 8+ arguments (arguments beyond x7 live on the stack, so the register shift is not enough) ---
typedef unsigned U; typedef int I; typedef long L;
static void *target(const char *name) {
    for (int i = 0; i < gl_nfuncs; i++) if (!strcmp(gl_names[i], name)) return gl_tab[i];
    return (void *)macro_unmapped;
}
#define CACHED(name) static void *t; if (!t) t = target(name)

// Debug log of the big/compressed texture uploads CoreAnimation does through the 8+ argument entry points (EAGL_SHIM_DEBUG): what it asks for,
// where the data comes from (client pointer or a bound pixel-unpack buffer) and the GL error afterwards.
static int dbg_on(void) { static int v = -1; if (v < 0) v = getenv("EAGL_SHIM_DEBUG") != NULL; return v; }
static unsigned gl_err(void) { static unsigned (*ge)(void); if (!ge) ge = (unsigned (*)(void))target("glGetError"); return ge(); }
static int gl_int(unsigned pname) { static void (*gi)(unsigned, int *); int v = -1; if (!gi) gi = (void (*)(unsigned, int *))target("glGetIntegerv"); gi(pname, &v); return v; }
#define UPLOAD_LOG(name, tgt, lvl, ifmt, w, h, size, data) do { if (dbg_on() && (size) > 100000 || dbg_on() && !strncmp(name, "Compressed", 10) && (w) * (h) > 20000) \
    fprintf(stderr, "EAGL(shim): %s target 0x%x level %d ifmt 0x%x %dx%d size %ld data %p unpack-buffer %d -> error 0x%x\n", name, (unsigned)(tgt), (int)(lvl), (unsigned)(ifmt), (int)(w), (int)(h), (long)(size), (const void *)(data), gl_int(0x88EF), gl_err()); } while (0)

void mw_CompressedTexImage2D(void *r, U a, I b, U c, I d, I e, I f, I g, const void *p) { glslot_gate(r); CACHED("glCompressedTexImage2D"); ((void (*)(U, I, U, I, I, I, I, const void *))t)(a, b, c, d, e, f, g, p); UPLOAD_LOG("CompressedTexImage2D", a, b, c, d, e, g, p); }
void eagl_zero_current_tex2d(void);   /* eagl.m: clear the just-defined texture through a scratch FBO (glClear) */
void mw_TexImage2D(void *r, U a, I b, I c, I d, I e, I f, U g, U h, const void *p) { glslot_gate(r); CACHED("glTexImage2D"); ((void (*)(U, I, I, I, I, I, U, U, const void *))t)(a, b, c, d, e, f, g, h, p); if (!p && b == 0 && a == 0xde1 && (long)d * e > 0 && (long)d * e <= 4000000) { static int on = -1; if (on < 0) { const char *nz = getenv("BGL_NOZERO"); on = !(nz && nz[0] == '1'); } if (on) eagl_zero_current_tex2d();   /* iOS guarantees cleared memory behind glTexImage2D(NULL); Mesa recycles GPU memory (noisy blocks in Control Center). Never pipe->clear_texture here: it stopped GPU submission on the phone */ } UPLOAD_LOG("TexImage2D", a, b, c, d, e, (long)d * e * 4, p); }
void mw_TexSubImage2D(void *r, U a, I b, I c, I d, I e, I f, U g, U h, const void *p) { glslot_gate(r); CACHED("glTexSubImage2D"); ((void (*)(U, I, I, I, I, I, U, U, const void *))t)(a, b, c, d, e, f, g, h, p); }
void mw_CopyTexImage2D(void *r, U a, I b, U c, I d, I e, I f, I g, I h) { glslot_gate(r); CACHED("glCopyTexImage2D"); ((void (*)(U, I, U, I, I, I, I, I))t)(a, b, c, d, e, f, g, h); }
void mw_CopyTexSubImage2D(void *r, U a, I b, I c, I d, I e, I f, I g, I h) { glslot_gate(r); CACHED("glCopyTexSubImage2D"); ((void (*)(U, I, I, I, I, I, I, I))t)(a, b, c, d, e, f, g, h); }
void mw_CompressedTexSubImage2D(void *r, U a, I b, I c, I d, I e, I f, U g, I h, const void *p) { glslot_gate(r); CACHED("glCompressedTexSubImage2D"); ((void (*)(U, I, I, I, I, I, U, I, const void *))t)(a, b, c, d, e, f, g, h, p); UPLOAD_LOG("CompressedTexSubImage2D", a, b, g, e, f, h, p); }
void mw_TexImage3D(void *r, U a, I b, I c, I d, I e, I f, I g, U h, U i, const void *p) { glslot_gate(r); CACHED("glTexImage3D"); ((void (*)(U, I, I, I, I, I, I, U, U, const void *))t)(a, b, c, d, e, f, g, h, i, p); }
void mw_TexSubImage3D(void *r, U a, I b, I c, I d, I e, I f, I g, I h, U i, U j, const void *p) { glslot_gate(r); CACHED("glTexSubImage3D"); ((void (*)(U, I, I, I, I, I, I, I, U, U, const void *))t)(a, b, c, d, e, f, g, h, i, j, p); }
void mw_CopyTexSubImage3D(void *r, U a, I b, I c, I d, I e, I f, I g, I h, I i) { glslot_gate(r); CACHED("glCopyTexSubImage3D"); ((void (*)(U, I, I, I, I, I, I, I, I))t)(a, b, c, d, e, f, g, h, i); }
void mw_CompressedTexImage3D(void *r, U a, I b, U c, I d, I e, I f, I g, I h, const void *p) { glslot_gate(r); CACHED("glCompressedTexImage3D"); ((void (*)(U, I, U, I, I, I, I, I, const void *))t)(a, b, c, d, e, f, g, h, p); }
void mw_CompressedTexSubImage3D(void *r, U a, I b, I c, I d, I e, I f, I g, I h, U i, I j, const void *p) { glslot_gate(r); CACHED("glCompressedTexSubImage3D"); ((void (*)(U, I, I, I, I, I, I, I, U, I, const void *))t)(a, b, c, d, e, f, g, h, i, j, p); }
void mw_BlitFramebuffer(void *r, I a, I b, I c, I d, I e, I f, I g, I h, U i, U j) { glslot_gate(r); CACHED("glBlitFramebuffer"); ((void (*)(I, I, I, I, I, I, I, I, U, U))t)(a, b, c, d, e, f, g, h, i, j); }

// Debug: the CC-era "glUniform(program not linked)" black layers. Log link results with the Mesa info log, and any program-binary loads
// (CA's shader cache: a binary Mesa refuses leaves the program unlinked, silently). EAGL_SHIM_DEBUG gates both.
static int shader_dbg_on(void) { static int v = -1; if (v < 0) v = getenv("EAGL_SHIM_DEBUG") != NULL; return v; }
void mw_LinkProgram(void *r, U prog) {
    glslot_gate(r);
    CACHED("glLinkProgram"); ((void (*)(U))t)(prog);
    if (shader_dbg_on()) {
        static void (*gpiv)(U, U, I *); if (!gpiv) gpiv = (void (*)(U, U, I *))target("glGetProgramiv");
        if (gpiv) {
            I ok = -1; gpiv(prog, 0x8b82 /* GL_LINK_STATUS */, &ok);
            if (ok == 0) {
                static void (*gpil)(U, I, void *, char *); if (!gpil) gpil = (void (*)(U, I, void *, char *))target("glGetProgramInfoLog");
                char log[1024] = "";
                if (gpil) gpil(prog, (I)sizeof log - 1, NULL, log);
                fprintf(stderr, "EAGL(shim): link of program %u FAILED: %s\n", prog, log);
            } else if (ok == 1) {
                fprintf(stderr, "EAGL(shim): link of program %u ok\n", prog);
            }
        }
    }
}
void mw_ProgramBinary(void *r, U prog, U fmt, const void *bin, I len) {
    glslot_gate(r);
    if (shader_dbg_on()) {
        const unsigned char *m = bin;
        fprintf(stderr, "EAGL(shim): glProgramBinary(%u fmt 0x%x len %d magic %02x%02x%02x%02x %02x%02x%02x%02x)\n", prog, fmt, (int)len,
                m ? m[0] : 0, m ? m[1] : 0, m ? m[2] : 0, m ? m[3] : 0, m ? m[4] : 0, m ? m[5] : 0, m ? m[6] : 0, m ? m[7] : 0);
    }
    CACHED("glProgramBinary"); ((void (*)(U, U, const void *, I))t)(prog, fmt, bin, len);
}
