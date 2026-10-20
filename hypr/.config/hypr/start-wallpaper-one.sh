#!/usr/bin/env bash
# Startup: paint ONE wallpaper. NO rotation loop — the user switches manually.
# Curls a fresh random image from the source (falls back to the cached one when
# offline). Keeps the awww daemon + matugen colour generation in sync.
set -euo pipefail

APPLY="$HOME/.config/hypr/scripts/apply-wallpaper.sh"
FETCH="$HOME/.config/hypr/scripts/fetch-wallpaper.sh"

# Wait for awww daemon
for _ in $(seq 1 40); do
    awww query &>/dev/null && break
    sleep 0.25
done

img="$(bash "$FETCH" 2>/dev/null || true)"
if [ -n "$img" ]; then
    bash "$APPLY" "$img"
fi
