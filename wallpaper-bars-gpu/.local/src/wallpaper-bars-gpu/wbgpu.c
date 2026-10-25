/*
 * wallpaper-bars-gpu -- cava spectrum bars drawn on the GPU.
 *
 * A wlr-layer-shell surface per output, fullscreen, on the Bottom layer, that
 * runs ONE fullscreen fragment shader: bar geometry, rounded corners, glow
 * falloff and the wallpaper-sampled colours are all computed per pixel on the
 * GPU. The CPU only feeds 128 smoothed levels and, when the wallpaper changes,
 * one texture upload.
 *
 * Replaces the Noctalia desktop widget `computing/wallpaper-bars`, whose ~1400
 * translucent ui.box nodes per output cost cairo ~1 core of CPU raster time.
 *
 *   cava (raw 0..1000 ascii) --> levels texture --> shader --> layer surface
 *
 * Build: make        Install: make install
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
#include <limits.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>

#include <wayland-client.h>
#include <wayland-egl.h>
#include "wlr-layer-shell-unstable-v1-client-protocol.h"

#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GLES3/gl3.h>

#define WALL_TEX_W 1024
#define WALL_TEX_H 576

/* ------------------------------------------------------------------ config */

static int    cfg_bands      = 128;
static int    cfg_feed       = 128;    /* bands cava delivers                */
static double cfg_gap        = 1.5;
static double cfg_radius     = 4.0;
static double cfg_opacity    = 0.22;   /* widget bar_opacity                 */
static double cfg_blur       = 1.0;    /* widget blur -> halo layer count    */
static double cfg_smooth_ms  = 165.0;  /* widget smoothing                   */
static double cfg_idle_ms    = 6000.0;
static double cfg_sat        = 2.8;    /* widget saturation                  */
static double cfg_lift       = 0.18;   /* widget brightness                  */
static double cfg_minlight   = 0.40;   /* widget min_light                   */
static char   cfg_settings[PATH_MAX];  /* noctalia settings.toml (per-output bands) */
static char   cfg_cava_conf[PATH_MAX];
static char   cfg_wallpaper[PATH_MAX];
static char   cfg_only_output[64];
static int    cfg_demo;

static void logmsg(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
static void logmsg(const char *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    fprintf(stderr, "wallpaper-bars-gpu: ");
    vfprintf(stderr, fmt, ap);
    fputc('\n', stderr);
    va_end(ap);
}

static double now_ms(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec * 1000.0 + ts.tv_nsec / 1e6;
}

/* -------------------------------------------------------------- wayland */

static struct wl_display *wl_dpy;
static struct wl_registry *wl_reg;
static struct wl_compositor *wl_comp;
static struct zwlr_layer_shell_v1 *wl_shell;

static EGLDisplay egl_dpy;
static EGLContext egl_ctx;
static EGLConfig  egl_cfg;

static GLuint prog, vao;
static GLuint tex_levels, tex_wall;
static GLint u_res, u_levels, u_wall, u_n, u_feed, u_gap, u_radius, u_fade;
static GLint u_opacity, u_blur, u_layers, u_sat, u_lift, u_minlight;
static int ge_ready;

struct output {
    struct wl_output *wl;
    char name[64];
    int32_t x, y, w, h;
    struct wl_surface *surf;
    struct zwlr_layer_surface_v1 *ls;
    struct wl_egl_window *win;
    EGLSurface esurf;
    int configured;
    int bands;              /* 0 = unknown, resolved at render time */
    struct output *next;
};

static struct output *outputs;

static int bands_for_output(const char *name);   /* settings.toml, defined below */

/* --------------------------------------------------------------- shaders */

static const char *VS_SRC =
    "#version 300 es\n"
    "void main() {\n"
    "  vec2 p = vec2((gl_VertexID << 1) & 2, gl_VertexID & 2);\n"
    "  gl_Position = vec4(p * 2.0 - 1.0, 0.0, 1.0);\n"
    "}\n";

static const char *FS_SRC =
    "#version 300 es\n"
    "precision highp float;\n"
    "uniform vec2  u_res;\n"
    "uniform sampler2D u_levels;   // feed-width levels (r = 0..1)\n"
    "uniform sampler2D u_wall;\n"
    "uniform int   u_n;            // bands on THIS output (widget setting)\n"
    "uniform int   u_feed;         // bands in the cava feed\n"
    "uniform float u_gap;\n"
    "uniform float u_radius;\n"
    "uniform float u_blur;         // widget \"blur\" 0..1 -> halo layers\n"
    "uniform float u_opacity;      // widget bar_opacity\n"
    "uniform float u_sat;\n"
    "uniform float u_lift;\n"
    "uniform float u_minlight;\n"
    "uniform float u_fade;\n"
    "uniform int   u_layers;\n"
    "out vec4 fragColor;\n"
    "\n"
    "vec3 rgb2hsv(vec3 c) {\n"
    "  float mx = max(max(c.r, c.g), c.b);\n"
    "  float mn = min(min(c.r, c.g), c.b);\n"
    "  float d = mx - mn;\n"
    "  float h = 0.0;\n"
    "  if (d > 1e-6) {\n"
    "    if (mx == c.r) h = mod((c.g - c.b) / d, 6.0);\n"
    "    else if (mx == c.g) h = (c.b - c.r) / d + 2.0;\n"
    "    else h = (c.r - c.g) / d + 4.0;\n"
    "    h /= 6.0;\n"
    "  }\n"
    "  return vec3(h, mx > 1e-6 ? d / mx : 0.0, mx);\n"
    "}\n"
    "\n"
    "vec3 hsv2rgb(vec3 hsv) {\n"
    "  float i = floor(hsv.x * 6.0);\n"
    "  float f = hsv.x * 6.0 - i;\n"
    "  float p = hsv.z * (1.0 - hsv.y);\n"
    "  float q = hsv.z * (1.0 - f * hsv.y);\n"
    "  float t = hsv.z * (1.0 - (1.0 - f) * hsv.y);\n"
    "  int k = int(mod(i, 6.0));\n"
    "  if (k == 0) return vec3(hsv.z, t, p);\n"
    "  if (k == 1) return vec3(q, hsv.z, p);\n"
    "  if (k == 2) return vec3(p, hsv.z, t);\n"
    "  if (k == 3) return vec3(p, q, hsv.z);\n"
    "  if (k == 4) return vec3(t, p, hsv.z);\n"
    "  return vec3(hsv.z, p, q);\n"
    "}\n"
    "\n"
    "void main() {\n"
    "  float barW = u_res.x / float(u_n);\n"
    "  float idx  = floor(gl_FragCoord.x / barW);\n"
    "  float lx   = gl_FragCoord.x - (idx + 0.5) * barW;\n"
    "\n"
    "  /* the widget spreads a feed wider than its own band count over the spectrum */\n"
    "  int src = int(idx);\n"
    "  if (u_feed != u_n) {\n"
    "    src = int(clamp(floor((idx + 0.5) / float(u_n) * float(u_feed)),\n"
    "                    0.0, float(u_feed - 1)));\n"
    "  }\n"
    "  float lvl = texelFetch(u_levels, ivec2(src, 0), 0).r;\n"
    "\n"
    "  /* ---- widget geometry: MIN_BAR + level * (BAR_MAX - MIN_BAR) ---- */\n"
    "  float minBar  = max(2.0, u_res.y * 0.004);\n"
    "  float vspread = u_res.y * 0.09 * u_blur;\n"
    "  float barMax  = max(minBar, u_res.y - vspread);\n"
    "  float h       = minBar + lvl * max(0.0, barMax - minBar);\n"
    "\n"
    "  float halfBar   = max(0.5, (barW - u_gap) * 0.5);\n"
    "  float coreHalf  = max(0.5, halfBar * (0.45 - 0.32 * u_blur));\n"
    "  float haloExtra = barW * 1.5 * u_blur;\n"
    "\n"
    "  /* distance outside the solid core, normalised like the widget's rings */\n"
    "  float dx = max(abs(lx) - coreHalf, 0.0);\n"
    "  float dy = max(gl_FragCoord.y - h, 0.0);\n"
    "  float t;\n"
    "  if (haloExtra > 0.5 || vspread > 0.5) {\n"
    "    t = max(dx / max(haloExtra, 1e-3), dy / max(vspread, 1e-3));\n"
    "  } else {\n"
    "    t = (dx > 0.0 || dy > 0.0) ? 1.0 : 0.0;\n"
    "  }\n"
    "\n"
    "  /* ---- the widget's nested translucent capsules, composited into one alpha ----\n"
    "   * layer j covers ring t <= j/L; its own alpha is solved so the VISIBLE alpha at\n"
    "   * ring j equals coreAlpha * exp(-4 (j/L)^2) -- exactly what the Luau does. */\n"
    "  float coreAlpha = u_opacity * (1.0 - 0.45 * u_blur);\n"
    "  float L = float(max(u_layers, 1));\n"
    "  float trans = 1.0;\n"
    "  for (int j = 0; j <= 12; j++) {\n"
    "    if (j > u_layers) break;\n"
    "    float t0 = float(j) / L;\n"
    "    if (t > t0 + 1e-4) continue;\n"
    "    float pj  = coreAlpha * exp(-4.0 * t0 * t0);\n"
    "    float t1  = float(j + 1) / L;\n"
    "    float pj1 = (j == u_layers) ? 0.0 : coreAlpha * exp(-4.0 * t1 * t1);\n"
    "    float a   = (j == 0) ? coreAlpha : (pj - pj1) / max(1.0 - pj1, 1e-4);\n"
    "    trans *= (1.0 - clamp(a, 0.0, 1.0));\n"
    "  }\n"
    "  float alpha = (1.0 - trans) * u_fade;\n"
    "\n"
    "  /* ---- colour: wallpaper pixel behind this bar's tip, tinted like the widget ---- */\n"
    "  vec2 walluv = vec2((idx + 0.5) / float(u_n), clamp(1.0 - lvl, 0.0, 1.0));\n"
    "  vec3 col = texture(u_wall, walluv).rgb;\n"
    "  vec3 hsv = rgb2hsv(col);\n"
    "  hsv.y = clamp(hsv.y * u_sat, 0.0, 1.0);\n"
    "  hsv.z = clamp(hsv.z + (1.0 - hsv.z) * u_lift, 0.0, 1.0);\n"
    "  hsv.z = max(hsv.z, u_minlight);\n"
    "  col = hsv2rgb(hsv);\n"
    "\n"
    "  if (alpha < 0.003) discard;\n"
    "  fragColor = vec4(col * alpha, alpha);\n"
    "}\n";

static GLuint compile(GLenum type, const char *src)
{
    GLuint s = glCreateShader(type);
    glShaderSource(s, 1, &src, NULL);
    glCompileShader(s);
    GLint ok = 0;
    glGetShaderiv(s, GL_COMPILE_STATUS, &ok);
    if (!ok) {
        char buf[4096];
        glGetShaderInfoLog(s, sizeof buf, NULL, buf);
        logmsg("shader compile failed: %s", buf);
        exit(1);
    }
    return s;
}

static void gpu_init(void)
{
    GLuint vs = compile(GL_VERTEX_SHADER, VS_SRC);
    GLuint fs = compile(GL_FRAGMENT_SHADER, FS_SRC);
    prog = glCreateProgram();
    glAttachShader(prog, vs);
    glAttachShader(prog, fs);
    glLinkProgram(prog);
    GLint ok = 0;
    glGetProgramiv(prog, GL_LINK_STATUS, &ok);
    if (!ok) {
        char buf[4096];
        glGetProgramInfoLog(prog, sizeof buf, NULL, buf);
        logmsg("program link failed: %s", buf);
        exit(1);
    }
    glDeleteShader(vs);
    glDeleteShader(fs);

    u_res      = glGetUniformLocation(prog, "u_res");
    u_levels   = glGetUniformLocation(prog, "u_levels");
    u_wall     = glGetUniformLocation(prog, "u_wall");
    u_n        = glGetUniformLocation(prog, "u_n");
    u_feed     = glGetUniformLocation(prog, "u_feed");
    u_gap      = glGetUniformLocation(prog, "u_gap");
    u_radius   = glGetUniformLocation(prog, "u_radius");
    u_fade     = glGetUniformLocation(prog, "u_fade");
    u_opacity  = glGetUniformLocation(prog, "u_opacity");
    u_blur     = glGetUniformLocation(prog, "u_blur");
    u_layers   = glGetUniformLocation(prog, "u_layers");
    u_sat      = glGetUniformLocation(prog, "u_sat");
    u_lift     = glGetUniformLocation(prog, "u_lift");
    u_minlight = glGetUniformLocation(prog, "u_minlight");

    glGenVertexArrays(1, &vao);

    glGenTextures(1, &tex_levels);
    glBindTexture(GL_TEXTURE_2D, tex_levels);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_R32F, cfg_feed, 1, 0, GL_RED, GL_FLOAT, NULL);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);

    glGenTextures(1, &tex_wall);
    glBindTexture(GL_TEXTURE_2D, tex_wall);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, WALL_TEX_W, WALL_TEX_H, 0,
                 GL_RGBA, GL_UNSIGNED_BYTE, NULL);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);

    ge_ready = 1;
}

/* ------------------------------------------------------------- wallpaper */

static time_t wall_mtime = -1;

static int read_fd_all(int fd, unsigned char **out, size_t *outlen)
{
    size_t cap = 1 << 20, len = 0;
    unsigned char *buf = malloc(cap);
    if (!buf)
        return -1;
    for (;;) {
        if (len == cap) {
            cap *= 2;
            unsigned char *nb = realloc(buf, cap);
            if (!nb) { free(buf); return -1; }
            buf = nb;
        }
        ssize_t n = read(fd, buf + len, cap - len);
        if (n < 0) {
            if (errno == EINTR)
                continue;
            break;
        }
        if (n == 0)
            break;
        len += (size_t)n;
    }
    *out = buf;
    *outlen = len;
    return 0;
}

/* Decode the wallpaper to a small RGBA buffer with magick (a dependency the
 * old plugin already required) and upload it. Sampled in the shader, so the
 * on-GPU texture can be small without visible loss. */
static void wallpaper_reload(void)
{
    char resolved[PATH_MAX];
    if (!realpath(cfg_wallpaper, resolved))
        return;
    struct stat st;
    if (stat(resolved, &st) != 0)
        return;
    if (st.st_mtime == wall_mtime)
        return;

    int pf[2];
    if (pipe(pf) != 0)
        return;
    pid_t pid = fork();
    if (pid == 0) {
        dup2(pf[1], STDOUT_FILENO);
        close(pf[0]);
        close(pf[1]);
        int devnull = open("/dev/null", O_WRONLY);
        if (devnull >= 0)
            dup2(devnull, STDERR_FILENO);
        char size[64];
        snprintf(size, sizeof size, "%dx%d!", WALL_TEX_W, WALL_TEX_H);
        execlp("magick", "magick", resolved, "-resize", size, "-depth", "8",
               "rgba:-", (char *)NULL);
        _exit(127);
    }
    close(pf[1]);
    unsigned char *buf = NULL;
    size_t len = 0;
    read_fd_all(pf[0], &buf, &len);
    close(pf[0]);
    int status = 0;
    waitpid(pid, &status, 0);

    size_t want = (size_t)WALL_TEX_W * WALL_TEX_H * 4;
    if (len < want) {
        logmsg("wallpaper decode failed (%zu/%zu bytes)", len, want);
        free(buf);
        return;
    }
    glBindTexture(GL_TEXTURE_2D, tex_wall);
    glTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, WALL_TEX_W, WALL_TEX_H,
                    GL_RGBA, GL_UNSIGNED_BYTE, buf);
    free(buf);
    wall_mtime = st.st_mtime;
    logmsg("wallpaper loaded: %s", resolved);
}

/* ------------------------------------------------------------------ cava */

static int cava_fd = -1;
static pid_t cava_pid = -1;

static void cava_spawn(void)
{
    int pf[2];
    if (pipe(pf) != 0) {
        logmsg("pipe: %s", strerror(errno));
        exit(1);
    }
    cava_pid = fork();
    if (cava_pid == 0) {
        dup2(pf[1], STDOUT_FILENO);
        close(pf[0]);
        close(pf[1]);
        int devnull = open("/dev/null", O_WRONLY);
        if (devnull >= 0)
            dup2(devnull, STDERR_FILENO);
        execlp("cava", "cava", "-p", cfg_cava_conf, (char *)NULL);
        _exit(127);
    }
    close(pf[1]);
    cava_fd = pf[0];
    fcntl(cava_fd, F_SETFL, fcntl(cava_fd, F_GETFL) | O_NONBLOCK);
    fcntl(cava_fd, F_SETFD, FD_CLOEXEC);
    logmsg("cava spawned (pid %d)", (int)cava_pid);
}

static float targets[1024];
static float levels[1024];

/* raw ascii cava: "12;34;56;...;\n", values 0..1000 */
static void cava_parse_line(char *line, int len)
{
    int got = 0;
    char *p = line, *end = line + len;
    while (p < end && got < 1024) {
        while (p < end && (*p == ';' || *p == ' '))
            p++;
        if (p >= end)
            break;
        char *nl = p;
        while (nl < end && *nl != ';')
            nl++;
        *nl = '\0';
        int v = atoi(p);
        targets[got++] = (float)(v < 0 ? 0 : (v > 1000 ? 1000 : v)) / 1000.0f;
        p = nl + 1;
    }
    if (getenv("WBGPU_DEBUG_CAVA")) {
        float mx = 0.f;
        for (int i = 0; i < got; i++)
            if (targets[i] > mx) mx = targets[i];
        logmsg("cava line: %d values, max %.3f, head '%s'", got, mx, line);
    }
    if (got == 0)
        return;
    /* resample the feed onto our band count (feed == bands is the norm) */
    if (got != cfg_bands) {
        float src[1024];
        memcpy(src, targets, sizeof(float) * (size_t)got);
        for (int i = 0; i < cfg_bands; i++) {
            int s = (int)(((i + 0.5) / cfg_bands) * got);
            if (s < 0) s = 0;
            if (s >= got) s = got - 1;
            targets[i] = src[s];
        }
    }
}

static char cava_buf[1 << 16];
static size_t cava_buflen;

/* returns number of complete lines consumed */
static int cava_pump(void)
{
    int lines = 0;
    for (;;) {
        if (cava_buflen > sizeof cava_buf - 4096)
            cava_buflen = 0;
        ssize_t n = read(cava_fd, cava_buf + cava_buflen, sizeof cava_buf - 1 - cava_buflen);
        if (n < 0) {
            if (errno == EINTR)
                continue;
            break; /* EAGAIN: nothing more pending */
        }
        if (n == 0)
            break;
        cava_buflen += (size_t)n;
        cava_buf[cava_buflen] = '\0';

        char *start = cava_buf, *nl;
        while ((nl = memchr(start, '\n', (size_t)(cava_buf + cava_buflen - start)))) {
            cava_parse_line(start, (int)(nl - start));
            lines++;
            start = nl + 1;
        }
        size_t used = (size_t)(start - cava_buf);
        if (used > 0) {
            memmove(cava_buf, start, cava_buflen - used);
            cava_buflen -= used;
        }
    }
    return lines;
}

/* --------------------------------------------------------------- surfaces */

static void render(struct output *o);

static void ls_configure(void *data, struct zwlr_layer_surface_v1 *ls,
                         uint32_t serial, uint32_t w, uint32_t h)
{
    struct output *o = data;
    zwlr_layer_surface_v1_ack_configure(ls, serial);
    if (w == 0 || h == 0)
        return;
    if (o->configured && (int)w == o->w && (int)h == o->h && o->win) {
        render(o);
        return;
    }
    if (o->win)
        wl_egl_window_resize(o->win, (int)w, (int)h, 0, 0);
    else {
        o->win = wl_egl_window_create(o->surf, (int)w, (int)h);
        if (!o->win) {
            logmsg("%s: wl_egl_window_create failed", o->name);
            return;
        }
        o->esurf = eglCreateWindowSurface(egl_dpy, egl_cfg, (EGLNativeWindowType)o->win, NULL);
        if (o->esurf == EGL_NO_SURFACE) {
            logmsg("%s: eglCreateWindowSurface failed (0x%x)", o->name, eglGetError());
            return;
        }
    }
    o->w = (int32_t)w;
    o->h = (int32_t)h;
    o->configured = 1;
    logmsg("%s: %dx%d", o->name, o->w, o->h);
    render(o);
}

static void ls_closed(void *data, struct zwlr_layer_surface_v1 *ls)
{
    (void)data;
    zwlr_layer_surface_v1_destroy(ls);
    logmsg("compositor closed a layer surface; exiting");
    exit(0);
}

static const struct zwlr_layer_surface_v1_listener ls_listener = {
    .configure = ls_configure,
    .closed = ls_closed,
};

static void create_surface(struct output *o)
{
    if (cfg_only_output[0] && strcmp(cfg_only_output, o->name) != 0)
        return;
    logmsg("create_surface for output '%s'", o->name);
    o->surf = wl_compositor_create_surface(wl_comp);
    if (!o->surf)
        return;
    /* click-through: an empty input region means the layer never eats input */
    struct wl_region *empty = wl_compositor_create_region(wl_comp);
    wl_surface_set_input_region(o->surf, empty);
    wl_region_destroy(empty);

    o->ls = zwlr_layer_shell_v1_get_layer_surface(wl_shell, o->surf, o->wl,
                                                  ZWLR_LAYER_SHELL_V1_LAYER_BOTTOM,
                                                  "wallpaper-bars-gpu");
    zwlr_layer_surface_v1_set_anchor(o->ls, ZWLR_LAYER_SURFACE_V1_ANCHOR_TOP |
                                             ZWLR_LAYER_SURFACE_V1_ANCHOR_BOTTOM |
                                             ZWLR_LAYER_SURFACE_V1_ANCHOR_LEFT |
                                             ZWLR_LAYER_SURFACE_V1_ANCHOR_RIGHT);
    zwlr_layer_surface_v1_set_size(o->ls, 0, 0);
    zwlr_layer_surface_v1_set_exclusive_zone(o->ls, 0);
    zwlr_layer_surface_v1_set_keyboard_interactivity(o->ls, 0);
    zwlr_layer_surface_v1_add_listener(o->ls, &ls_listener, o);
    wl_surface_commit(o->surf);
}

/* ------------------------------------------------------------------ input */

static void out_geometry(void *data, struct wl_output *wl, int32_t x, int32_t y,
                         int32_t pw, int32_t ph, int32_t subpixel,
                         const char *make, const char *model, int32_t transform)
{
    (void)wl; (void)pw; (void)ph; (void)subpixel; (void)make; (void)model; (void)transform;
    struct output *o = data;
    o->x = x;
    o->y = y;
}

static void out_mode(void *data, struct wl_output *wl, uint32_t flags,
                     int32_t w, int32_t h, int32_t refresh)
{
    (void)wl; (void)flags; (void)refresh;
    struct output *o = data;
    if (w > 0 && h > 0) {
        o->w = w;
        o->h = h;
    }
}

static void out_done(void *data, struct wl_output *wl) { (void)data; (void)wl; }
static void out_scale(void *data, struct wl_output *wl, int32_t f) { (void)data; (void)wl; (void)f; }
static void out_name(void *data, struct wl_output *wl, const char *name)
{
    (void)wl;
    struct output *o = data;
    snprintf(o->name, sizeof o->name, "%s", name);
}
static void out_desc(void *data, struct wl_output *wl, const char *d) { (void)data; (void)wl; (void)d; }

static const struct wl_output_listener out_listener = {
    .geometry = out_geometry,
    .mode = out_mode,
    .done = out_done,
    .scale = out_scale,
    .name = out_name,
    .description = out_desc,
};

static void reg_global(void *data, struct wl_registry *reg, uint32_t name,
                       const char *iface, uint32_t ver)
{
    (void)data;
    if (strcmp(iface, wl_compositor_interface.name) == 0) {
        wl_comp = wl_registry_bind(reg, name, &wl_compositor_interface, 4);
    } else if (strcmp(iface, zwlr_layer_shell_v1_interface.name) == 0) {
        wl_shell = wl_registry_bind(reg, name, &zwlr_layer_shell_v1_interface, 1);
    } else if (strcmp(iface, wl_output_interface.name) == 0) {
        uint32_t v = ver < 4 ? ver : 4;
        struct output *o = calloc(1, sizeof *o);
        o->wl = wl_registry_bind(reg, name, &wl_output_interface, v);
        o->next = outputs;
        outputs = o;
        wl_output_add_listener(o->wl, &out_listener, o);
    }
}

static void reg_remove(void *data, struct wl_registry *reg, uint32_t name)
{
    (void)data; (void)reg; (void)name;
}

static const struct wl_registry_listener reg_listener = {
    .global = reg_global,
    .global_remove = reg_remove,
};

/* ------------------------------------------------------------------- draw */

static float fade = 1.0f;
static double idle_acc, fade_target = 1.0;

static void render(struct output *o)
{
    if (!ge_ready || !o->configured || !o->esurf)
        return;
    if (eglMakeCurrent(egl_dpy, o->esurf, o->esurf, egl_ctx) == EGL_FALSE) {
        logmsg("%s: eglMakeCurrent failed (0x%x)", o->name, eglGetError());
        return;
    }
    int32_t w = o->w, h = o->h;
    if (w <= 0 || h <= 0)
        return;
    if (o->bands <= 0)
        o->bands = bands_for_output(o->name);

    glViewport(0, 0, w, h);
    glDisable(GL_SCISSOR_TEST);
    glClearColor(0.f, 0.f, 0.f, 0.f);
    glClear(GL_COLOR_BUFFER_BIT);

    glEnable(GL_BLEND);
    glBlendFunc(GL_ONE, GL_ONE_MINUS_SRC_ALPHA); /* premultiplied */
    glUseProgram(prog);
    glBindVertexArray(vao);

    glUniform2f(u_res, (float)w, (float)h);
    glUniform1i(u_n, o->bands > 0 ? o->bands : cfg_bands);
    glUniform1i(u_feed, cfg_feed);
    glUniform1f(u_gap, (float)cfg_gap);
    glUniform1f(u_radius, (float)cfg_radius);
    glUniform1f(u_fade, fade);
    glUniform1f(u_opacity, (float)cfg_opacity);
    glUniform1f(u_blur, (float)cfg_blur);
    glUniform1i(u_layers, (int)(4.0 + 6.0 * cfg_blur));
    glUniform1f(u_sat, (float)cfg_sat);
    glUniform1f(u_lift, (float)cfg_lift);
    glUniform1f(u_minlight, (float)cfg_minlight);

    glActiveTexture(GL_TEXTURE0);
    glBindTexture(GL_TEXTURE_2D, tex_levels);
    glTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, cfg_feed, 1, GL_RED, GL_FLOAT, levels);
    glUniform1i(u_levels, 0);

    glActiveTexture(GL_TEXTURE1);
    glBindTexture(GL_TEXTURE_2D, tex_wall);
    glUniform1i(u_wall, 1);

    glDrawArrays(GL_TRIANGLES, 0, 3);

    static int sel_frames;
    if (getenv("WBGPU_SELFTEST") && ++sel_frames > 45) {
        unsigned char *row = calloc((size_t)w * 4, 1);
        glReadPixels(0, 3, w, 1, GL_RGBA, GL_UNSIGNED_BYTE, row);
        int runs = 0, inside = 0, maxrun = 0, cur = 0;
        for (int x = 0; x < w; x++) {
            int on = row[x * 4 + 3] > 25;
            if (on && !inside) { runs++; cur = 0; }
            if (on) { cur++; if (cur > maxrun) maxrun = cur; }
            inside = on;
        }
        logmsg("%s: selftest row A>25 -> %d bands, widest run %d px, width %d",
               o->name, runs, maxrun, w);
        /* glow / tip profile at the middle of the widest band */
        int nb = o->bands > 0 ? o->bands : cfg_bands;
        int cx = (int)((nb / 2 + 0.5) * (double)w / nb);   /* centre of one bar, not a gap */
        for (int y = 0; y < h; y += h / 12) {
            unsigned char px[4] = {0};
            glReadPixels(cx, y, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, px);
            logmsg("  y=%4d alpha=%3d rgb=%3d,%3d,%3d", y, px[3], px[0], px[1], px[2]);
        }
        free(row);
        exit(0);
    }
    if (getenv("WBGPU_DEBUG_PIXELS")) {
        unsigned char px[4] = {0, 0, 0, 0};
        glReadPixels(w / 2, 4, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, px);
        logmsg("%s: readback bottom-centre rgba=%u,%u,%u,%u  err=0x%x",
               o->name, px[0], px[1], px[2], px[3], glGetError());
    }
    eglSwapBuffers(egl_dpy, o->esurf);
}

static void render_all(void)
{
    for (struct output *o = outputs; o; o = o->next)
        render(o);
}

/* ------------------------------------------------------------------- main */

static void usage(const char *argv0)
{
    printf("usage: %s [options]\n"
           "  --bands N          bars across the screen (default: per-output widget setting)\n"
           "  --gap PX           gap between bars (default 1.5)\n"
           "  --radius PX        bar corner radius (default 4)\n"
           "  --opacity F        peak bar opacity (default: settings.toml bar_opacity)\n"
           "  --blur F           halo strength 0..1, the widget's blur (default 1.0)\n"
           "  --smooth MS        level smoothing time constant (default 45)\n"
           "  --idle MS          fade out after this much silence (default 6000)\n"
           "  --cava-conf PATH   cava config (default $XDG_CONFIG_HOME/wallpaper-bars-gpu/cava.conf)\n"
           "  --wallpaper PATH   wallpaper image (default ~/.config/backgrounds/current-wallpaper)\n"
           "  --output NAME      only draw on this connector (default: every output)\n"
           "  --saturation F     saturation boost on the sampled wallpaper px\n"
           "  --lift F           lift the sampled colour toward white\n"
           "  --min-light F      floor on the sampled colour value\n"
           "  --demo             synthesize levels instead of reading cava (visual test)\n"
           "  --help\n", argv0);
}

static void parse_args(int argc, char **argv)
{
    const char *home = getenv("HOME");
    const char *xdg = getenv("XDG_CONFIG_HOME");
    snprintf(cfg_cava_conf, sizeof cfg_cava_conf, "%s/%s",
             xdg ? xdg : "", "wallpaper-bars-gpu/cava.conf");
    if (!xdg)
        snprintf(cfg_cava_conf, sizeof cfg_cava_conf, "%s/.config/wallpaper-bars-gpu/cava.conf", home);
    snprintf(cfg_wallpaper, sizeof cfg_wallpaper, "%s/.config/backgrounds/current-wallpaper", home);
    {
        const char *st = getenv("XDG_STATE_HOME");
        if (st && *st)
            snprintf(cfg_settings, sizeof cfg_settings, "%s/noctalia/settings.toml", st);
        else
            snprintf(cfg_settings, sizeof cfg_settings, "%s/.local/state/noctalia/settings.toml", home);
    }

    for (int i = 1; i < argc; i++) {
        const char *a = argv[i];
        const char *v = (i + 1 < argc) ? argv[i + 1] : NULL;
        if (!strcmp(a, "--help") || !strcmp(a, "-h")) {
            usage(argv[0]);
            exit(0);
        } else if (!strcmp(a, "--bands") && v) { cfg_bands = atoi(v); i++; }
        else if (!strcmp(a, "--gap") && v) { cfg_gap = atof(v); i++; }
        else if (!strcmp(a, "--radius") && v) { cfg_radius = atof(v); i++; }
        else if (!strcmp(a, "--opacity") && v) { cfg_opacity = atof(v); i++; }
        else if (!strcmp(a, "--blur") && v) { cfg_blur = atof(v); i++; }
        else if (!strcmp(a, "--smooth") && v) { cfg_smooth_ms = atof(v); i++; }
        else if (!strcmp(a, "--idle") && v) { cfg_idle_ms = atof(v); i++; }
        else if (!strcmp(a, "--cava-conf") && v) {
            snprintf(cfg_cava_conf, sizeof cfg_cava_conf, "%s", v); i++;
        } else if (!strcmp(a, "--wallpaper") && v) {
            snprintf(cfg_wallpaper, sizeof cfg_wallpaper, "%s", v); i++;
        } else if (!strcmp(a, "--saturation") && v) { cfg_sat = atof(v); i++; }
        else if (!strcmp(a, "--lift") && v) { cfg_lift = atof(v); i++; }
        else if (!strcmp(a, "--min-light") && v) { cfg_minlight = atof(v); i++; }
        else if (!strcmp(a, "--demo")) {
            cfg_demo = 1;
        } else if (!strcmp(a, "--output") && v) {
            snprintf(cfg_only_output, sizeof cfg_only_output, "%s", v); i++;
        } else {
            logmsg("unknown argument: %s", a);
            usage(argv[0]);
            exit(1);
        }
    }
    if (cfg_bands < 8) cfg_bands = 8;
    if (cfg_bands > 1024) cfg_bands = 1024;
}

/* The Noctalia widget took its look from settings.toml: plugin-level bar_opacity,
 * saturation and smoothing, plus a per-instance band count (this box runs 64 bands
 * on the TV and 128 on the laptop panel). Read the same values so the GPU renderer
 * draws what the widget drew instead of guessing. */
static char map_out[8][64];
static int  map_bands[8];
static int  map_n;

static int bands_for_output(const char *name)
{
    for (int i = 0; i < map_n; i++)
        if (strcmp(map_out[i], name) == 0)
            return map_bands[i];
    return cfg_bands;
}

static char *trim(char *t)
{
    while (*t == ' ' || *t == '\t')
        t++;
    char *e = t + strlen(t);
    while (e > t && (e[-1] == '\n' || e[-1] == '\r' || e[-1] == ' '))
        *--e = '\0';
    return t;
}

static void load_widget_settings(void)
{
    FILE *f = fopen(cfg_settings, "r");
    if (!f) {
        logmsg("no %s; using built-in look", cfg_settings);
        return;
    }
    char line[512], section[256] = "";
    char w_out[64] = "";
    int w_isbars = 0;

    while (fgets(line, sizeof line, f)) {
        char *t = trim(line);
        if (!*t || *t == '#')
            continue;
        if (*t == '[') {
            char *e = strchr(t, ']');
            if (!e)
                continue;
            size_t n = (size_t)(e - t - 1);
            if (n >= sizeof section)
                n = sizeof section - 1;
            memcpy(section, t + 1, n);
            section[n] = '\0';
            if (strncmp(section, "desktop_widgets.widget.", 23) == 0 &&
                !strstr(section, ".settings")) {
                w_out[0] = '\0';
                w_isbars = 0;
            }
            continue;
        }
        char *eq = strchr(t, '=');
        if (!eq)
            continue;
        *eq = '\0';
        char *key = trim(t);
        char *val = trim(eq + 1);
        if (val[0] == '"') {
            char *q = strchr(val + 1, '"');
            if (q)
                *q = '\0';
            val++;
        }

        int is_widget = strncmp(section, "desktop_widgets.widget.", 23) == 0;
        int is_settings = strstr(section, ".settings") != NULL;
        int is_plugin = strncmp(section, "plugin_settings.", 16) == 0 &&
                        strstr(section, "wallpaper-bars") != NULL;

        if (is_widget && !is_settings) {
            if (!strcmp(key, "output"))
                snprintf(w_out, sizeof w_out, "%s", val);
            else if (!strcmp(key, "type") && strstr(val, "wallpaper-bars:bars"))
                w_isbars = 1;
        } else if (is_widget && is_settings) {
            if (!strcmp(key, "bands") && w_isbars && w_out[0] && map_n < 8) {
                snprintf(map_out[map_n], sizeof map_out[map_n], "%s", w_out);
                map_bands[map_n] = atoi(val);
                map_n++;
            }
        } else if (is_plugin) {
            if (!strcmp(key, "bar_opacity")) cfg_opacity = atof(val);
            else if (!strcmp(key, "saturation")) cfg_sat = atof(val);
            else if (!strcmp(key, "smoothing")) cfg_smooth_ms = atof(val);
            else if (!strcmp(key, "gap")) cfg_gap = atof(val);
            else if (!strcmp(key, "radius")) cfg_radius = atof(val);
            else if (!strcmp(key, "blur")) cfg_blur = atof(val);
            else if (!strcmp(key, "brightness")) cfg_lift = atof(val);
            else if (!strcmp(key, "min_light")) cfg_minlight = atof(val);
            else if (!strcmp(key, "idle_seconds")) cfg_idle_ms = atof(val) * 1000.0;
        }
    }
    fclose(f);
    for (int i = 0; i < map_n; i++)
        logmsg("bands[%s] = %d", map_out[i], map_bands[i]);
    logmsg("look: opacity=%.2f sat=%.2f blur=%.2f lift=%.2f minlight=%.2f smooth=%.0fms",
           cfg_opacity, cfg_sat, cfg_blur, cfg_lift, cfg_minlight, cfg_smooth_ms);
}

static void egl_boot(void)
{
    egl_dpy = eglGetPlatformDisplay(EGL_PLATFORM_WAYLAND_KHR, wl_dpy, NULL);
    if (egl_dpy == EGL_NO_DISPLAY) {
        logmsg("no EGL display");
        exit(1);
    }
    EGLint major = 0, minor = 0;
    if (!eglInitialize(egl_dpy, &major, &minor)) {
        logmsg("eglInitialize failed (0x%x)", eglGetError());
        exit(1);
    }
    if (!eglBindAPI(EGL_OPENGL_ES_API)) {
        logmsg("eglBindAPI failed");
        exit(1);
    }
    const EGLint cfg_attr[] = {
        EGL_SURFACE_TYPE, EGL_WINDOW_BIT | EGL_PBUFFER_BIT,
        EGL_RENDERABLE_TYPE, EGL_OPENGL_ES3_BIT,
        EGL_RED_SIZE, 8, EGL_GREEN_SIZE, 8, EGL_BLUE_SIZE, 8, EGL_ALPHA_SIZE, 8,
        EGL_NONE,
    };
    EGLint n = 0;
    if (!eglChooseConfig(egl_dpy, cfg_attr, &egl_cfg, 1, &n) || n < 1) {
        logmsg("no matching EGL config");
        exit(1);
    }
    const EGLint ctx_attr[] = { EGL_CONTEXT_CLIENT_VERSION, 3, EGL_NONE };
    egl_ctx = eglCreateContext(egl_dpy, egl_cfg, EGL_NO_CONTEXT, ctx_attr);
    if (egl_ctx == EGL_NO_CONTEXT) {
        logmsg("eglCreateContext failed (0x%x)", eglGetError());
        exit(1);
    }
    logmsg("EGL %d.%d", major, minor);
}

static volatile sig_atomic_t quit;
static void on_signal(int sig) { (void)sig; quit = 1; }

int main(int argc, char **argv)
{
    signal(SIGPIPE, SIG_IGN);
    signal(SIGTERM, on_signal);
    signal(SIGINT, on_signal);
    parse_args(argc, argv);
    load_widget_settings();
    for (int i = 0; i < cfg_bands; i++) {
        levels[i] = 0.f;
        targets[i] = 0.f;
    }

    wl_dpy = wl_display_connect(NULL);
    if (!wl_dpy) {
        logmsg("cannot connect to WAYLAND_DISPLAY");
        return 1;
    }
    wl_reg = wl_display_get_registry(wl_dpy);
    wl_registry_add_listener(wl_reg, &reg_listener, NULL);
    wl_display_roundtrip(wl_dpy);
    wl_display_roundtrip(wl_dpy);
    if (!wl_comp || !wl_shell) {
        logmsg("compositor lacks wl_compositor / zwlr_layer_shell_v1");
        return 1;
    }

    egl_boot();
    /* one context is enough: each surface is made current for its own draw */
    if (!eglMakeCurrent(egl_dpy, EGL_NO_SURFACE, EGL_NO_SURFACE, egl_ctx)) {
        /* no surfaceless support: park the context on a 1x1 pbuffer so
         * textures can be created and uploaded before any surface exists */
        const EGLint pb[] = { EGL_WIDTH, 1, EGL_HEIGHT, 1, EGL_NONE };
        EGLSurface tmp = eglCreatePbufferSurface(egl_dpy, egl_cfg, pb);
        if (tmp == EGL_NO_SURFACE || !eglMakeCurrent(egl_dpy, tmp, tmp, egl_ctx)) {
            logmsg("cannot make an EGL context current (0x%x)", eglGetError());
            return 1;
        }
    }
    gpu_init();
    logmsg("GL %s", glGetString(GL_RENDERER));
    wallpaper_reload();

    for (struct output *o = outputs; o; o = o->next)
        create_surface(o);
    wl_display_roundtrip(wl_dpy);

    /* Fallback: outputs may have been announced after our first roundtrip. */
    if (!outputs) {
        logmsg("no wl_output yet, retrying");
        wl_display_roundtrip(wl_dpy);
    }

    if (!cfg_demo)
        cava_spawn();

    double last = now_ms();
    double last_wall_check = 0;
    int fading = 0;
    if (access(cfg_cava_conf, R_OK) != 0)
        logmsg("warning: cava config %s unreadable", cfg_cava_conf);

    while (!quit) {
        double t0 = now_ms();
        double timeout = 1000; /* idle wake for the wallpaper check */
        if (fading)
            timeout = 16;
        if (cfg_demo) {
            double t = t0 / 1000.0;
            for (int i = 0; i < cfg_bands; i++)
                targets[i] = (float)(0.5 + 0.45 * sin(t * 2.0 + i * 0.22)
                                     * sin(t * 0.7 + i * 0.05));
            timeout = 16;
        }

        while (wl_display_prepare_read(wl_dpy) != 0)
            wl_display_dispatch_pending(wl_dpy);
        wl_display_flush(wl_dpy);

        struct pollfd pf[2] = {
            { .fd = wl_display_get_fd(wl_dpy), .events = POLLIN },
            { .fd = cava_fd, .events = POLLIN },
        };
        int nfd = cfg_demo ? 1 : 2;
        int pr = poll(pf, (nfds_t)nfd, (int)timeout);
        if (pr < 0 && errno != EINTR) {
            wl_display_cancel_read(wl_dpy);
            logmsg("poll: %s", strerror(errno));
            break;
        }
        int dirty = cfg_demo;
        if (pr > 0 && (pf[0].revents & POLLIN)) {
            if (wl_display_read_events(wl_dpy) != 0) {
                logmsg("wayland connection lost");
                break;
            }
            wl_display_dispatch_pending(wl_dpy);
        } else {
            wl_display_cancel_read(wl_dpy);
        }
        if (!cfg_demo && pr > 0 && (pf[1].revents & POLLIN)) {
            if (cava_pump() > 0)
                dirty = 1;
        } else if (!cfg_demo && pr > 0 && (pf[1].revents & (POLLHUP | POLLERR))) {
            logmsg("cava exited; restarting in 1s");
            close(cava_fd);
            cava_fd = -1;
            usleep(1000000);
            cava_spawn();
            continue;
        }

        double t1 = now_ms();
        double dt = t1 - last;
        if (dt > 250) dt = 250;
        last = t1;

        /* smoothing + fade run on every frame we draw */
        if (dirty || fading) {
            float k = cfg_smooth_ms > 0 ? (float)(1.0 - exp(-dt / cfg_smooth_ms)) : 1.f;
            float peak = 0.f;
            for (int i = 0; i < cfg_bands; i++) {
                levels[i] += (targets[i] - levels[i]) * k;
                if (levels[i] > peak)
                    peak = levels[i];
            }
            if (peak < 0.003f)
                idle_acc += dt;
            else
                idle_acc = 0;
            if (idle_acc > cfg_idle_ms)
                fade_target = 0.0;
            else
                fade_target = 1.0;
            fade += (float)(fade_target - fade) * (float)(dt / 220.0);
            if (fade < 0.004f)
                fade = 0.f;
            else if (fade > 0.996f)
                fade = 1.f;

            /* keep ticking only while there is something to see: once fully
             * faded and silent, skip the draw entirely (cava keeps streaming
             * zero lines, which would otherwise force a frame every tick). */
            if (fade > 0.0f)
                render_all();
            fading = (fade_target == 0.0 && fade > 0.0);
        }

        if (t1 - last_wall_check > 1000) {
            last_wall_check = t1;
            wallpaper_reload();
        }
        (void)t0;
    }

    if (cava_fd >= 0)
        close(cava_fd);
    if (cava_pid > 0)
        kill(cava_pid, SIGTERM);
    return 0;
}
