#!/usr/bin/env bash
# Lock the session when logind is about to suspend/hibernate.
# A user unit cannot order itself against sleep.target (that unit does not exist in
# the user manager - "added as a dependency to a non-existent unit sleep.target"),
# so watch logind's PrepareForSleep signal on the system bus instead. No root needed.

set -uo pipefail

LOCK="${HOME}/.local/bin/lock.sh"

exec gdbus monitor --system --dest org.freedesktop.login1 --object-path /org/freedesktop/login1 |
while IFS= read -r line; do
    case "$line" in
        *PrepareForSleep*'(true'*) "$LOCK" || true ;;
    esac
done
