#!/usr/bin/env bash
set -euo pipefail

DER="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
APPLY="$DER/apply-wallpaper.sh"
FETCH="$DER/fetch-wallpaper.sh"

img="$(bash "$FETCH" 2>/dev/null || true)"
if [ -n "$img" ]; then
    bash "$APPLY" "$img"
fi
