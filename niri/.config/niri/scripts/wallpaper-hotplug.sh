#!/usr/bin/env bash
set -uo pipefail

LINK="$HOME/.config/backgrounds/current-wallpaper"
CACHE_DIR="$HOME/.cache/wallpaper"
INTERVAL=3

log() { printf '[wallpaper-hotplug] %s\n' "$*"; }

current_image() {
    local img=""
    [ -L "$LINK" ] && img="$(readlink -f "$LINK" 2>/dev/null || true)"
    if [ -z "$img" ] || [ ! -f "$img" ]; then
        img="$(ls "$CACHE_DIR"/wallpaper.* 2>/dev/null | head -n 1)"
    fi
    printf '%s' "$img"
}

heal_if_needed() {
    awww query &>/dev/null || return 0            # daemon not up yet

    local enabled shown o line
    enabled="$(niri msg --json outputs 2>/dev/null \
        | jq -r 'to_entries[] | select(.value.logical != null) | .key')"
    [ -z "$enabled" ] && return 0

    shown="$(awww query 2>/dev/null)"

    while IFS= read -r o; do
        [ -z "$o" ] && continue
        line="$(printf '%s\n' "$shown" | grep -F ": $o: " | head -n1)"
        case "$line" in
            *"image:"*) ;;                        # already painted, nothing to do
            *)                                    # missing entirely, or a solid color
                local img; img="$(current_image)"
                if [ -n "$img" ]; then
                    log "output $o has no image; applying $(basename "$img")"
                    awww img "$img" --transition-type none 2>/dev/null
                fi
                return 0
                ;;
        esac
    done <<<"$enabled"
}

while :; do
    sleep "$INTERVAL"
    heal_if_needed
done
