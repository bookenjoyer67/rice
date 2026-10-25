#!/usr/bin/env bash
set -u

command -v niri >/dev/null 2>&1 || exit 0
command -v noctalia >/dev/null 2>&1 || exit 0
niri msg overview-state >/dev/null 2>&1 || exit 0   # not running under niri

state="$(niri msg overview-state 2>/dev/null | grep -q 'Overview is open' && echo true || echo false)"
[ "$state" = "true" ] && noctalia msg desktop-widgets-hide >/dev/null 2>&1

niri msg event-stream | while read -r line; do
    case "$line" in
        "Overview toggled: true"|"Overview toggled: false")
            now="${line#Overview toggled: }"
            [ "$now" = "$state" ] && continue
            state="$now"
            if [ "$now" = "true" ]; then
                noctalia msg desktop-widgets-hide >/dev/null 2>&1
            else
                noctalia msg desktop-widgets-show >/dev/null 2>&1
            fi
            ;;
    esac
done
