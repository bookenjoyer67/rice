#!/bin/bash
set -uo pipefail

BIN="$HOME/.local/bin/wallpaper-bars-gpu"
LOG="${XDG_CACHE_HOME:-$HOME/.cache}/wallpaper-bars-gpu.log"

pids=$(pgrep -f "^$BIN" || true)
if [ -n "$pids" ]; then
    kill $pids
else
    setsid "$BIN" >>"$LOG" 2>&1 &
fi
