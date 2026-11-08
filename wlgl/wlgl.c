#define _GNU_SOURCE
#include <stdio.h>
#include <stdarg.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <sys/types.h>
#include <sys/wait.h>

#include "wlgl.h"
#include <EGL/eglext.h>

void wlgl_logf(struct wlgl *g, const char *fmt, ...)
{
    if (!g->log) return;
    va_list ap;
    va_start(ap, fmt);
    char buf[1024];
    vsnprintf(buf, sizeof buf, fmt, ap);
    va_end(ap);
    g->log("%s", buf);
}

static void fatal(struct wlgl *g, const char *fmt, ...)
{
    fprintf(stderr, "%s: ", g->prog);
    va_list ap;
    va_start(ap, fmt);
    vfprintf(stderr, fmt, ap);
    va_end(ap);
    fputc('\n', stderr);
    exit(1);
}

/* ------------------------------------------------------------------ inputs */

static void out_geometry(void *data, struct wl_output *wl, int32_t x, int32_t y,
                         int32_t pw, int32_t ph, int32_t subpixel,
                         const char *make, const char *model, int32_t transform)
{
    (void)data; (void)wl; (void)x; (void)y;
    (void)pw; (void)ph; (void)subpixel; (void)make; (void)model; (void)transform;
}

static void out_mode(void *data, struct wl_output *wl, uint32_t flags,
                     int32_t w, int32_t h, int32_t refresh)
{
    (void)wl; (void)flags; (void)refresh;
    struct wlgl_output *o = data;
    if (w > 0 && h > 0) { o->w = w; o->h = h; }
}

static void out_done(void *data, struct wl_output *wl) { (void)data; (void)wl; }
static void out_scale(void *data, struct wl_output *wl, int32_t f) { (void)data; (void)wl; (void)f; }

static void out_name(void *data, struct wl_output *wl, const char *name)
{
    (void)wl;
    struct wlgl_output *o = data;
    snprintf(o->name, sizeof o->name, "%s", name);
}

static void out_desc(void *data, struct wl_output *wl, const char *d) { (void)data; (void)wl; (void)d; }

static const struct wl_output_listener out_listener = {
    .geometry = out_geometry, .mode = out_mode, .done = out_done,
    .scale = out_scale, .name = out_name, .description = out_desc,
};

static void reg_global(void *data, struct wl_registry *reg, uint32_t name,
                       const char *iface, uint32_t ver)
{
    struct wlgl *g = data;
    if (strcmp(iface, wl_compositor_interface.name) == 0) {
        g->comp = wl_registry_bind(reg, name, &wl_compositor_interface, 4);
    } else if (strcmp(iface, zwlr_layer_shell_v1_interface.name) == 0) {
        g->shell = wl_registry_bind(reg, name, &zwlr_layer_shell_v1_interface, 1);
    } else if (strcmp(iface, wl_output_interface.name) == 0) {
        uint32_t v = ver < 4 ? ver : 4;
        size_t sz = g->output_size ? g->output_size : sizeof(struct wlgl_output);
        struct wlgl_output *o = calloc(1, sz);
        if (!o) return;
        o->wl = wl_registry_bind(reg, name, &wl_output_interface, v);
        o->next = g->outputs;
        g->outputs = o;
        g->n_outputs++;
        wl_output_add_listener(o->wl, &out_listener, o);
    }
}

static void reg_remove(void *data, struct wl_registry *reg, uint32_t name)
{ (void)data; (void)reg; (void)name; }

static const struct wl_registry_listener reg_listener = { reg_global, reg_remove };

/* ------------------------------------------------------------------ layers */

static void ls_configure(void *data, struct zwlr_layer_surface_v1 *ls,
                         uint32_t serial, uint32_t w, uint32_t h)
{
    struct wlgl_layer *l = data;
    zwlr_layer_surface_v1_ack_configure(ls, serial);
    if (w == 0 || h == 0) return;
    if (!l->win) {
        l->win = wl_egl_window_create(l->surf, (int)w, (int)h);
        if (!l->win) {
            wlgl_logf(l->g, "wl_egl_window_create failed");
            return;
        }
        l->esurf = eglCreateWindowSurface(l->g->egl_dpy, l->g->egl_cfg,
                                          (EGLNativeWindowType)l->win, NULL);
        if (l->esurf == EGL_NO_SURFACE) {
            wlgl_logf(l->g, "eglCreateWindowSurface failed (0x%x)", eglGetError());
            return;
        }
    } else {
        wl_egl_window_resize(l->win, (int)w, (int)h, 0, 0);
    }
    l->w = (int32_t)w;
    l->h = (int32_t)h;
    l->configured = 1;
    if (l->hooks && l->hooks->configured)
        l->hooks->configured(l);
}

static void ls_closed(void *data, struct zwlr_layer_surface_v1 *ls)
{
    struct wlgl_layer *l = data;
    (void)ls;
    if (l->hooks && l->hooks->closed)
        l->hooks->closed(l);
    else
        _exit(0);
}

static const struct zwlr_layer_surface_v1_listener ls_listener = {
    .configure = ls_configure,
    .closed = ls_closed,
};

int wlgl_create_layer(struct wlgl *g, struct wlgl_output *output,
                      struct wlgl_layer *l, int kind,
                      enum zwlr_layer_shell_v1_layer layer, const char *ns,
                      uint32_t width, uint32_t height,
                      const struct wlgl_layer_hooks *hooks, void *user)
{
    memset(l, 0, sizeof *l);
    l->g = g;
    l->output = output;
    l->kind = kind;
    l->hooks = hooks;
    l->user = user;
    l->surf = wl_compositor_create_surface(g->comp);
    if (!l->surf) return -1;
    struct wl_region *empty = wl_compositor_create_region(g->comp);
    wl_surface_set_input_region(l->surf, empty);
    wl_region_destroy(empty);

    l->ls = zwlr_layer_shell_v1_get_layer_surface(g->shell, l->surf, output->wl,
                                                  layer, ns);
    if (!l->ls) {
        wl_surface_destroy(l->surf);
        l->surf = NULL;
        return -1;
    }
    zwlr_layer_surface_v1_set_anchor(l->ls, ZWLR_LAYER_SURFACE_V1_ANCHOR_TOP |
                                             ZWLR_LAYER_SURFACE_V1_ANCHOR_BOTTOM |
                                             ZWLR_LAYER_SURFACE_V1_ANCHOR_LEFT |
                                             ZWLR_LAYER_SURFACE_V1_ANCHOR_RIGHT);
    zwlr_layer_surface_v1_set_size(l->ls, width, height);
    zwlr_layer_surface_v1_set_exclusive_zone(l->ls, -1);
    zwlr_layer_surface_v1_set_keyboard_interactivity(l->ls, 0);
    zwlr_layer_surface_v1_add_listener(l->ls, &ls_listener, l);
    wl_surface_commit(l->surf);
    return 0;
}

/* --------------------------------------------------------------------- egl */

void wlgl_init(struct wlgl *g, const char *prog, void (*log)(const char *, ...))
{
    memset(g, 0, sizeof *g);
    g->prog = prog;
    g->log = log;
    g->output_size = sizeof(struct wlgl_output);
}

int wlgl_connect(struct wlgl *g)
{
    g->dpy = wl_display_connect(NULL);
    if (!g->dpy) return -1;
    g->reg = wl_display_get_registry(g->dpy);
    wl_registry_add_listener(g->reg, &reg_listener, g);
    wl_display_roundtrip(g->dpy);
    wl_display_roundtrip(g->dpy);
    if (!g->comp || !g->shell) return -2;
    return 0;
}

void wlgl_egl_boot(struct wlgl *g)
{
    g->egl_dpy = eglGetPlatformDisplay(EGL_PLATFORM_WAYLAND_KHR, g->dpy, NULL);
    if (g->egl_dpy == EGL_NO_DISPLAY) fatal(g, "no EGL display");
    EGLint major = 0, minor = 0;
    if (!eglInitialize(g->egl_dpy, &major, &minor))
        fatal(g, "eglInitialize failed (0x%x)", eglGetError());
    if (!eglBindAPI(EGL_OPENGL_ES_API))
        fatal(g, "eglBindAPI failed");
    const EGLint cfg_attr[] = {
        EGL_SURFACE_TYPE, EGL_WINDOW_BIT | EGL_PBUFFER_BIT,
        EGL_RENDERABLE_TYPE, EGL_OPENGL_ES3_BIT,
        EGL_RED_SIZE, 8, EGL_GREEN_SIZE, 8, EGL_BLUE_SIZE, 8, EGL_ALPHA_SIZE, 8,
        EGL_NONE,
    };
    EGLint n = 0;
    if (!eglChooseConfig(g->egl_dpy, cfg_attr, &g->egl_cfg, 1, &n) || n < 1)
        fatal(g, "no matching EGL config");
    const EGLint ctx_attr[] = { EGL_CONTEXT_CLIENT_VERSION, 3, EGL_NONE };
    g->egl_ctx = eglCreateContext(g->egl_dpy, g->egl_cfg, EGL_NO_CONTEXT, ctx_attr);
    if (g->egl_ctx == EGL_NO_CONTEXT)
        fatal(g, "eglCreateContext failed (0x%x)", eglGetError());
    if (!eglMakeCurrent(g->egl_dpy, EGL_NO_SURFACE, EGL_NO_SURFACE, g->egl_ctx)) {
        const EGLint pb[] = { EGL_WIDTH, 1, EGL_HEIGHT, 1, EGL_NONE };
        EGLSurface tmp = eglCreatePbufferSurface(g->egl_dpy, g->egl_cfg, pb);
        if (tmp == EGL_NO_SURFACE || !eglMakeCurrent(g->egl_dpy, tmp, tmp, g->egl_ctx))
            fatal(g, "cannot make an EGL context current (0x%x)", eglGetError());
    }
    wlgl_logf(g, "EGL %d.%d", major, minor);
}

/* ------------------------------------------------------------------ shader */

static GLuint compile(struct wlgl *g, GLenum type, const char *src)
{
    GLuint s = glCreateShader(type);
    glShaderSource(s, 1, &src, NULL);
    glCompileShader(s);
    GLint ok = 0;
    glGetShaderiv(s, GL_COMPILE_STATUS, &ok);
    if (!ok) {
        char buf[4096];
        glGetShaderInfoLog(s, sizeof buf, NULL, buf);
        fatal(g, "shader compile failed: %s", buf);
    }
    return s;
}

GLuint wlgl_program(struct wlgl *g, const char *vs_src, const char *fs_src)
{
    GLuint vs = compile(g, GL_VERTEX_SHADER, vs_src);
    GLuint fs = compile(g, GL_FRAGMENT_SHADER, fs_src);
    GLuint prog = glCreateProgram();
    glAttachShader(prog, vs);
    glAttachShader(prog, fs);
    glLinkProgram(prog);
    GLint ok = 0;
    glGetProgramiv(prog, GL_LINK_STATUS, &ok);
    if (!ok) {
        char buf[4096];
        glGetProgramInfoLog(prog, sizeof buf, NULL, buf);
        fatal(g, "program link failed: %s", buf);
    }
    glDeleteShader(vs);
    glDeleteShader(fs);
    return prog;
}

/* ------------------------------------------------------------------ images */

int wlgl_read_fd_all(int fd, unsigned char **out, size_t *outlen)
{
    size_t cap = 1 << 20, len = 0;
    unsigned char *buf = malloc(cap);
    if (!buf) return -1;
    for (;;) {
        if (len == cap) {
            cap *= 2;
            unsigned char *nb = realloc(buf, cap);
            if (!nb) { free(buf); return -1; }
            buf = nb;
        }
        ssize_t n = read(fd, buf + len, cap - len);
        if (n < 0) {
            if (errno == EINTR) continue;
            free(buf);
            return -1;
        }
        if (n == 0) break;
        len += (size_t)n;
    }
    *out = buf;
    *outlen = len;
    return 0;
}

/* magick <args...> to stdout; returns bytes read or -1 */
int wlgl_magick_pipe(char *const argv[], unsigned char **out, size_t *outlen)
{
    int pf[2];
    if (pipe(pf) != 0) return -1;
    pid_t pid = fork();
    if (pid == 0) {
        dup2(pf[1], STDOUT_FILENO);
        close(pf[0]); close(pf[1]);
        int dn = open("/dev/null", O_WRONLY);
        if (dn >= 0) dup2(dn, STDERR_FILENO);
        execvp(argv[0], argv);
        _exit(127);
    }
    close(pf[1]);
    int rc = wlgl_read_fd_all(pf[0], out, outlen);
    close(pf[0]);
    int status = 0;
    waitpid(pid, &status, 0);
    if (rc != 0 || !WIFEXITED(status) || WEXITSTATUS(status) != 0) {
        if (*out) { free(*out); *out = NULL; }
        *outlen = 0;
        return -1;
    }
    return (int)*outlen;
}

int wlgl_magick_rgba(const char *path, const char *geometry,
                     unsigned char **out, size_t *outlen)
{
    char *av[] = { "magick", (char *)path, "-resize", (char *)geometry,
                   "-depth", "8", "rgba:-", NULL };
    return wlgl_magick_pipe(av, out, outlen);
}

void wlgl_image_dims(const char *path, int *w, int *h)
{
    *w = *h = 0;
    int pf[2];
    if (pipe(pf) != 0) return;
    pid_t pid = fork();
    if (pid == 0) {
        dup2(pf[1], STDOUT_FILENO);
        close(pf[0]); close(pf[1]);
        int dn = open("/dev/null", O_WRONLY);
        if (dn >= 0) dup2(dn, STDERR_FILENO);
        execlp("magick", "magick", "identify", "-format", "%w %h", path, (char *)NULL);
        _exit(127);
    }
    close(pf[1]);
    char buf[64] = {0};
    ssize_t n = read(pf[0], buf, sizeof buf - 1);
    close(pf[0]);
    int status = 0;
    waitpid(pid, &status, 0);
    if (n <= 0) return;
    if (sscanf(buf, "%d %d", w, h) != 2) *w = *h = 0;
}
