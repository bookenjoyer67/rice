#!/usr/bin/env bash
# apply-wallpaper.sh — THE single place that applies a wallpaper.
#
# Every wallpaper path (startup, random-switch, swipe-delete, rotation) calls
# this, so the desktop stays in sync in one shot:
#
#   1. awww paints the image (awww owns the wallpaper on this box;
#      Noctalia's own [wallpaper] enabled = false).
#   2. ~/.config/backgrounds/current-wallpaper is repointed (lockscreen,
#      hotplug healer and other consumers read this symlink).
#   3. matugen regenerates the app palettes (kitty / nvim).
#   4. Noctalia is handed the image, so its shell palette (bar, panels,
#      widgets, OSD) is re-extracted from the wallpaper — theme.source is
#      "wallpaper", but Noctalia only samples what it is told about.
#
# Usage: apply-wallpaper.sh <image> [extra awww img args...]
#
# NOTE: app theme templates (noctalia msg templates-apply) are deliberately
# NOT run here — they rewrite external app configs (vscode, neovim, obsidian,
# ...) and we do not want that on every wallpaper swipe. Run it by hand when
# you want the app palettes refreshed too.
set -uo pipefail

IMG="${1:-}"
shift || true
if [ -z "$IMG" ] || [ ! -f "$IMG" ]; then
    echo "apply-wallpaper: no such image: ${IMG:-<empty>}" >&2
    exit 1
fi
IMG="$(readlink -f "$IMG")"

LINK="$HOME/.config/backgrounds/current-wallpaper"

# 1. paint
awww img "$IMG" --transition-type random --transition-duration 2 "$@" 2>/dev/null \
    || awww img "$IMG" "$@" 2>/dev/null \
    || true

# 2. remember
ln -sf "$IMG" "$LINK"

# 3. app palettes (kitty, nvim)
matugen image "$IMG" -m dark --prefer darkness --quiet 2>/dev/null || true

# 4. Noctalia shell palette follows the wallpaper
if command -v noctalia >/dev/null 2>&1; then
    noctalia msg wallpaper-set "$IMG" >/dev/null 2>&1 || true
fi

# 5. lockscreen backdrops (swaylock draws a pre-graded image per output; baking it
#    here keeps the lock instant instead of grading on the first lock after a change)
if [ -x "$HOME/.local/bin/refresh-lock-backdrops.sh" ]; then
    "$HOME/.local/bin/refresh-lock-backdrops.sh" >/dev/null 2>&1 &
fi

