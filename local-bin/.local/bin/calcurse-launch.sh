#!/usr/bin/env bash
# Open calcurse for EDITING: focus the running instance if there is one,
# otherwise spawn it in a kitty window.
#
# Used by click targets that are not MIME handoffs (the Noctalia desktop clock,
# keybinds, a terminal command). The text/calendar handler (calcurse-open.sh)
# stays a separate path because it also imports a clicked .ics.
#
# calcurse keeps a pid lock at ~/.local/share/calcurse/.calcurse.pid and refuses
# to start while it exists, even if the recorded pid is dead, so a stale lock has
# to be cleared before launching.
set -u

# invocation trace: proves whether a click target actually reached us
logfile="${XDG_CACHE_HOME:-$HOME/.cache}/calcurse-launch.log"
printf '%s invoked pid=%s HOME=%s kitty=%s\n' "$(date '+%F %T')" "$$" "${HOME:-unset}" "$(command -v kitty || echo MISSING)" >>"$logfile"

lock="${XDG_DATA_HOME:-$HOME/.local/share}/calcurse/.calcurse.pid"

running_pid() {
    [ -f "$lock" ] || return 1
    local pid
    pid=$(cat "$lock" 2>/dev/null || true)
    [ -n "${pid:-}" ] || return 1
    kill -0 "$pid" 2>/dev/null || return 1
    printf '%s' "$pid"
}

calcurse_window() {
    niri msg --json windows 2>/dev/null \
        | jq -r '.[] | select((.title // "") | test("Calcurse")) | .id' 2>/dev/null \
        | head -n1
}

if running_pid >/dev/null; then
    wid=$(calcurse_window)
    if [ -n "${wid:-}" ]; then
        # already open somewhere: bring that window forward, do not start a second
        niri msg action focus-window --id "$wid" >/dev/null 2>&1
        printf '%s focused existing window %s\n' "$(date '+%F %T')" "$wid" >>"${XDG_CACHE_HOME:-$HOME/.cache}/calcurse-launch.log"
        exit 0
    fi
    notify-send "Calcurse" "Already running without a window; quit it from a terminal (pid $(running_pid))" 2>/dev/null || true
    exit 1
fi

# stale lock from a one-shot import: safe to drop, nothing is running
if [ -f "$lock" ]; then
    rm -f "$lock"
fi

# Launch through the COMPOSITOR, not as a child of us: a kitty started straight
# from the shell (or from a plugin's runAsync) can die on startup -- observed
# status 139 -- because it inherits a non-session environment. `niri msg action
# spawn` hands the child the real session env (WAYLAND_DISPLAY, NIRI_SOCKET, ...),
# which is the same path spawn-at-startup uses.
if command -v niri >/dev/null 2>&1; then
    niri msg action spawn -- kitty --title Calcurse "$HOME/.local/bin/calcurse-open.sh" \
        >>"$logfile" 2>&1
    printf '%s spawn via niri: status=%s\n' "$(date '+%F %T')" "$?" >>"$logfile"
    exit 0
fi

exec kitty --title Calcurse "$HOME/.local/bin/calcurse-open.sh"
