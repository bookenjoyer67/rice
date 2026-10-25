#!/usr/bin/env bash
set -euo pipefail

DER="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
APPLY="$DER/apply-wallpaper.sh"
FETCH="$DER/fetch-wallpaper.sh"
LINK="$HOME/.config/backgrounds/current-wallpaper"
CACHE_DIR="$HOME/.cache/wallpaper"

if ! awww query &>/dev/null; then
    setsid awww-daemon >/dev/null 2>&1 &
fi

for _ in $(seq 1 40); do
    awww query &>/dev/null && break
    sleep 0.25
done

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
