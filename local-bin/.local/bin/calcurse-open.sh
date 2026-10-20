#!/usr/bin/env bash
# Handler for text/calendar / text/x-vcalendar / application/x-zerosize:
# import the given .ics into calcurse, then open the calendar UI.
# Noctalia's calendar panel hands the event file here.
#
# Two calcurse quirks this has to work around:
#   1. `calcurse -i <file>` imports and EXITS -- it does not drop into the TUI,
#      so import and interactive start are two separate commands.
#   2. calcurse keeps a pid lock at ~/.local/share/calcurse/.calcurse.pid and
#      refuses to start while it exists, even if the recorded pid is long dead.
#      A stale lock makes the kitty window vanish instantly, which looks exactly
#      like "nothing happened".
set -u

file="${1:-}"
lock="${XDG_DATA_HOME:-$HOME/.local/share}/calcurse/.calcurse.pid"

running_pid() {
  [ -f "$lock" ] || return 1
  local pid
  pid=$(cat "$lock" 2>/dev/null || true)
  [ -n "${pid:-}" ] || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  printf '%s' "$pid"
}

clear_stale_lock() {
  if [ -f "$lock" ] && ! running_pid >/dev/null; then
    rm -f "$lock"
  fi
}

# Another calcurse is already up: bring its window forward instead of failing.
if running_pid >/dev/null; then
  wid=$(niri msg --json windows 2>/dev/null \
    | jq -r '.[] | select((.title // "") | test("Calcurse")) | .id' 2>/dev/null \
    | head -n1)
  if [ -n "${wid:-}" ]; then
    niri msg action focus-window --id "$wid" >/dev/null 2>&1
    exit 0
  fi
fi

clear_stale_lock

if [ -n "$file" ] && [ -f "$file" ]; then
  calcurse --import "$file" >/dev/null 2>&1 || true
  clear_stale_lock   # the one-shot import leaves its pid behind
fi

calcurse
status=$?

# Keep the window open if calcurse refused to start, so the reason is readable.
if [ "$status" -ne 0 ]; then
  echo
  echo "calcurse exited with status $status"
  sleep 10
fi
