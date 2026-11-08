/*
 * wallfx-character -- the wallpaper's character, kept on the desktop.
 *
 * One fullscreen wlr-layer-shell surface per output, on the BACKGROUND layer
 * so it is wallpaper decoration below the Noctalia desktop widgets. The image
 * is the newest ~/.cache/wallfx/widget/character-<digits>.png written by
 * apply-wallpaper.sh; a 1x1 fully transparent file means "draw nothing".
 *
 * While niri is moving a workspace, switching its active window, animating the
 * overview or otherwise changing the window/workspace set, the surface draws
 * nothing. It comes back 400 ms after the last such event. If niri is not
 * running (or the event-stream child dies) it never hides: a visible character
 * is better than an invisible one.
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
#include <dirent.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>

#include "wlgl.h"
#include <EGL/eglext.h>

#define IMG_MAX       2560      /* longest side an image is decoded at       */
#define IMAGE_POLL_MS 1000.0    /* how often the widget directory is scanned */
#define HIDE_MS       400.0     /* stay hidden this long after the last move */
#define NIRI_RETRY_MS 1000.0

static void logmsg(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
static void logmsg(const char *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    fprintf(stderr, "wallfx-character: ");
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

/* ---------------------------------------------------------------- wayland */

static struct wlgl g;

static GLuint prog, vao;
static GLuint tex_img;
static GLint  u_tex, u_crop, u_sw, u_sh;
static int    img_w, img_h;
static int    ge_ready;

static char   image_path[PATH_MAX];

struct output {
    struct wlgl_output base;        /* must stay first: the registry fills it */
    struct wlgl_layer layer;
    int pending;
    int logged;
};

#define OUTPUTS ((struct output *)g.outputs)
#define NEXT(o) ((struct output *)(o)->base.next)

static void request_render_all(void)
{
    for (struct output *o = OUTPUTS; o; o = NEXT(o))
        o->pending = 1;
}

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
    "uniform sampler2D imgTex;\n"
    "uniform vec4  crop;      // image uv = crop.xy + screen uv * crop.zw\n"
    "uniform float sw, sh;    // screen size, px\n"
    "out vec4 fragColor;\n"
    "void main() {\n"
    "  // gl_FragCoord is bottom-up; the decoded image is top-down.\n"
    "  vec2 uv = vec2(gl_FragCoord.x / sw, 1.0 - gl_FragCoord.y / sh);\n"
    "  vec4 c = texture(imgTex, crop.xy + uv * crop.zw);\n"
    "  // The compositor wants premultiplied alpha.\n"
    "  fragColor = vec4(c.rgb * c.a, c.a);\n"
    "}\n";

static void gpu_init(void)
{
    prog = wlgl_program(&g, VS_SRC, FS_SRC);
    glGenVertexArrays(1, &vao);

    u_tex  = glGetUniformLocation(prog, "imgTex");
    u_crop = glGetUniformLocation(prog, "crop");
    u_sw   = glGetUniformLocation(prog, "sw");
    u_sh   = glGetUniformLocation(prog, "sh");
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

/* decode an image (shrunk to IMG_MAX on the long side) into a new texture.
 * A 1x1 fully transparent image is the widget's "nobody here" marker and gets
 * no texture at all. */
static GLuint load_image(const char *path, int *ow, int *oh)
{
    *ow = *oh = 0;
    int iw = 0, ih = 0;
    wlgl_image_dims(path, &iw, &ih);
    if (iw <= 0 || ih <= 0) return 0;
    char fit[64];
    snprintf(fit, sizeof fit, "%dx%d>", IMG_MAX, IMG_MAX);
    unsigned char *buf = NULL;
    size_t len = 0;
    if (wlgl_magick_rgba(path, fit, &buf, &len) < 0) return 0;
    double s = 1.0;
    if (iw > IMG_MAX || ih > IMG_MAX)
        s = (iw >= ih) ? (double)IMG_MAX / iw : (double)IMG_MAX / ih;
    int dw = (int)lround(iw * s), dh = (int)lround(ih * s);
    size_t want = (size_t)dw * dh * 4;
    if (dw <= 0 || dh <= 0 || len < want) {
        logmsg("decode failed (%zu/%zu bytes): %s", len, want, path);
        free(buf);
        return 0;
    }
    if (dw == 1 && dh == 1 && buf[3] == 0) {
        free(buf);
        return 0;
    }
    GLuint tex = upload_rgba(buf, dw, dh);
    free(buf);
    *ow = dw;
    *oh = dh;
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

/* --------------------------------------------------------- image directory */

static int path_join(char *out, size_t n, const char *dir, const char *name)
{
    size_t dl = strlen(dir), nl = strlen(name);
    if (dl + 1 + nl + 1 > n) return -1;
    memcpy(out, dir, dl);
    out[dl] = '/';
    memcpy(out + dl + 1, name, nl + 1);
    return 0;
}

static int all_digits(const char *s)
{
    if (!*s) return 0;
    for (; *s; s++)
        if (*s < '0' || *s > '9') return 0;
    return 1;
}

/* newest character-<digits>.png in the widget directory (numeric, not lexical) */
static int newest_file(char *out, size_t outlen)
{
    out[0] = '\0';
    DIR *d = opendir(".");
    if (!d) return 0;
    struct dirent *de;
    unsigned long long best = 0;
    char bestname[256] = "";
    while ((de = readdir(d))) {
        const char *nm = de->d_name;
        size_t len = strlen(nm);
        if (len < 15) continue;                       /* character-0.png */
        if (strncmp(nm, "character-", 10) != 0) continue;
        if (strcmp(nm + len - 4, ".png") != 0) continue;
        size_t nlen = len - 14;
        char num[64];
        if (nlen >= sizeof num) continue;
        memcpy(num, nm + 10, nlen);
        num[nlen] = '\0';
        if (!all_digits(num)) continue;
        errno = 0;
        unsigned long long v = strtoull(num, NULL, 10);
        if (errno != 0) continue;
        if (bestname[0] == '\0' || v > best ||
            (v == best && strcmp(nm, bestname) > 0)) {
            best = v;
            snprintf(bestname, sizeof bestname, "%s", nm);
        }
    }
    closedir(d);
    if (!bestname[0]) return 0;
    snprintf(out, outlen, "%s", bestname);
    return 1;
}

/* ------------------------------------------------------- niri event stream */

static int    niri_fd = -1;
static pid_t  niri_pid = -1;
static double niri_restart_at;
static double last_move_ms;
static int    hidden;
static char   niri_buf[1 << 20];
static size_t niri_buflen;

static void niri_spawn(void)
{
    if (niri_fd >= 0) return;
    int pf[2];
    if (pipe(pf) != 0) {
        niri_restart_at = now_ms() + NIRI_RETRY_MS;
        return;
    }
    pid_t pid = fork();
    if (pid < 0) {
        close(pf[0]); close(pf[1]);
        niri_restart_at = now_ms() + NIRI_RETRY_MS;
        return;
    }
    if (pid == 0) {
        dup2(pf[1], STDOUT_FILENO);
        close(pf[0]); close(pf[1]);
        int dn = open("/dev/null", O_WRONLY);
        if (dn >= 0) dup2(dn, STDERR_FILENO);
        execlp("niri", "niri", "msg", "--json", "event-stream", (char *)NULL);
        _exit(127);
    }
    close(pf[1]);
    niri_pid = pid;
    niri_fd = pf[0];
    fcntl(niri_fd, F_SETFL, fcntl(niri_fd, F_GETFL) | O_NONBLOCK);
    fcntl(niri_fd, F_SETFD, FD_CLOEXEC);
    niri_buflen = 0;
    niri_restart_at = 0;
}

static void niri_close(int restart)
{
    if (niri_fd >= 0) {
        close(niri_fd);
        niri_fd = -1;
    }
    if (niri_pid > 0) {
        kill(niri_pid, SIGTERM);
        while (waitpid(niri_pid, NULL, 0) < 0 && errno == EINTR) { }
        niri_pid = -1;
    }
    niri_buflen = 0;
    last_move_ms = 0;
    hidden = 0;
    niri_restart_at = restart ? now_ms() + NIRI_RETRY_MS : 0;
    request_render_all();
}

static int event_moves_backdrop(const char *line)
{
    return strstr(line, "\"Window") != NULL ||
           strstr(line, "\"Workspace") != NULL ||
           strstr(line, "\"OverviewOpenedOrClosed\"") != NULL;
}

/* returns the number of complete lines consumed */
static void niri_pump(void)
{
    if (niri_fd < 0) return;
    for (;;) {
        if (niri_buflen > sizeof niri_buf - 65536)
            niri_buflen = 0;
        ssize_t n = read(niri_fd, niri_buf + niri_buflen,
                         sizeof niri_buf - 1 - niri_buflen);
        if (n < 0) {
            if (errno == EINTR) continue;
            if (errno == EAGAIN || errno == EWOULDBLOCK) break;
            niri_close(1);
            return;
        }
        if (n == 0) {
            niri_close(1);
            return;
        }
        niri_buflen += (size_t)n;
        niri_buf[niri_buflen] = '\0';

        char *start = niri_buf, *nl;
        while ((nl = memchr(start, '\n',
                            niri_buflen - (size_t)(start - niri_buf)))) {
            *nl = '\0';
            if (event_moves_backdrop(start))
                last_move_ms = now_ms();
            start = nl + 1;
        }
        size_t used = (size_t)(start - niri_buf);
        if (used > 0) {
            memmove(niri_buf, start, niri_buflen - used);
            niri_buflen -= used;
        }
    }
}

/* --------------------------------------------------------------- surfaces */

static void frame_done(void *data, struct wl_callback *cb, uint32_t t)
{
    (void)t;
    struct output *o = data;
    wl_callback_destroy(cb);
    o->layer.frame_cb = NULL;
}

static const struct wl_callback_listener frame_cb_listener = { .done = frame_done };

static void render(struct output *o)
{
    if (!ge_ready || !o->layer.configured || !o->layer.esurf || !o->pending) return;
    if (o->layer.frame_cb) return;
    if (eglMakeCurrent(g.egl_dpy, o->layer.esurf, o->layer.esurf, g.egl_ctx) == EGL_FALSE) return;

    int32_t w = o->layer.w, h = o->layer.h;
    if (w <= 0 || h <= 0) return;

    glViewport(0, 0, w, h);
    glDisable(GL_SCISSOR_TEST);
    glClearColor(0.f, 0.f, 0.f, 0.f);
    glClear(GL_COLOR_BUFFER_BIT);

    if (!hidden && tex_img && img_w > 0 && img_h > 0) {
        float crop[4];
        crop_for(img_w, img_h, w, h, crop);

        glEnable(GL_BLEND);
        glBlendFunc(GL_ONE, GL_ONE_MINUS_SRC_ALPHA); /* premultiplied */
        glUseProgram(prog);
        glBindVertexArray(vao);
        glUniform1f(u_sw, (float)w);
        glUniform1f(u_sh, (float)h);
        glUniform4fv(u_crop, 1, crop);
        glActiveTexture(GL_TEXTURE0);
        glBindTexture(GL_TEXTURE_2D, tex_img);
        glUniform1i(u_tex, 0);
        glDrawArrays(GL_TRIANGLES, 0, 3);
    }

    o->pending = 0;
    o->layer.frame_cb = wl_surface_frame(o->layer.surf);
    wl_callback_add_listener(o->layer.frame_cb, &frame_cb_listener, o);
    eglSwapBuffers(g.egl_dpy, o->layer.esurf);
}

static void render_all(void)
{
    for (struct output *o = OUTPUTS; o; o = NEXT(o))
        render(o);
}

static void layer_configured(struct wlgl_layer *l)
{
    struct output *o = l->user;
    if (!o->logged) {
        o->logged = 1;
        logmsg("%s %dx%d, image %s", o->base.name[0] ? o->base.name : "?",
               l->w, l->h, image_path[0] ? image_path : "none");
    }
    o->pending = 1;
    render(o);
}

static void layer_closed(struct wlgl_layer *l)
{
    (void)l;
    logmsg("compositor closed a layer surface");
    exit(0);
}

static const struct wlgl_layer_hooks layer_hooks = {
    .configured = layer_configured,
    .closed = layer_closed,
};

static void create_surface(struct output *o)
{
    /* wall decoration: BACKGROUND is below every Noctalia widget (Bottom). */
    wlgl_create_layer(&g, &o->base, &o->layer, 0,
                      ZWLR_LAYER_SHELL_V1_LAYER_BACKGROUND, "wallfx-character",
                      0, 0, &layer_hooks, o);
}

/* ------------------------------------------------------------------- main */

static volatile sig_atomic_t quit;
static void on_signal(int sig) { (void)sig; quit = 1; }

static void cleanup(void)
{
    niri_close(0);
    for (struct output *o = OUTPUTS; o; o = NEXT(o)) {
        if (o->layer.frame_cb) {
            wl_callback_destroy(o->layer.frame_cb);
            o->layer.frame_cb = NULL;
        }
        if (o->layer.esurf) eglDestroySurface(g.egl_dpy, o->layer.esurf);
        if (o->layer.win) wl_egl_window_destroy(o->layer.win);
        if (o->layer.ls) zwlr_layer_surface_v1_destroy(o->layer.ls);
        if (o->layer.surf) wl_surface_destroy(o->layer.surf);
        if (o->base.wl) wl_output_destroy(o->base.wl);
    }
    if (g.egl_dpy != EGL_NO_DISPLAY) {
        if (g.egl_ctx != EGL_NO_CONTEXT)
            eglDestroyContext(g.egl_dpy, g.egl_ctx);
        eglTerminate(g.egl_dpy);
    }
    if (g.dpy) wl_display_disconnect(g.dpy);
}

int main(int argc, char **argv)
{
    (void)argc;
    (void)argv;

    wlgl_init(&g, "wallfx-character", logmsg);
    g.output_size = sizeof(struct output);
    signal(SIGPIPE, SIG_IGN);
    signal(SIGTERM, on_signal);
    signal(SIGINT, on_signal);

    const char *home = getenv("HOME");
    if (!home || !*home) {
        logmsg("HOME is not set");
        return 1;
    }
    char widget_dir[PATH_MAX];
    snprintf(widget_dir, sizeof widget_dir, "%s/.cache/wallfx/widget", home);
    image_path[0] = '\0';

    int wl_rc = wlgl_connect(&g);
    if (wl_rc == -1) {
        logmsg("cannot connect to WAYLAND_DISPLAY");
        return 1;
    }
    if (wl_rc != 0) {
        logmsg("compositor lacks wl_compositor / zwlr_layer_shell_v1");
        return 1;
    }

    wlgl_egl_boot(&g);
    gpu_init();
    ge_ready = 1;

    /* chdir to the widget directory so readdir only needs d_name */
    if (chdir(widget_dir) == 0) {
        char newest[PATH_MAX];
        if (newest_file(newest, sizeof newest) &&
            path_join(image_path, sizeof image_path, widget_dir, newest) == 0) {
            int w = 0, h = 0;
            GLuint t = load_image(image_path, &w, &h);
            if (t) {
                tex_img = t;
                img_w = w;
                img_h = h;
            }
        }
    }

    for (struct output *o = OUTPUTS; o; o = NEXT(o))
        create_surface(o);
    wl_display_roundtrip(g.dpy);

    niri_spawn();

    double next_img = now_ms() + IMAGE_POLL_MS;
    while (!quit) {
        double t = now_ms();

        if (t >= next_img) {
            next_img = t + IMAGE_POLL_MS;
            if (chdir(widget_dir) == 0) {
                char newest[PATH_MAX];
                int have = newest_file(newest, sizeof newest);
                char found[PATH_MAX];
                if (!have || path_join(found, sizeof found, widget_dir, newest) != 0)
                    found[0] = '\0';
                if (strcmp(found, image_path) != 0) {
                    snprintf(image_path, sizeof image_path, "%s", found);
                    if (tex_img) {
                        glDeleteTextures(1, &tex_img);
                        tex_img = 0;
                        img_w = img_h = 0;
                    }
                    if (have) {
                        int w = 0, h = 0;
                        GLuint tex = load_image(image_path, &w, &h);
                        if (tex) {
                            tex_img = tex;
                            img_w = w;
                            img_h = h;
                        }
                    }
                    request_render_all();
                }
            }
        }

        if (niri_fd < 0 && niri_restart_at > 0 && t >= niri_restart_at)
            niri_spawn();

        int want_hide = last_move_ms > 0 && t - last_move_ms < HIDE_MS;
        if (want_hide != hidden) {
            hidden = want_hide;
            request_render_all();
        }
        render_all();

        double wait = next_img - t;
        if (hidden) {
            double d = last_move_ms + HIDE_MS - t;
            if (d < wait) wait = d;
        }
        if (niri_fd < 0 && niri_restart_at > 0) {
            double d = niri_restart_at - t;
            if (d < wait) wait = d;
        }
        if (wait < 0) wait = 0;
        int timeout = (int)ceil(wait);

        while (wl_display_prepare_read(g.dpy) != 0)
            wl_display_dispatch_pending(g.dpy);
        wl_display_flush(g.dpy);

        struct pollfd pf[2] = {
            { .fd = wl_display_get_fd(g.dpy), .events = POLLIN },
            { .fd = niri_fd, .events = POLLIN },
        };
        int nfd = niri_fd >= 0 ? 2 : 1;
        int pr = poll(pf, (nfds_t)nfd, timeout);
        if (pr < 0) {
            wl_display_cancel_read(g.dpy);
            if (errno == EINTR)
                continue;
            logmsg("poll: %s", strerror(errno));
            break;
        }
        if (pr > 0 && (pf[0].revents & POLLIN)) {
            if (wl_display_read_events(g.dpy) != 0) {
                logmsg("wayland connection lost");
                break;
            }
            wl_display_dispatch_pending(g.dpy);
        } else {
            wl_display_cancel_read(g.dpy);
        }
        if (nfd == 2 && pr > 0 && pf[1].revents) {
            if (pf[1].revents & POLLIN)
                niri_pump();
            if (niri_fd >= 0 && (pf[1].revents & (POLLHUP | POLLERR)))
                niri_close(1);
        }
    }

    cleanup();
    return 0;
}
