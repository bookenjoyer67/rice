/*
 * noctalia-layer-swap.so — LD_PRELOAD shim for Noctalia on niri.
 *
 * WHY
 *   niri zooms the Background and Bottom layers together with the workspaces in
 *   the overview, so Noctalia's desktop widgets (which Noctalia hard-codes to the
 *   Bottom layer) slide and shrink away instead of staying put. EWW avoids this by
 *   swapping each widget for a top-layer twin while the overview is open; Noctalia
 *   exposes no layer option and no layer IPC for desktop widgets, so the swap has
 *   to be driven from inside Noctalia's own Wayland connection.
 *
 * WHAT
 *   Interposes wl_proxy_marshal_array_flags to spot
 *   zwlr_layer_shell_v1.get_layer_surface calls whose namespace starts with
 *   "noctalia-desktop-widget-", remembers the created layer-surface (and its
 *   wl_surface), and — watching niri's event stream on a worker thread — moves
 *   those surfaces to the Background layer while the overview is open and back to
 *   Bottom when it closes. A place-within-backdrop layer-rule (same namespace) then
 *   renders them in the stationary backdrop: they stay put AND draw BELOW the
 *   windows. niri re-stacks a surface whenever its client changes layer
 *   (src/handlers/layer_shell.rs: pending_layer != current_layer -> recompute),
 *   and wlr-layer-shell layers are double-buffered, so a set_layer is followed by
 *   a wl_surface commit to apply it immediately.
 *
 * SAFETY
 *   - Everything is marshalled on the main thread (the hooks); the worker thread
 *     only sets a flag.
 *   - If dlsym or the event stream fails, the shim silently does nothing.
 *   - NOCTALIA_LAYER_SWAP=0 disables it, NOCTALIA_LAYER_SWAP=log runs it dry.
 *   - Only surfaces whose namespace matches the prefix are ever touched.
 */

#define _GNU_SOURCE
#include <dlfcn.h>
#include <errno.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include <wayland-client-core.h>
#include <wayland-util.h>

#define IFACE_SHELL "zwlr_layer_shell_v1"
#define IFACE_SURFACE "zwlr_layer_surface_v1"
#define NS_PREFIX "noctalia-desktop-widget-"

#define OP_GET_LAYER_SURFACE 0 /* zwlr_layer_shell_v1.get_layer_surface */
#define OP_SH_DESTROY 1        /* zwlr_layer_shell_v1.destroy */
#define OP_SF_SET_LAYER 8      /* zwlr_layer_surface_v1.set_layer */
#define OP_SF_DESTROY 7        /* zwlr_layer_surface_v1.destroy */
#define OP_SF_SET_EXCLUSIVE_ZONE 2 /* zwlr_layer_surface_v1.set_exclusive_zone */

#define OP_SURFACE_COMMIT 6    /* wl_surface.commit */
#define OP_SURFACE_DESTROY 0   /* wl_surface.destroy */

#define LAYER_BACKGROUND 0
#define LAYER_BOTTOM 1
#define LAYER_TOP 2

#define MAX_TRACKED 64

struct tracked {
    struct wl_proxy *ls; /* zwlr_layer_surface_v1 */
    struct wl_proxy *ws; /* its wl_surface */
    unsigned layer;
};

static struct wl_proxy *(*real_marshal_array_flags)(struct wl_proxy *, unsigned,
                                                    const struct wl_interface *,
                                                    unsigned, unsigned,
                                                    union wl_argument *);

static pthread_mutex_t g_lock = PTHREAD_MUTEX_INITIALIZER;
static struct tracked g_items[MAX_TRACKED];
static int g_count = 0;

static int g_enabled = 1;
static int g_dry = 0;

/* Resolve the next definition of a wayland symbol.
 *
 * dlsym(RTLD_NEXT, ...) only works when libwayland-client is already after us in
 * the link map. Toolkits that dlopen() wayland (kitty/glfw do) break that: the
 * lookup returns NULL and the hook either calls a null pointer or reports a fake
 * success. Fall back to the handle of the already-loaded library. */
static void *resolve_next(const char *sym)
{
    void *p = dlsym(RTLD_NEXT, sym);
    void *h;

    if (p)
        return p;
    h = dlopen("libwayland-client.so.0", RTLD_LAZY | RTLD_NOLOAD);
    if (!h)
        h = dlopen("libwayland-client.so.0", RTLD_LAZY | RTLD_GLOBAL);
    if (!h)
        return NULL;

    return dlsym(h, sym);
}
static volatile int g_pending = 0; /* 0 = nothing, 1 = move to top, 2 = to bottom */

static const char *iface_name(const struct wl_proxy *proxy)
{
    const struct wl_interface *i = wl_proxy_get_interface((struct wl_proxy *)proxy);

    return (i && i->name) ? i->name : NULL;
}

static void track(struct wl_proxy *ls, struct wl_proxy *ws, unsigned layer)
{
    pthread_mutex_lock(&g_lock);
    for (int i = 0; i < g_count; i++) {
        if (g_items[i].ls == ls) {
            g_items[i].ws = ws;
            g_items[i].layer = layer;
            pthread_mutex_unlock(&g_lock);
            return;
        }
    }
    if (g_count < MAX_TRACKED) {
        g_items[g_count].ls = ls;
        g_items[g_count].ws = ws;
        g_items[g_count].layer = layer;
        g_count++;
        fprintf(stderr, "[layer-swap] tracking desktop widget surface %p\n", (void *)ls);
    }
    pthread_mutex_unlock(&g_lock);
}

static void untrack(struct wl_proxy *p)
{
    pthread_mutex_lock(&g_lock);
    for (int i = 0; i < g_count; i++) {
        if (g_items[i].ls == p) {
            g_items[i] = g_items[g_count - 1];
            g_count--;
            break;
        }
    }
    pthread_mutex_unlock(&g_lock);
}

static int is_tracked(struct wl_proxy *ls)
{
    int found = 0;

    pthread_mutex_lock(&g_lock);
    for (int i = 0; i < g_count; i++) {
        if (g_items[i].ls == ls) {
            found = 1;
            break;
        }
    }
    pthread_mutex_unlock(&g_lock);
    return found;
}

/* Marshal one request on a proxy we already know how to talk to. */
static void send(struct wl_proxy *proxy, unsigned opcode, union wl_argument *args)
{
    if (!real_marshal_array_flags || !proxy)
        return;
    real_marshal_array_flags(proxy, opcode, NULL, wl_proxy_get_version(proxy), 0, args);
}

static void set_layer(struct tracked *t, unsigned layer)
{
    union wl_argument a;

    if (t->layer == layer)
        return;
    if (g_dry) {
        fprintf(stderr, "[layer-swap] dry: would move %p -> layer %u\n", (void *)t->ls, layer);
        t->layer = layer;
        return;
    }
    a.u = layer;
    send(t->ls, OP_SF_SET_LAYER, &a);
    /* Layers are double-buffered: the surface has to commit for the move to apply. */
    send(t->ws, OP_SURFACE_COMMIT, NULL);
    t->layer = layer;
    fprintf(stderr, "[layer-swap] moved %p -> layer %u\n", (void *)t->ls, layer);
}

static void apply_pending(void)
{
    if (!real_marshal_array_flags)
        return;

    pthread_mutex_lock(&g_lock);
    int want = g_pending;
    if (want)
        g_pending = 0;
    if (want) {
        /* overview OPEN -> Background layer: the matching place-within-backdrop
         * layer-rule drops the widget into niri's stationary backdrop, so it stays
         * put AND draws BELOW the open windows. overview CLOSED -> native Bottom. */
        unsigned layer = (want == 1) ? LAYER_BACKGROUND : LAYER_BOTTOM;

        if (getenv("NOCTALIA_LAYER_SWAP_DEBUG"))
            fprintf(stderr, "[layer-swap] apply want=%d tracked=%d\n", want, g_count);
        for (int i = 0; i < g_count; i++)
            set_layer(&g_items[i], layer);
    }
    pthread_mutex_unlock(&g_lock);
}

/* wl_proxy_marshal_array_flags() takes the display mutex, so marshalling from the
 * watcher thread is safe; flushing needs the display, captured by the hook. */
static struct wl_display *g_display = NULL;
static int (*g_real_flush)(struct wl_display *) = NULL;

static void apply_and_flush(void)
{
    apply_pending();
    if (g_real_flush && g_display)
        g_real_flush(g_display);
}

/* ---- hooks ------------------------------------------------------------- */

static pthread_mutex_t g_start_lock = PTHREAD_MUTEX_INITIALIZER;
static volatile int g_watcher_up = 0;

static void *watcher(void *unused);

/* Started lazily: a client that forks after dlopen (eww daemon, for one) would
 * otherwise lose the thread, since threads do not survive fork(). */
static void maybe_start_watcher(void)
{
    if (__atomic_load_n(&g_watcher_up, __ATOMIC_RELAXED))
        return;
    pthread_mutex_lock(&g_start_lock);
    if (!__atomic_load_n(&g_watcher_up, __ATOMIC_RELAXED)) {
        pthread_t thread;
        if (pthread_create(&thread, NULL, watcher, NULL) == 0) {
            pthread_detach(thread);
            __atomic_store_n(&g_watcher_up, 1, __ATOMIC_RELAXED);
        }
    }
    pthread_mutex_unlock(&g_start_lock);
}

/* After a fork the child has the code but not the thread: reset so the hook
 * restarts the watcher, and reinit mutexes that may have been locked. */
static void atfork_child(void)
{
    __atomic_store_n(&g_watcher_up, 0, __ATOMIC_RELAXED);
    pthread_mutex_init(&g_start_lock, NULL);
    pthread_mutex_init(&g_lock, NULL);
    g_count = 0;
}

struct wl_proxy *wl_proxy_marshal_array_flags(struct wl_proxy *proxy, unsigned opcode,
                                              const struct wl_interface *interface,
                                              unsigned version, unsigned flags,
                                              union wl_argument *args)
{
    if (!real_marshal_array_flags)
        real_marshal_array_flags = resolve_next("wl_proxy_marshal_array_flags");

    if (!real_marshal_array_flags)
        return NULL; /* library is interposed but the real symbol is gone */

    if (!g_enabled)
        return real_marshal_array_flags(proxy, opcode, interface, version, flags, args);

    if (g_enabled && real_marshal_array_flags) {
        const char *name = iface_name(proxy);

        maybe_start_watcher();
        /* The client marshals constantly, so this is a dependable place to apply
         * a pending layer swap on its own thread -- more so than wl_display_flush,
         * which some toolkits never call directly. */
        apply_pending();

        if (name && strcmp(name, IFACE_SHELL) == 0 && opcode == OP_GET_LAYER_SURFACE && args) {
            /* signature "no?us": n, surface, output, layer, namespace */
            const char *ns = args[4].s;
            if (ns && strncmp(ns, NS_PREFIX, sizeof(NS_PREFIX) - 1) == 0) {
                struct wl_proxy *ls = real_marshal_array_flags(proxy, opcode, interface, version, flags, args);
                track(ls, (struct wl_proxy *)args[1].o, args[3].u);
                /* Force exclusive_zone = -1 ("ignore exclusive zones") so niri's
                 * place-within-backdrop rule applies even if this client never
                 * sets it (gtk-layer-shell/eww). */
                if (!g_dry) {
                    union wl_argument e;
                    e.i = -1;
                    send(ls, OP_SF_SET_EXCLUSIVE_ZONE, &e);
                }
                return ls;
            }
        } else if (name && strcmp(name, IFACE_SURFACE) == 0 && opcode == OP_SF_SET_EXCLUSIVE_ZONE && args) {
            /* niri's place-within-backdrop rule only applies to background-layer
             * surfaces that IGNORE exclusive zones (exclusive_zone == -1, as
             * wallpaper tools set it). gtk-layer-shell (eww) leaves it at 0, so
             * force -1 on our tracked desktop-widget surfaces; Noctalia already
             * sets -1 itself, so this is a no-op there. */
            if (is_tracked(proxy)) {
                args[0].i = -1;
                if (getenv("NOCTALIA_LAYER_SWAP_DEBUG"))
                    fprintf(stderr, "[layer-swap] forced exclusive_zone -1 on %p\n", (void *)proxy);
            }
        } else if (name && strcmp(name, IFACE_SURFACE) == 0 && opcode == OP_SF_DESTROY) {
            untrack(proxy);
        } else if (name && strcmp(name, "wl_surface") == 0 && opcode == OP_SURFACE_DESTROY) {
            pthread_mutex_lock(&g_lock);
            for (int i = 0; i < g_count; i++) {
                if (g_items[i].ws == proxy) {
                    g_items[i] = g_items[g_count - 1];
                    g_count--;
                    break;
                }
            }
            pthread_mutex_unlock(&g_lock);
        }
    }

    return real_marshal_array_flags(proxy, opcode, interface, version, flags, args);
}

int wl_display_flush(struct wl_display *display)
{
    static int (*real)(struct wl_display *) = NULL;
    static int logged = 0;

    if (!real)
        real = resolve_next("wl_display_flush");
    if (!g_enabled)
        return real ? real(display) : -1;
    g_real_flush = real;
    g_display = display;
    if (!logged && getenv("NOCTALIA_LAYER_SWAP_DEBUG")) {
        logged = 1;
        fprintf(stderr, "[layer-swap] wl_display_flush hook active\n");
    }
    apply_pending();

    return real ? real(display) : -1;
}

int wl_display_dispatch(struct wl_display *display)
{
    static int (*real)(struct wl_display *) = NULL;

    if (!real)
        real = resolve_next("wl_display_dispatch");
    if (!g_enabled)
        return real ? real(display) : -1;
    apply_pending();

    return real ? real(display) : -1;
}

/* ---- niri overview watcher -------------------------------------------- */

static void *watcher(void *unused)
{
    (void)unused;
    sleep(1); /* let the shell finish starting before shelling out */

    FILE *stream = popen("niri msg event-stream 2>/dev/null", "r");
    if (!stream)
        return NULL;

    char line[512];
    int state = -1;

    while (fgets(line, sizeof line, stream)) {
        if (getenv("NOCTALIA_LAYER_SWAP_DEBUG"))
            fprintf(stderr, "[layer-swap] event: %s", line);
        if (strncmp(line, "Overview toggled: ", 18) != 0)
            continue;
        int now = strncmp(line + 18, "true", 4) == 0;
        if (now == state)
            continue; /* niri re-emits the current state on subscribe */
        state = now;
        g_pending = now ? 1 : 2;
        apply_and_flush();
    }

    pclose(stream);
    return NULL;
}

/* Only arm in the processes that own desktop widgets: the shell itself, and the
 * eww daemon (its desktop widgets use the same noctalia-desktop-widget- namespace
 * prefix and get the identical Bottom<->Background swap). LD_PRELOAD is inherited
 * by every child those spawn, and those have no desktop widgets to move. */
static int process_is_target(void)
{
    const char *name = program_invocation_short_name;

    if (name && (strstr(name, "noctalia") || strcmp(name, "eww") == 0))
        return 1;

    char comm[64] = {0};
    FILE *f = fopen("/proc/self/comm", "r");
    if (f) {
        if (fgets(comm, sizeof comm, f)) {
            comm[strcspn(comm, "\n")] = '\0';
            if (strstr(comm, "noctalia") || strcmp(comm, "eww") == 0) {
                fclose(f);
                return 1;
            }
        }
        fclose(f);
    }

    return getenv("NOCTALIA_LAYER_SWAP_FORCE") != NULL;
}

__attribute__((constructor)) static void layer_swap_init(void)
{
    const char *env = getenv("NOCTALIA_LAYER_SWAP");

    if (env && (strcmp(env, "0") == 0 || strcmp(env, "off") == 0)) {
        g_enabled = 0;
        return;
    }
    if (!process_is_target()) {
        /* LD_PRELOAD is inherited by every app Noctalia launches, so this
         * library is present in processes it has no business touching. The
         * symbols stay interposed, but every hook has to behave as a pure
         * pass-through from here on -- leaving g_enabled at 1 started a
         * `niri msg event-stream` watcher and ran apply_pending() inside
         * arbitrary clients, and kitty died in glfwInit. */
        g_enabled = 0;
        return;
    }
    if (env && strcmp(env, "log") == 0)
        g_dry = 1;

    real_marshal_array_flags = dlsym(RTLD_NEXT, "wl_proxy_marshal_array_flags");
    if (!real_marshal_array_flags) {
        g_enabled = 0;
        return;
    }

    pthread_atfork(NULL, NULL, atfork_child);
    maybe_start_watcher();

    fprintf(stderr, "[layer-swap] armed%s\n", g_dry ? " (dry run)" : "");
}
