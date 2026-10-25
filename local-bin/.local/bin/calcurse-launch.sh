#!/usr/bin/env bash
set -u

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
        niri msg action focus-window --id "$wid" >/dev/null 2>&1
        printf '%s focused existing window %s\n' "$(date '+%F %T')" "$wid" >>"${XDG_CACHE_HOME:-$HOME/.cache}/calcurse-launch.log"
        exit 0
    fi
    notify-send "Calcurse" "Already running without a window; quit it from a terminal (pid $(running_pid))" 2>/dev/null || true
    exit 1
fi

if [ -f "$lock" ]; then
    rm -f "$lock"
fi

if command -v niri >/dev/null 2>&1; then
    niri msg action spawn -- kitty --title Calcurse "$HOME/.local/bin/calcurse-open.sh" \
        >>"$logfile" 2>&1
    printf '%s spawn via niri: status=%s\n' "$(date '+%F %T')" "$?" >>"$logfile"
    exit 0
fi

exec kitty --title Calcurse "$HOME/.local/bin/calcurse-open.sh"
