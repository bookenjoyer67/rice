#!/usr/bin/env bash
set -u
BIN="$HOME/spotport/.venv/bin/spotport"
CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/spotport"
LOG="$CACHE/sync.log"
LOCK="$CACHE/trigger.lock"
mkdir -p "$CACHE"

guard() {
  if ! flock -n "$LOCK" true 2>/dev/null; then
    echo "$(date -Is) trigger: already running, ignored ($1)" >>"$LOG"
    exit 0
  fi
}

case "${1:-}" in
  sync)
    guard sync
    setsid nohup flock -n "$LOCK" "$BIN" sync >>"$LOG" 2>&1 </dev/null &
    ;;
  dry)
    guard dry
    setsid nohup flock -n "$LOCK" "$BIN" sync --dry-run >>"$LOG" 2>&1 </dev/null &
    ;;
  status)
    "$BIN" status 2>&1
    ;;
  review)
    "$BIN" review --limit 5 2>&1
    ;;
  *)
    echo "usage: $0 {sync|dry|status|review}" >&2
    exit 2
    ;;
esac
exit 0
