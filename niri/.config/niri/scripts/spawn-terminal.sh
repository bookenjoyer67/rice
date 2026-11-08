#!/usr/bin/env bash
# Spawn a terminal, with a smaller font when it lands on the TV (HDMI-A-1).
#
# Why a wrapper: niri cannot match an output in a window-rule (`match output="…"`
# is rejected as an "unexpected property"), so the compositor cannot restyle a
# window per screen. niri always places a NEW window on the FOCUSED output, so the
# focused output at the instant of spawn is exactly the screen the terminal will
# appear on -- that is the hook we use.
#
# Tunables (override in the environment if you want to experiment without editing):
#   TV_OUTPUT    connector name of the TV      (default HDMI-A-1)
#   TV_FONT      font size used on the TV      (default 10)
# Laptop spawns pass NO font override, so ~/.config/kitty/kitty.conf stays the
# single source of truth for the normal size.
set -euo pipefail

TV_OUTPUT="${TV_OUTPUT:-HDMI-A-1}"
TV_FONT="${TV_FONT:-10}"

out=""
if command -v niri >/dev/null 2>&1; then
    out=$(niri msg --json focused-output 2>/dev/null | jq -r '.name // empty' 2>/dev/null || true)
fi

if [ "$out" = "$TV_OUTPUT" ]; then
    exec kitty -o "font_size=$TV_FONT" "$@"
fi
exec kitty "$@"
