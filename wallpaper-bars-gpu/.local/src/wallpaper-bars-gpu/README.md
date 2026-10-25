# wallpaper-bars-gpu

The cava spectrum bars, drawn on the GPU. One `wlr-layer-shell` surface per
output (Bottom layer, click-through) and one fullscreen fragment shader that
does the bar geometry, the mist (a real falloff, not stacked translucent boxes)
and the wallpaper-coloured tint.

It replaces the Noctalia desktop widget `computing/wallpaper-bars`, which built
~1400 translucent `ui.box` nodes per output every frame and cost cairo about one
core of CPU. Measured on this box: ~110% CPU for the widget, ~1-2% for this.

## Build / install

    make            # wayland-scanner + cc
    make install    # -> ~/.local/bin/wallpaper-bars-gpu

Autostart is a `spawn-at-startup` line in `niri/.config/niri/config.kdl`;
`Mod+B` runs `niri/.config/niri/scripts/toggle-wallpaper-bars.sh` to stop/start it.

## Look

The look is taken from the Noctalia settings file at startup
(`~/.local/state/noctalia/settings.toml`), so it stays identical to what the
widget drew:

* `[plugin_settings."computing/wallpaper-bars"]` -> `bar_opacity`, `saturation`,
  `smoothing`, `blur`, `brightness` (colour lift), `min_light`, `idle_seconds`
* per-instance `[desktop_widgets.widget.<id>.settings]` -> `bands` per output
  (this box: 64 on the TV, 128 on the laptop panel)

Everything else (gap, radius, glow) can be overridden on the command line:

    wallpaper-bars-gpu --help

## Data path

`cava -p ~/.config/wallpaper-bars-gpu/cava.conf` (raw ascii, 0..1000) -> smoothed
128-band float texture -> shader. The wallpaper is decoded once per change with
`magick` into a small RGBA texture and sampled per bar tip.

`--demo` synthesises levels for testing without audio; `WBGPU_SELFTEST=1` reads
the frame back and prints band count / alpha profile.
