#!/usr/bin/env bash
set -u
set -o pipefail

VDIR="${HOME}/.local/share/calcurse-vdir/personal"
OUT="${VDIR}/calcurse.ics"
LOCK="${XDG_RUNTIME_DIR:-/tmp}/calcurse-sync-noctalia.lock"
LOG="${XDG_CACHE_HOME:-$HOME/.cache}/calcurse-sync-noctalia.log"

log() { printf '%s %s\n' "$(date '+%F %T')" "$*" >>"$LOG"; }

mkdir -p "$VDIR"

exec 9>"$LOCK"
if ! flock -n 9; then
    exit 0
fi

tmp="$(mktemp "${VDIR}/.calcurse.XXXXXX")" || exit 1

if ! calcurse -x >"$tmp" 2>>"$LOG"; then
    log "export failed, keeping previous $OUT"
    rm -f "$tmp"
    exit 1
fi

if ! grep -q '^BEGIN:VCALENDAR' "$tmp"; then
    log "export produced no VCALENDAR, keeping previous $OUT"
    rm -f "$tmp"
    exit 1
fi

APTS="${XDG_DATA_HOME:-$HOME/.local/share}/calcurse/apts"
if ! grep -q '^BEGIN:VEVENT' "$tmp" && [ -s "$APTS" ]; then
    log "export had 0 events but $APTS is non-empty, keeping previous $OUT"
    rm -f "$tmp"
    exit 1
fi

chmod 644 "$tmp"
mv -f "$tmp" "$OUT"

if [ ! -f "${VDIR}/displayname" ]; then
    printf 'Calcurse\n' >"${VDIR}/displayname"
fi

log "exported $(grep -c '^BEGIN:VEVENT' "$OUT") event(s) to $OUT"

if command -v noctalia >/dev/null 2>&1; then
    timeout 5 noctalia msg config-reload >/dev/null 2>&1 || true
fi

9>&-

exit 0
