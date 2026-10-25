#!/usr/bin/env bash
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

if [ "$status" -ne 0 ]; then
  echo
  echo "calcurse exited with status $status"
  sleep 10
fi
