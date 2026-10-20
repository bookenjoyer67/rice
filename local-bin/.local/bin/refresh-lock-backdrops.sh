#!/usr/bin/env bash
# Pre-render the lockscreen backdrops for every enabled output.
# Called from apply-wallpaper.sh (the wallpaper funnel) so that locking is instant
# right after a wallpaper change; lock.sh itself regenerates on demand if this has
# not run yet.
set -uo pipefail
LOCK_FORCE=1 LOCK_DRY=1 "$HOME/.local/bin/lock.sh" >/dev/null 2>&1 || true
