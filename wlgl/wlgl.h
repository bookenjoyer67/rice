#ifndef WLGL_H
#define WLGL_H

#include <stddef.h>
#include <stdint.h>

#include <wayland-client.h>
#include <wayland-egl.h>
#include "wlr-layer-shell-unstable-v1-client-protocol.h"

#include <EGL/egl.h>
#include <GLES3/gl3.h>

struct wlgl_output {
    struct wl_output *wl;
    char name[64];
    int32_t w, h;
    struct wlgl_output *next;
};

struct wlgl;
struct wlgl_layer;

struct wlgl_layer_hooks {
    void (*configured)(struct wlgl_layer *l);
    void (*closed)(struct wlgl_layer *l);
};

struct wlgl_layer {
    struct wlgl *g;
    struct wlgl_output *output;
    void *user;
    int kind;
    struct wl_surface *surf;
    struct zwlr_layer_surface_v1 *ls;
    struct wl_egl_window *win;
    EGLSurface esurf;
    struct wl_callback *frame_cb;
    int32_t w, h;
    int configured;
    int ready_counted;
    const struct wlgl_layer_hooks *hooks;
};

struct wlgl {
    const char *prog;
    void (*log)(const char *fmt, ...);
    size_t output_size;
    struct wl_display *dpy;
    struct wl_registry *reg;
    struct wl_compositor *comp;
    struct zwlr_layer_shell_v1 *shell;
    EGLDisplay egl_dpy;
    EGLContext egl_ctx;
    EGLConfig egl_cfg;
    struct wlgl_output *outputs;
    int n_outputs;
};

void wlgl_init(struct wlgl *g, const char *prog, void (*log)(const char *, ...));
int wlgl_connect(struct wlgl *g);
void wlgl_egl_boot(struct wlgl *g);
GLuint wlgl_program(struct wlgl *g, const char *vs_src, const char *fs_src);
int wlgl_read_fd_all(int fd, unsigned char **out, size_t *outlen);
int wlgl_magick_pipe(char *const argv[], unsigned char **out, size_t *outlen);
int wlgl_magick_rgba(const char *path, const char *geometry,
                     unsigned char **out, size_t *outlen);
void wlgl_image_dims(const char *path, int *w, int *h);
int wlgl_create_layer(struct wlgl *g, struct wlgl_output *output,
                      struct wlgl_layer *l, int kind,
                      enum zwlr_layer_shell_v1_layer layer, const char *ns,
                      uint32_t width, uint32_t height,
                      const struct wlgl_layer_hooks *hooks, void *user);
void wlgl_logf(struct wlgl *g, const char *fmt, ...)
    __attribute__((format(printf, 2, 3)));

#endif
