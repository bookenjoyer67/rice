#!/usr/bin/env bash
# Lock the session with swaylock: no input field, the ring IS the feedback.
#
# The look is a BAKED backdrop, not swaylock's own effects: make_backdrop.py grades
# the current wallpaper (blur, desaturate, palette tint, accent bloom, vignette) and
# draws the indicator's glow plus the dark disc behind the clock, so swaylock only
# strokes the ring and draws the time. Backdrops are per output (aspect safe) and
# cached in ~/.cache/lockscreen, so locking is instant after the first run and after
# every wallpaper change (apply-wallpaper.sh refreshes them).
#
# Typing lights ring segments (key-hl), backspace lights them in the second accent,
# a wrong guess turns the ring red, caps lock tints it, failed attempts and the
# keyboard layout are printed in the ring.
#
# LOCK_DRY=1 / LOCK_NUL=1 -> print the argv instead of locking (tests, preview harness)
# LOCK_FORCE=1            -> regenerate the cached backdrops even if fresh
# LOCK_RING_R / LOCK_FONT -> override geometry / typeface

set -euo pipefail

CACHE="${HOME}/.cache/lockscreen"
PALETTE="${HOME}/.local/state/rice/palette.yml"
WALL="${HOME}/.config/backgrounds/current-wallpaper"
RING_R="${LOCK_RING_R:-210}"      # px; baked into the backdrop halo at the same radius
FONT="${LOCK_FONT:-DejaVu Serif}"

mkdir -p "$CACHE"

# Palette anchors are quoted 8-digit rrggbbaa values; fall back to the "divine
# machinery" pink/gold scheme if matugen has not run yet.
get_colour() {
    local key="$1" fallback="$2" val=""
    if [ -r "$PALETTE" ]; then
        val="$(sed -n "s/^${key}: *&[A-Za-z0-9_]* *\"\([0-9a-fA-F]\{6,8\}\)\".*/\1/p" "$PALETTE" | head -n1)"
    fi
    if [ -z "$val" ]; then
        val="$fallback"
    fi
    if [ "${#val}" -eq 6 ]; then
        val="${val}ff"
    fi
    printf '%s' "$val"
}

BG="$(get_colour c_bg 0a0a0fcc)"
FG="$(get_colour c_fg e8e0d0ff)"
ACCENT="$(get_colour c_accent ff1493ff)"
ACCENT2="$(get_colour c_accent2 ffd700ff)"

WALL_REAL="$(readlink -f "$WALL" 2>/dev/null || true)"
if [ -z "$WALL_REAL" ] || [ ! -f "$WALL_REAL" ]; then
    WALL_REAL=""
fi

# Cache key: wallpaper identity + ring radius.
KEY="$(printf '%s' "${WALL_REAL}:$(stat -c '%s-%Y' "$WALL_REAL" 2>/dev/null):${RING_R}" | md5sum | cut -c1-12)"

# One backdrop per enabled output; swaylock takes --image <output>:<path>.
IMAGE_ARGS=()
while IFS=$'\t' read -r name ow oh; do
    if [ -z "${name:-}" ]; then
        continue
    fi
    shot="$CACHE/${KEY}-${ow}x${oh}.png"
    if [ ! -s "$shot" ] || [ "${LOCK_FORCE:-0}" = "1" ]; then
        if [ -n "$WALL_REAL" ]; then
            python3 "${HOME}/.local/bin/make_backdrop.py" \
                "$WALL_REAL" "$shot" "${ow}x${oh}" "$PALETTE" "$RING_R" >/dev/null 2>&1 || true
        fi
    fi
    if [ -s "$shot" ]; then
        IMAGE_ARGS+=(--image "${name}:${shot}")
    fi
done < <(niri msg --json outputs 2>/dev/null |
         jq -r 'to_entries[] | select(.value.logical != null) |
                "\(.key)\t\(.value.logical.width|floor)\t\(.value.logical.height|floor)"' 2>/dev/null)

# Fallback: no compositor info (niri not answering) -> let swaylock grade one image.
if [ ${#IMAGE_ARGS[@]} -eq 0 ]; then
    if [ -n "$WALL_REAL" ]; then
        IMAGE_ARGS=(--image "$WALL_REAL" --scaling fill --effect-blur 14x4)
    else
        IMAGE_ARGS=(--color "${BG:0:6}")
    fi
fi

NONE="00000000"

ARGS=(
    "${IMAGE_ARGS[@]}"
    --fade-in 0.4
    --indicator
    --indicator-radius "$RING_R"
    --indicator-thickness 2
    --show-failed-attempts
    --show-keyboard-layout
    --indicator-caps-lock
    --font "$FONT"
    --clock
    --timestr "%-I:%M"
    --datestr "%a %d %B"
    --font-size 112
    --inside-color "${BG:0:6}00"
    --inside-ver-color "${ACCENT:0:6}1f"
    --inside-wrong-color "ff6b8122"
    --inside-caps-lock-color "${ACCENT2:0:6}1f"
    --ring-color "${ACCENT:0:6}99"
    --ring-clear-color "${ACCENT:0:6}55"
    --ring-ver-color "${ACCENT:0:6}ff"
    --ring-wrong-color "ff6b81ff"
    --ring-caps-lock-color "${ACCENT2:0:6}ff"
    --line-color "$NONE"
    --separator-color "$NONE"
    --key-hl-color "${ACCENT:0:6}ff"
    --bs-hl-color "${ACCENT2:0:6}ff"
    --caps-lock-key-hl-color "${ACCENT2:0:6}ff"
    --caps-lock-bs-hl-color "${ACCENT2:0:6}ff"
    --text-color "$FG"
    --text-clear-color "$FG"
    --text-ver-color "${ACCENT:0:6}ff"
    --text-wrong-color "ff6b81ff"
    --text-caps-lock-color "${ACCENT2:0:6}ff"
)

if [ "${LOCK_NUL:-0}" = "1" ]; then
    printf '%s\0' "${ARGS[@]}"
    exit 0
fi

if [ "${LOCK_DRY:-0}" = "1" ]; then
    printf 'swaylock'
    printf ' %q' "${ARGS[@]}"
    printf '\n'
    exit 0
fi

# -f daemonizes so a niri spawn / systemd oneshot returns immediately.
exec swaylock -f "${ARGS[@]}"
