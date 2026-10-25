#!/bin/bash
# Toggle the GPU cava bars: the wlr-layer-shell renderer in
# ~/.local/src/wallpaper-bars-gpu (one fullscreen shader pass per output).
#
# It replaced the Noctalia desktop widget `computing/wallpaper-bars`, whose
# ~1400 translucent ui.box nodes per output cost cairo about one core of CPU.
# The widget stays installed but DISABLED so nothing draws twice.
set -uo pipefail

BIN="$HOME/.local/bin/wallpaper-bars-gpu"
LOG="${XDG_CACHE_HOME:-$HOME/.cache}/wallpaper-bars-gpu.log"

pids=$(pgrep -f "^$BIN" || true)
if [ -n "$pids" ]; then
    # shellcheck disable=SC2086
    kill $pids
else
    setsid "$BIN" >>"$LOG" 2>&1 &
fi
