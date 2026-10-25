#!/usr/bin/env bash
set -uo pipefail
LOCK_FORCE=1 LOCK_DRY=1 "$HOME/.local/bin/lock.sh" >/dev/null 2>&1 || true
