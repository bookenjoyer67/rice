/* wallfx-gpu — the character-draw wallpaper transition, drawn over awww.
 *
 * Two wlr-layer-shell surfaces per output, both click-through, because the
 * cava bars sit between where the two halves have to go:
 *   stage     (BACKGROUND layer)  the wallpaper crossfade, the outline and the
 *                                 world spreading out — below the bars, so the
 *                                 bars keep showing over the changing wallpaper
 *   character (OVERLAY layer)     only the pixels inside the silhouette plus
 *                                 its outline — above every bar, which is what
 *                                 "the character passes in front of the bars"
 *                                 means; ordering inside a layer is not worth
 *                                 betting on, a different layer is.
 * TOP is above BOTTOM in niri, but a bar is allowed to raise itself to TOP or
 * OVERLAY; OVERLAY is the only layer that is above all of them. If the bars
 * share it, this surface was created last so it still stacks above them.
 * Because it is on OVERLAY it also covers whatever window sits under the
 * silhouette, for the ~1.5 s the character is drawn. That is the price of the
 * character being in front of layer-shell decorations at all: there is no slot
 * between the bottom layer and the windows.
 * Without that split, one fullscreen bottom-layer surface hides the bars for
 * the whole transition.
 *
 * The stage draws the OUTLINE transition only: a thin quiet line in the
 * wallpaper's lightest tone draws the character's silhouette (two pens from
 * the top), the character fills in from that outline, and then the rest of the
 * world spreads out of it in crisp 4 px cells.
 *
 * The maps come from `wallfx perfil IMG` (~/.cache/wallfx/perfil):
 *   campo : R = distance outside the silhouette (wide, for the glow)
 *           G = depth inside the character (0 on its outline)
 *           B = signed distance (-sdRange..+sdRange map px)
 *   linea : R = where along each contour a point is (0..1, 0 = no line)
 *           G/B = the order the outside arrives, as a 16-bit surface
 *
 * Hand-over with awww (what makes it seamless):
 *   1. decode both images and the maps;
 *   2. start the animation and, at the same time, fade in over awww: at t=0
 *      the animation IS the old wallpaper, so the fade is between two renders
 *      of the same picture and nobody sees it;
 *   3. once fully covered, switch awww instantly (--transition-type none);
 *   4. finish on the new image, which awww now shows too;
 *   5. fade out and exit.
 * If anything fails within 2.5 s, awww changes with a plain fade: the
 * wallpaper must change even if the effect cannot be shown.
 *
 * Usage: wallfx-gpu OLD NEW CAMPO LINEA [DURATION_MS]
 */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdarg.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <poll.h>
#include <signal.h>
#include <time.h>
#include <math.h>
#include <sys/types.h>
#include <sys/wait.h>

#include "wlgl.h"

#include <EGL/eglext.h>

#define IMG_MAX 2560          /* longest side an image is decoded at          */

static int cfg_verbose;
static void logmsg(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
static void logmsg(const char *fmt, ...)
{
    if (!cfg_verbose) return;
    va_list ap;
    va_start(ap, fmt);
    vfprintf(stderr, fmt, ap);
    va_end(ap);
    fputc('\n', stderr);
}

static double now_ms(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec * 1000.0 + ts.tv_nsec / 1e6;
}

/* ---------------------------------------------------------------- wayland */

static struct wlgl g;

static GLuint prog, vao;
static GLuint tex_campo, tex_linea;
static int    maps_w, maps_h;
static GLint  u_old, u_new, u_campo, u_linea, u_t, u_sw, u_sh, u_fw,
              u_lw, u_lh, u_lineW, u_sdRange, u_cropOld, u_cropNew, u_ink, u_fade,
              u_charOnly;

/* Two surfaces per output, because the cava bars sit between them:
 *   BACKGROUND layer : STAGE     the wallpaper crossfade, the outline and the
 *                                world spreading out — BELOW the bars, so the
 *                                bars stay visible over the changing wallpaper
 *   OVERLAY layer    : CHARACTER only what is inside the silhouette, plus its
 *                                outline — above every bar layer (TOP included),
 *                                and above the windows
 * With one fullscreen surface on BOTTOM the bars disappeared for the whole
 * transition, which is not what the bars' owner wants to look at.
 */
struct output {
    struct wlgl_output base;        /* must stay first: the registry fills it */
    struct wlgl_layer s[2];         /* 0 stage, 1 character */
    GLuint tex_old, tex_new;
    float crop_old[4], crop_new[4];
};

static int n_ready;

#define OUTPUTS ((struct output *)g.outputs)
#define NEXT(o) ((struct output *)(o)->base.next)

static float g_ink[3] = { 1.f, 1.f, 1.f };   /* the outline's line colour */
static float g_fade = 0.f;                   /* surface opacity, 0..1      */

/* ------------------------------------------------------------------ shader */

static const char *VS_SRC =
    "#version 300 es\n"
    "void main() {\n"
    "  vec2 p = vec2((gl_VertexID << 1) & 2, gl_VertexID & 2);\n"
    "  gl_Position = vec4(p * 2.0 - 1.0, 0.0, 1.0);\n"
    "}\n";

static const char *FS_SRC =
    "#version 300 es\n"
    "precision highp float;\n"
    "uniform sampler2D oldTex;\n"
    "uniform sampler2D newTex;\n"
    "uniform sampler2D fieldTex;   // campo\n"
    "uniform sampler2D lineTex;    // linea\n"
    "uniform float t;              // 0..1, linear in time\n"
    "uniform float sw, sh;         // screen, px\n"
    "uniform float fw;             // field texels\n"
    "uniform float lw, lh;         // line texels\n"
    "uniform float lineW;          // outline width, px\n"
    "uniform float sdRange;        // campo B spans +-sdRange map px\n"
    "uniform float fade;           // 0..1 surface opacity\n"
    "uniform float charOnly;       // 1 on the character surface, 0 on the stage\n"
    "uniform vec3  ink;            // the wallpaper's lightest tone\n"
    "uniform vec4  cropOld;        // image uv = xy + screen uv * zw\n"
    "uniform vec4  cropNew;\n"
    "out vec4 fragColor;\n"
    "\n"
    "const float CELL = 4.0;\n"
    "float escena(float x) { x = clamp(x, 0.0, 1.0); return x * x * (3.0 - 2.0 * x); }\n"
    "float luma(vec3 c) { return dot(c, vec3(0.299, 0.587, 0.114)); }\n"
    "vec2 cam(vec2 uv, float z) { return 0.5 + (uv - 0.5) / z; }\n"
    "vec3 oldAt(vec2 uv) { return texture(oldTex, cropOld.xy + uv * cropOld.zw).rgb; }\n"
    "vec2 newUv(vec2 uv, float z) { return cropNew.xy + cam(uv, z) * cropNew.zw; }\n"
    "\n"
    "// 16-bit surface in lineTex's G (high) and B (low), interpolated by hand:\n"
    "// the sampler's bilinear filter would blend the two bytes separately.\n"
    "float s16(vec2 texel) {\n"
    "  texel = clamp(texel, vec2(0.0), vec2(lw, lh) - 1.0);\n"
    "  vec4 f = texture(lineTex, (texel + 0.5) / vec2(lw, lh));\n"
    "  return (floor(f.g * 255.0 + 0.5) * 256.0 + floor(f.b * 255.0 + 0.5)) / 65535.0;\n"
    "}\n"
    "float surface(vec2 tuv) {\n"
    "  vec2 p = tuv * vec2(lw, lh) - 0.5;\n"
    "  vec2 i = floor(p), f = p - i;\n"
    "  return mix(mix(s16(i), s16(i + vec2(1.0, 0.0)), f.x),\n"
    "             mix(s16(i + vec2(0.0, 1.0)), s16(i + vec2(1.0, 1.0)), f.x), f.y);\n"
    "}\n"
    "\n"
    "void main() {\n"
    "  // gl_FragCoord is bottom-up; the textures (and the maps) are top-down.\n"
    "  vec2 uv = vec2(gl_FragCoord.x / sw, 1.0 - gl_FragCoord.y / sh);\n"
    "\n"
    "  // Two cameras, barely: the character settles from a touch closer than\n"
    "  // its background, which is enough to give it a little depth.\n"
    "  float zCh = 1.0 + 0.03 * (1.0 - escena(t));\n"
    "  float zBg = 1.0 + 0.015 * (1.0 - escena(t));\n"
    "  vec4 f = texture(fieldTex, newUv(uv, zCh));\n"
    "  float sdPx = (f.b * 2.0 - 1.0) * sdRange * sw * zCh / (fw * cropNew.z);\n"
    "  float inside = clamp(0.5 - sdPx / max(fwidth(sdPx), 1e-3), 0.0, 1.0);\n"
    "\n"
    "  // The stage steps back, a little: a fifth darker, a quarter greyer.\n"
    "  float back = escena(t / 0.18);\n"
    "  vec3 st = oldAt(uv);\n"
    "  st = mix(st, vec3(luma(st)), 0.25 * back) * (1.0 - 0.2 * back);\n"
    "\n"
    "  // The same 4 px cells: each decides by its centre, so the fronts are\n"
    "  // crisp and stepped; the silhouette itself stays smooth.\n"
    "  vec2 grid = vec2(sw, sh) / CELL;\n"
    "  vec2 cuv = (floor(uv * grid) + 0.5) / grid;\n"
    "\n"
    "  // The character fills in from its outline...\n"
    "  float Ti = escena((t - 0.32) / 0.32) * 1.02 - 0.01;\n"
    "  vec3 cIn = texture(fieldTex, newUv(cuv, zCh)).g <= Ti\n"
    "             ? texture(newTex, newUv(uv, zCh)).rgb : st;\n"
    "  // ...and then the world spreads out of it.\n"
    "  float To = escena((t - 0.45) / 0.50) * 1.02 - 0.01;\n"
    "  vec3 cOut = surface(newUv(cuv, zBg)) <= To\n"
    "              ? texture(newTex, newUv(uv, zBg)).rgb : st;\n"
    "  vec3 c = mix(cOut, cIn, inside);\n"
    "\n"
    "  // The line: thin and quiet, in the wallpaper's lightest tone, drawn by\n"
    "  // two pens from the top of every contour; it leaves once the character\n"
    "  // is in.\n"
    "  float drawP = escena((t - 0.02) / 0.33);\n"
    "  float lp = texture(lineTex, newUv(uv, zCh)).r;\n"
    "  float lfade = 1.0 - escena((t - 0.45) / 0.25);\n"
    "  float lineA = 0.0;\n"
    "  if (lp > 0.0 && lp <= drawP && lfade > 0.0) {\n"
    "    float d = abs(sdPx) - lineW * 0.5;\n"
    "    float core = clamp(0.5 - d / max(fwidth(sdPx), 1e-3), 0.0, 1.0);\n"
    "    lineA = core * lfade;\n"
    "    c = mix(c, ink, lineA * 0.75);\n"
    "  }\n"
    "  // The character surface carries only the silhouette and its outline, so\n"
    "  // everything around it (the cava bars, the windows) stays as it was.\n"
    "  float a = charOnly > 0.5 ? clamp(max(inside, lineA), 0.0, 1.0) : 1.0;\n"
    "  fragColor = vec4(clamp(c, 0.0, 1.0) * (fade * a), fade * a);\n"
    "}\n";

static void gpu_init(void)
{
    prog = wlgl_program(&g, VS_SRC, FS_SRC);
    glGenVertexArrays(1, &vao);

    u_old    = glGetUniformLocation(prog, "oldTex");
    u_new    = glGetUniformLocation(prog, "newTex");
    u_campo  = glGetUniformLocation(prog, "fieldTex");
    u_linea  = glGetUniformLocation(prog, "lineTex");
    u_t      = glGetUniformLocation(prog, "t");
    u_sw     = glGetUniformLocation(prog, "sw");
    u_sh     = glGetUniformLocation(prog, "sh");
    u_fw     = glGetUniformLocation(prog, "fw");
    u_lw     = glGetUniformLocation(prog, "lw");
    u_lh     = glGetUniformLocation(prog, "lh");
    u_lineW  = glGetUniformLocation(prog, "lineW");
    u_sdRange= glGetUniformLocation(prog, "sdRange");
    u_cropOld= glGetUniformLocation(prog, "cropOld");
    u_cropNew= glGetUniformLocation(prog, "cropNew");
    u_ink    = glGetUniformLocation(prog, "ink");
    u_fade   = glGetUniformLocation(prog, "fade");
    u_charOnly = glGetUniformLocation(prog, "charOnly");
}

/* ------------------------------------------------------------------ images */

static GLuint upload_rgba(const unsigned char *buf, int w, int h)
{
    GLuint tex = 0;
    glGenTextures(1, &tex);
    glBindTexture(GL_TEXTURE_2D, tex);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, w, h, 0, GL_RGBA, GL_UNSIGNED_BYTE, buf);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    return tex;
}

static void ink_from_buffer(const unsigned char *buf, size_t len, float out[3]);

/* decode an image (shrunk to IMG_MAX on the long side) into a new texture;
 * when ink is non-NULL, also sample its lightest tone from the same bytes */
static GLuint load_image(const char *path, int *ow, int *oh, float ink[3])
{
    int iw = 0, ih = 0;
    wlgl_image_dims(path, &iw, &ih);
    if (iw <= 0 || ih <= 0) return 0;
    char fit[64];
    snprintf(fit, sizeof fit, "%dx%d>", IMG_MAX, IMG_MAX);
    unsigned char *buf = NULL;
    size_t len = 0;
    if (wlgl_magick_rgba(path, fit, &buf, &len) < 0) return 0;
    /* magick reports the size AFTER -resize only through the pixel count:
     * derive the decoded size from the ratio we asked for. */
    double s = 1.0;
    if (iw > IMG_MAX || ih > IMG_MAX)
        s = (iw >= ih) ? (double)IMG_MAX / iw : (double)IMG_MAX / ih;
    int dw = (int)lround(iw * s), dh = (int)lround(ih * s);
    size_t want = (size_t)dw * dh * 4;
    if (dw <= 0 || dh <= 0 || len < want) {
        fprintf(stderr, "wallfx-gpu: decode failed (%zu/%zu bytes): %s\n", len, want, path);
        free(buf);
        return 0;
    }
    if (ink) ink_from_buffer(buf, len, ink);
    GLuint tex = upload_rgba(buf, dw, dh);
    free(buf);
    *ow = dw; *oh = dh;
    return tex;
}

/* cover-crop rect (x, y, w, h in image uv) for this screen, like awww's crop */
static void crop_for(int iw, int ih, int sw, int sh, float out[4])
{
    double s = fmax((double)sw / iw, (double)sh / ih);
    double vw = sw / ((double)iw * s);
    double vh = sh / ((double)ih * s);
    out[0] = (float)((1.0 - vw) / 2.0);
    out[1] = (float)((1.0 - vh) / 2.0);
    out[2] = (float)vw;
    out[3] = (float)vh;
}

static void load_maps(const char *campo, const char *linea)
{
    int cw = 0, ch = 0, lw = 0, lh = 0;
    unsigned char *cbuf = NULL, *lbuf = NULL;
    size_t clen = 0, llen = 0;
    char *cav[] = { "magick", (char *)campo, "-depth", "8", "rgba:-", NULL };
    char *lav[] = { "magick", (char *)linea, "-depth", "8", "rgba:-", NULL };
    wlgl_image_dims(campo, &cw, &ch);
    wlgl_image_dims(linea, &lw, &lh);
    if (cw <= 0 || ch <= 0 || lw <= 0 || lh <= 0) return;
    if (wlgl_magick_pipe(cav, &cbuf, &clen) < 0 ||
        wlgl_magick_pipe(lav, &lbuf, &llen) < 0) {
        free(cbuf); free(lbuf);
        return;
    }
    if (clen < (size_t)cw * ch * 4 || llen < (size_t)lw * lh * 4) {
        free(cbuf); free(lbuf);
        return;
    }
    tex_campo = upload_rgba(cbuf, cw, ch);
    tex_linea = upload_rgba(lbuf, lw, lh);
    maps_w = cw; maps_h = ch;
    free(cbuf); free(lbuf);
}

/* ---------------------------------------------------------------- surfaces */

static void render(struct wlgl_layer *s);
static int  started;
static double started_ms;
static double g_duration_ms = 2000.0;

static void frame_done(void *data, struct wl_callback *cb, uint32_t t)
{
    (void)t;
    struct wlgl_layer *s = data;
    wl_callback_destroy(cb);
    s->frame_cb = NULL;
}

static const struct wl_callback_listener frame_cb_listener = { .done = frame_done };

static void render(struct wlgl_layer *s)
{
    struct output *o = (struct output *)s->output;
    if (!s->configured || !s->esurf || s->frame_cb) return;
    if (eglMakeCurrent(g.egl_dpy, s->esurf, s->esurf, g.egl_ctx) == EGL_FALSE) return;

    int32_t w = s->w, h = s->h;
    if (w <= 0 || h <= 0) return;

    double t = started ? (now_ms() - started_ms) / g_duration_ms : 0.0;
    if (t > 1.0) t = 1.0;
    float fade = g_fade;

    glViewport(0, 0, w, h);
    glDisable(GL_SCISSOR_TEST);
    glClearColor(0.f, 0.f, 0.f, 0.f);
    glClear(GL_COLOR_BUFFER_BIT);

    glEnable(GL_BLEND);
    glBlendFunc(GL_ONE, GL_ONE_MINUS_SRC_ALPHA);
    glUseProgram(prog);
    glBindVertexArray(vao);

    glUniform1f(u_t, (float)t);
    glUniform1f(u_sw, (float)w);
    glUniform1f(u_sh, (float)h);
    glUniform1f(u_fw, (float)maps_w);
    glUniform1f(u_lw, (float)maps_w);
    glUniform1f(u_lh, (float)maps_h);
    glUniform1f(u_lineW, 1.5f);
    glUniform1f(u_sdRange, 16.0f);
    glUniform1f(u_fade, fade);
    glUniform1f(u_charOnly, s->kind == 1 ? 1.f : 0.f);
    glUniform3fv(u_ink, 1, g_ink);
    glUniform4fv(u_cropOld, 1, o->crop_old);
    glUniform4fv(u_cropNew, 1, o->crop_new);

    glActiveTexture(GL_TEXTURE0); glBindTexture(GL_TEXTURE_2D, o->tex_old);
    glUniform1i(u_old, 0);
    glActiveTexture(GL_TEXTURE1); glBindTexture(GL_TEXTURE_2D, o->tex_new);
    glUniform1i(u_new, 1);
    glActiveTexture(GL_TEXTURE2); glBindTexture(GL_TEXTURE_2D, tex_campo);
    glUniform1i(u_campo, 2);
    glActiveTexture(GL_TEXTURE3); glBindTexture(GL_TEXTURE_2D, tex_linea);
    glUniform1i(u_linea, 3);

    glDrawArrays(GL_TRIANGLES, 0, 3);

    s->frame_cb = wl_surface_frame(s->surf);
    wl_callback_add_listener(s->frame_cb, &frame_cb_listener, s);
    eglSwapBuffers(g.egl_dpy, s->esurf);
}

static void render_all(void)
{
    for (struct output *o = OUTPUTS; o; o = NEXT(o)) {
        render(&o->s[0]);
        render(&o->s[1]);
    }
}

static void layer_configured(struct wlgl_layer *l)
{
    struct output *o = (struct output *)l->output;
    if (l->kind == 0 && !l->ready_counted) {
        l->ready_counted = 1;
        n_ready++;
    }
    logmsg("%s: %s %dx%d", o->base.name, l->kind ? "character" : "stage", l->w, l->h);
    render(l);
}

static void layer_closed(struct wlgl_layer *l)
{
    (void)l;
    _exit(0);
}

static const struct wlgl_layer_hooks layer_hooks = {
    .configured = layer_configured,
    .closed = layer_closed,
};

/* ------------------------------------------------------------------- main */

static void fallback(const char *newimg)
{
    /* the wallpaper must change even if the effect cannot be shown */
    pid_t pid = fork();
    if (pid == 0) {
        int dn = open("/dev/null", O_WRONLY);
        if (dn >= 0) { dup2(dn, STDOUT_FILENO); dup2(dn, STDERR_FILENO); }
        execlp("awww", "awww", "img", newimg,
               "--transition-type", "fade", "--transition-duration", "0.5", (char *)NULL);
        _exit(127);
    }
    if (pid > 0) waitpid(pid, NULL, 0);
}

static pid_t swap_pid;

static void swap_awww(const char *newimg)
{
    swap_pid = fork();
    if (swap_pid == 0) {
        int dn = open("/dev/null", O_WRONLY);
        if (dn >= 0) { dup2(dn, STDOUT_FILENO); dup2(dn, STDERR_FILENO); }
        execlp("awww", "awww", "img", newimg, "--transition-type", "none", (char *)NULL);
        _exit(127);
    }
}

/* the wallpaper's lightest tone, sampled from the decoded new image */
static void ink_from_buffer(const unsigned char *buf, size_t len, float out[3])
{
    /* coarse scan: every 997th pixel is plenty for a tone */
    unsigned best = 0;
    double br = 1, bg = 1, bb = 1;
    for (size_t i = 0; i + 3 < len; i += 4 * 997) {
        unsigned r = buf[i], g = buf[i + 1], b = buf[i + 2];
        unsigned l = (unsigned)(0.299 * r + 0.587 * g + 0.114 * b);
        if (l > best) { best = l; br = r; bg = g; bb = b; }
    }
    if (best < 150) {           /* too dark to read on: lift towards white */
        br = br + (255 - br) * 0.7;
        bg = bg + (255 - bg) * 0.7;
        bb = bb + (255 - bb) * 0.7;
    }
    out[0] = (float)(br / 255.0);
    out[1] = (float)(bg / 255.0);
    out[2] = (float)(bb / 255.0);
}

/* Every way out that is not the effect says why: a silent fallback and a
 * played transition look identical from the outside. */
static void fail(const char *newimg, const char *why)
{
    fprintf(stderr, "wallfx-gpu: %s — plain fade\n", why);
    fallback(newimg);
}

int main(int argc, char **argv)
{
    cfg_verbose = getenv("WALLFX_GPU_DEBUG") != NULL;
    if (argc < 5) {
        fprintf(stderr, "usage: wallfx-gpu OLD NEW CAMPO LINEA [DURATION_MS]\n");
        return 2;
    }
    const char *oldimg = argv[1], *newimg = argv[2];
    const char *campo = argv[3], *linea = argv[4];
    if (argc >= 6) {
        char *end = NULL;
        double d = strtod(argv[5], &end);
        if (end && *end == '\0' && d > 0) g_duration_ms = d;
    }

    signal(SIGPIPE, SIG_IGN);

    wlgl_init(&g, "wallfx-gpu", logmsg);
    g.output_size = sizeof(struct output);
    int wl_rc = wlgl_connect(&g);
    if (wl_rc == -1) { fail(newimg, "cannot connect to WAYLAND_DISPLAY"); return 1; }
    if (wl_rc != 0 || !g.outputs) { fail(newimg, "compositor lacks wl_compositor/zwlr_layer_shell_v1 or has no output"); return 1; }

    wlgl_egl_boot(&g);
    gpu_init();

    int old_w = 0, old_h = 0, new_w = 0, new_h = 0;
    GLuint old_tex = load_image(oldimg, &old_w, &old_h, NULL);
    GLuint new_tex = load_image(newimg, &new_w, &new_h, g_ink);
    load_maps(campo, linea);
    if (!old_tex || !new_tex || !tex_campo || !tex_linea) {
        fail(newimg, "could not decode the images or the maps");
        return 1;
    }

    for (struct output *o = OUTPUTS; o; o = NEXT(o)) {
        int ow = o->base.w > 0 ? o->base.w : 1920;
        int oh = o->base.h > 0 ? o->base.h : 1080;
        o->tex_old = old_tex;
        o->tex_new = new_tex;
        crop_for(old_w, old_h, ow, oh, o->crop_old);
        crop_for(new_w, new_h, ow, oh, o->crop_new);
        uint32_t lw = o->base.w > 0 ? (uint32_t)o->base.w : 0;
        uint32_t lh = o->base.h > 0 ? (uint32_t)o->base.h : 0;
        wlgl_create_layer(&g, &o->base, &o->s[0], 0,
                          ZWLR_LAYER_SHELL_V1_LAYER_BACKGROUND, "wallfx-gpu-stage",
                          lw, lh, &layer_hooks, o);
        wlgl_create_layer(&g, &o->base, &o->s[1], 1,
                          ZWLR_LAYER_SHELL_V1_LAYER_OVERLAY, "wallfx-gpu",
                          lw, lh, &layer_hooks, o);
    }
    wl_display_roundtrip(g.dpy);

    /* watchdog: if the surfaces do not come up, the wallpaper still changes */
    double boot = now_ms();
    while (n_ready < g.n_outputs && now_ms() - boot < 2500) {
        wl_display_dispatch_pending(g.dpy);
        struct pollfd pf = { .fd = wl_display_get_fd(g.dpy), .events = POLLIN };
        if (poll(&pf, 1, 20) > 0) wl_display_dispatch(g.dpy);
    }
    if (n_ready == 0) { fail(newimg, "no layer surface was configured in 2.5 s"); return 1; }

    started = 1;
    started_ms = now_ms();
    int swapped = 0;

    for (;;) {
        double el = now_ms() - started_ms;

        if (!swapped && el >= 130) {
            swap_awww(newimg);
            swapped = 1;
        }
        double t = el / g_duration_ms;
        if (t > 1.0) t = 1.0;
        double fade;
        if (el < 130) fade = el / 130.0;                 /* in: over identical old */
        else if (t < 1.0) fade = 1.0;
        else {
            fade = 1.0 - (el - g_duration_ms) / 130.0;   /* out: over the new */
            if (fade <= 0.0) break;
        }

        /* the globals render() reads */
        g_fade = (float)fade;

        render_all();
        wl_display_flush(g.dpy);

        struct pollfd pf = { .fd = wl_display_get_fd(g.dpy), .events = POLLIN };
        int pr = poll(&pf, 1, 8);
        if (pr > 0) wl_display_dispatch(g.dpy);
        else wl_display_dispatch_pending(g.dpy);
    }

    if (swap_pid > 0) waitpid(swap_pid, NULL, 0);
    return 0;
}
