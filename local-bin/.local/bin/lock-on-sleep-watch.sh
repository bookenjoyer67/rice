#!/usr/bin/env bash

set -uo pipefail

LOCK="${HOME}/.local/bin/lock.sh"

exec gdbus monitor --system --dest org.freedesktop.login1 --object-path /org/freedesktop/login1 |
while IFS= read -r line; do
    case "$line" in
        *PrepareForSleep*'(true'*) "$LOCK" || true ;;
    esac
done
