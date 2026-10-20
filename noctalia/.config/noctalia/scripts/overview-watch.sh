#!/usr/bin/env bash
# overview-watch.sh — keep the Noctalia desktop widgets out of the niri overview
# zoom-out.
#
# niri zooms the Background and Bottom layers together with the workspaces in
# the overview, and Noctalia renders every desktop widget as its own
# layer-shell surface on the Bottom layer (see `niri msg layers`:
# noctalia-desktop-widget-*). So in the overview the widgets slide and shrink
# away with the workspace instead of staying put.
#
# EWW solves the same problem by swapping each widget for a top-layer twin
# (scripts/overview-watch.sh in the eww config). Noctalia cannot be driven that
# way: unlike bars (`noctalia msg bar-layer-set <top|overlay>`), desktop widgets
# have no layer setting under [desktop_widgets] and no layer IPC -- the Bottom
# layer is hard-coded in DesktopWidgetsHost. The only lever Noctalia exposes is
# runtime visibility, so the closest match is to hide the widgets for the
# duration of the overview and bring them back when it closes.
# `desktop-widgets-hide`/`-show` flip an ephemeral runtime override; settings.toml
# is never written and the saved preference returns on restart.
#
# Reads niri's IPC event stream and toggles on "Overview toggled: ...".
#
# niri re-emits the CURRENT state when the stream opens, so the first event just
# repeats whatever the state already is; acting on it would hide widgets the
# moment this script starts with the overview already closed. Seed the last-known
# state and skip the repeat (same guard as the EWW watcher).
set -u

command -v niri >/dev/null 2>&1 || exit 0
command -v noctalia >/dev/null 2>&1 || exit 0
niri msg overview-state >/dev/null 2>&1 || exit 0   # not running under niri

state="$(niri msg overview-state 2>/dev/null | grep -q 'Overview is open' && echo true || echo false)"
# Started while the overview is already open: hide now -- the stream only reports
# future toggles.
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
