# noctalia-layer-swap

Keeps Noctalia's desktop widgets in place during the niri overview.

## The problem

niri zooms the `Background` and `Bottom` layers together with the workspaces in
the overview; only `Top` and `Overlay` surfaces stay put. Noctalia renders every
desktop widget as its own layer-shell surface on the **Bottom** layer
(`src/shell/desktop/desktop_widgets_host.cpp` — `LayerShellLayer::Bottom`,
hard-coded). So in the overview the widgets slide and shrink away with the
workspace.

The EWW widgets get around this with `scripts/overview-watch.sh`: a bottom-layer
window plus a `foreground`-layer twin, swapped on niri's overview events.

That trick cannot be applied to Noctalia from the outside:

* `[desktop_widgets]` has no `layer` setting, and there is no layer IPC (bars get
  `noctalia msg bar-layer-set`, desktop widgets get nothing).
* niri's `layer-rule` can `match layer=`, but it cannot *change* a client's layer,
  and `place-within-backdrop` only applies to `Background`-layer surfaces.
* The plugin API cannot create a surface at a chosen layer.

## What this does

`set_layer` can only be sent by the client that owns the surface, so the swap is
driven from inside Noctalia via `LD_PRELOAD`.

The shim interposes `wl_proxy_marshal_array_flags` and watches for
`zwlr_layer_shell_v1.get_layer_surface` — that is where the layer *and* the
namespace are supplied — remembering every surface whose namespace starts with
`noctalia-desktop-widget-`. A worker thread reads `niri msg event-stream` and, on
`Overview toggled:`, marshals `set_layer(Top)` (overview open) or
`set_layer(Bottom)` (closed) on those surfaces, followed by a `wl_surface.commit`,
because layer-shell layers are double-buffered.

niri re-stacks a surface whenever its client changes layer
(`src/handlers/layer_shell.rs`: `pending_layer != current_layer` triggers rule
recomputation), so the widgets stay at the same output position but stop zooming
— exactly what the EWW twins achieve.

Marshalling from the worker thread is safe: `wl_proxy_marshal_array_flags` takes
the display mutex (`src/wayland-client.c`), which serialises it with the shell's
own requests.

## Files

    shim.c        the whole shim
    Makefile      builds ~/.local/lib/noctalia-layer-swap.so

## Build

    make            # -> ~/.local/lib/noctalia-layer-swap.so
    make clean

## Enable

niri launches Noctalia under it (`~/.config/niri/config.kdl`):

    spawn-at-startup "env" "LD_PRELOAD=/home/computing/.local/lib/noctalia-layer-swap.so" "noctalia"

Then restart the shell (log out/in, or `pkill -x noctalia` and start it again
with the same `env` line).

## Disable / revert

* Temporarily, without a restart: `NOCTALIA_LAYER_SWAP=0` in the environment.
* Permanently: remove the `LD_PRELOAD` from the `spawn-at-startup` line in
  `~/.config/niri/config.kdl` and drop the four-line comment above it.

## Guard rails

* Arms only in a process named `noctalia` (by argv[0] or `/proc/self/comm`).
  `LD_PRELOAD` is inherited by every child Noctalia spawns; those stay untouched.
  `NOCTALIA_LAYER_SWAP_FORCE=1` overrides the name check (the test client used it).
* If `dlsym` fails or the event stream cannot be started, it does nothing.
* Only namespaces matching `noctalia-desktop-widget-` are ever touched.

## Debugging

    NOCTALIA_LAYER_SWAP_DEBUG=1 ...   # logs every niri event and each swap

It always logs `armed`, each tracked surface, and each move to stderr (the
session journal).

Check the current layers with:

    niri msg layers | grep -A2 noctalia-desktop-widget

## Testing without Noctalia

Any Wayland layer-shell client works, e.g. a throwaway eww config:

    (defwindow w :monitor 0 :stacking "bottom"
      :namespace "noctalia-desktop-widget-test-0001"
      :geometry (geometry :x "200px" :y "200px" :width "200px" :height "80px" :anchor "top left")
      (box (label :text "test")))

    NOCTALIA_LAYER_SWAP_FORCE=1 LD_PRELOAD=$HOME/.local/lib/noctalia-layer-swap.so \
      eww --config /tmp/eww-shimtest daemon

Toggle the overview and watch that surface move between `Bottom` and `Top`,
while a control window with a different namespace never moves.
