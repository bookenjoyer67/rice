#!/usr/bin/env bash
# Trigger helper for the spotport Noctalia widget.
# Detaches the sync so the bar never waits on a multi-minute run, and keeps a
# log the user can tail when a sync misbehaves.
set -u
BIN="$HOME/spotport/.venv/bin/spotport"
CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/spotport"
LOG="$CACHE/sync.log"
LOCK="$CACHE/trigger.lock"
mkdir -p "$CACHE"

# Two lock layers, deliberately: an IPC dispatch is delivered once per bar
# instance, which is how five overlapping runs got spawned. flock -n here
# refuses a second trigger outright; the CLI also takes its own fcntl lock.
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
