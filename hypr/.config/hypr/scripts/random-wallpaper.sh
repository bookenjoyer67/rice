#!/usr/bin/env bash
# Wallpaper: force a random switch (Tinder "keep" — swipe right).
# Curls a fresh random image from the source and applies it.
set -euo pipefail

APPLY="$HOME/.config/hypr/scripts/apply-wallpaper.sh"
FETCH="$HOME/.config/hypr/scripts/fetch-wallpaper.sh"

img="$(bash "$FETCH" 2>/dev/null || true)"
if [ -n "$img" ]; then
    bash "$APPLY" "$img"
fi
