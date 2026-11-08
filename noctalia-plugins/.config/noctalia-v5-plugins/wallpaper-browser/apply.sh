#!/usr/bin/env bash
set -uo pipefail

ID="${1:-}"
URL="${2:-}"
if [ -z "$ID" ] || [ -z "$URL" ]; then
    echo "apply.sh: usage: apply.sh <id> <url>" >&2
    exit 2
fi

CACHE_DIR="$HOME/.cache/wallpaper"
UA="Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36"
MIN_BYTES=100000

ext="${URL##*.}"
ext="${ext%%\?*}"
case "$ext" in
    jpg|jpeg|png|webp) ;;
    *) ext="jpg" ;;
esac

mkdir -p "$CACHE_DIR"
CACHE_DIR="$(readlink -f "$CACHE_DIR" 2>/dev/null || printf '%s' "$CACHE_DIR")"

CACHE_LIB="${WALLPAPER_CACHE_LIB:-}"
if [ -z "$CACHE_LIB" ]; then
    for candidate in "$HOME/.config/niri/scripts/wallpaper-cache.sh" \
                     "$HOME/.local/bin/wallpaper-cache.sh"; do
        if [ -r "$candidate" ]; then
            CACHE_LIB="$candidate"
            break
        fi
    done
fi
if [ -z "$CACHE_LIB" ] || [ ! -r "$CACHE_LIB" ]; then
    echo "apply.sh: wallpaper-cache.sh not found (looked in \$WALLPAPER_CACHE_LIB, $HOME/.config/niri/scripts, $HOME/.local/bin)" >&2
    exit 1
fi
. "$CACHE_LIB"

# The cache reuses one file name (wallpaper.<ext>), so the image on screen is
# about to be overwritten (or deleted, when the extension changes). Snapshot
# it before anything is published; the copy is renamed into place so
# apply-wallpaper.sh can never read a half-written previous.img.
prev_tmp="$CACHE_DIR/.previous.$$.img"
if wc_snapshot_previous "$prev_tmp"; then
    mv -f "$prev_tmp" "$CACHE_DIR/previous.img" 2>/dev/null || rm -f "$prev_tmp"
else
    rm -f "$prev_tmp"
fi

if ! dest="$(wc_download "$URL" 45 "$ext")"; then
    echo "apply.sh: download failed or too small for $ID" >&2
    exit 1
fi
wc_record "$ID"                        # only the image actually published

SCRIPTS_DIR="${WALLPAPER_SCRIPTS:-}"
if [ -z "$SCRIPTS_DIR" ]; then
    for candidate in "$HOME/.config/niri/scripts" "$HOME/.local/bin"; do
        if [ -x "$candidate/apply-wallpaper.sh" ]; then
            SCRIPTS_DIR="$candidate"
            break
        fi
    done
fi
if [ -z "$SCRIPTS_DIR" ] || [ ! -x "$SCRIPTS_DIR/apply-wallpaper.sh" ]; then
    echo "apply.sh: apply-wallpaper.sh not found (looked in \$WALLPAPER_SCRIPTS, $HOME/.config/niri/scripts, $HOME/.local/bin)" >&2
    exit 127
fi

exec bash "$SCRIPTS_DIR/apply-wallpaper.sh" "$dest"
