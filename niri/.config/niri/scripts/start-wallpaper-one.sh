#!/usr/bin/env bash
# Startup: re-paint the wallpaper we ALREADY had. NO new image is fetched here —
# switching is manual only (Mod+Shift+W keep / Mod+X reject). A fresh image is
# pulled just once, when the cache is empty (first login, or a wiped
# ~/.cache/wallpaper), so the desktop is never left blank.
# Keeps the awww daemon + matugen colour generation in sync.
set -euo pipefail

DER="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
APPLY="$DER/apply-wallpaper.sh"
FETCH="$DER/fetch-wallpaper.sh"
LINK="$HOME/.config/backgrounds/current-wallpaper"
CACHE_DIR="$HOME/.cache/wallpaper"

# Under niri-session the awww-daemon user unit is up before this runs. A bare
# `niri` started from a login shell has no systemd session target, so the daemon
# would never appear: the wallpaper stayed unpainted and every `awww img` failed
# silently. Start it ourselves when nothing answers `awww query`.
if ! awww query &>/dev/null; then
    setsid awww-daemon >/dev/null 2>&1 &
fi

# Wait for awww daemon
for _ in $(seq 1 40); do
    awww query &>/dev/null && break
    sleep 0.25
done

# The wallpaper that was on screen when this session ended: the symlink every
# apply writes, then the single-file cache, then (last resort) a fresh fetch.
img=""
if [ -L "$LINK" ]; then
    img="$(readlink -f "$LINK" 2>/dev/null || true)"
fi
if [ -z "$img" ] || [ ! -f "$img" ]; then
    img="$(ls "$CACHE_DIR"/wallpaper.* 2>/dev/null | head -n1 || true)"
fi
if [ -z "$img" ] || [ ! -f "$img" ]; then
    img="$(bash "$FETCH" 2>/dev/null || true)"
fi

if [ -n "$img" ]; then
    bash "$APPLY" "$img"
fi
