#!/usr/bin/env bash
set -uo pipefail

IMG="${1:-}"
shift || true
if [ -z "$IMG" ] || [ ! -f "$IMG" ]; then
    echo "apply-wallpaper: no such image: ${IMG:-<empty>}" >&2
    exit 1
fi
IMG="$(readlink -f "$IMG")"

LINK="$HOME/.config/backgrounds/current-wallpaper"

PAINTED=0
if awww img "$IMG" --transition-type random --transition-duration 2 "$@" 2>/dev/null \
   || awww img "$IMG" "$@" 2>/dev/null; then
    PAINTED=1
elif awww query 2>/dev/null | grep -q "image: $IMG"; then
    PAINTED=1   # already showing this image (awww refuses a no-op re-apply)
fi
if [ "$PAINTED" -eq 0 ]; then
    echo "apply-wallpaper: awww did not paint $IMG (is awww-daemon running?)" >&2
    exit 1
fi

ln -sf "$IMG" "$LINK"

if command -v matugen >/dev/null 2>&1; then
    if ! matugen image "$IMG" -m dark --prefer darkness --quiet >/dev/null 2>&1; then
        echo "apply-wallpaper: matugen failed — wallpapers will not re-colour" >&2
    fi
fi

if command -v noctalia >/dev/null 2>&1; then
    if ! noctalia msg wallpaper-set "$IMG" >/dev/null 2>&1; then
        echo "apply-wallpaper: noctalia wallpaper-set failed — shell palette stale" >&2
    fi
fi

(
    BRAVE_TPL="$HOME/.local/state/noctalia/community-templates/brave"
    BRAVE_OUT="$HOME/.cache/noctalia/brave-theme/manifest.json"
    if command -v noctalia >/dev/null 2>&1 && [ -f "$BRAVE_TPL/manifest.json" ]; then
        if noctalia theme "$IMG" --scheme "${NOCTALIA_SCHEME:-vibrant}" \
                -r "$BRAVE_TPL/manifest.json:$BRAVE_OUT" >/dev/null 2>&1; then
            bash "$BRAVE_TPL/apply.sh" dark >/dev/null 2>&1 || true
        fi
    fi
) &

if [ -x "$HOME/.local/bin/refresh-lock-backdrops.sh" ]; then
    "$HOME/.local/bin/refresh-lock-backdrops.sh" >/dev/null 2>&1 &
fi
