#!/usr/bin/env bash
# calcurse -> Noctalia calendar bridge.
# Exports calcurse's whole calendar as iCal into a vdir collection that
# Noctalia's calendar service reads through its vdir account ("Calcurse"),
# then nudges the shell so the calendar tab/widget refreshes immediately.
set -u
set -o pipefail

VDIR="${HOME}/.local/share/calcurse-vdir/personal"
OUT="${VDIR}/calcurse.ics"
LOCK="${XDG_RUNTIME_DIR:-/tmp}/calcurse-sync-noctalia.lock"
LOG="${XDG_CACHE_HOME:-$HOME/.cache}/calcurse-sync-noctalia.log"

log() { printf '%s %s\n' "$(date '+%F %T')" "$*" >>"$LOG"; }

mkdir -p "$VDIR"

# serialize: calcurse saves quickly, hook can fire back to back
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

# calcurse -x emits a VCALENDAR wrapper even with zero events; refuse a
# truncated/empty file so the shell never sees a half-written calendar.
if ! grep -q '^BEGIN:VCALENDAR' "$tmp"; then
    log "export produced no VCALENDAR, keeping previous $OUT"
    rm -f "$tmp"
    exit 1
fi

# A zero-event export while apts still holds appointments means we read a
# half-written/foreign data file: keep the previous export instead of blanking
# the shell's calendar. (Genuinely deleting everything leaves apts empty too.)
APTS="${XDG_DATA_HOME:-$HOME/.local/share}/calcurse/apts"
if ! grep -q '^BEGIN:VEVENT' "$tmp" && [ -s "$APTS" ]; then
    log "export had 0 events but $APTS is non-empty, keeping previous $OUT"
    rm -f "$tmp"
    exit 1
fi

chmod 644 "$tmp"
mv -f "$tmp" "$OUT"

# collection label shown by Noctalia (vdir displayname file)
if [ ! -f "${VDIR}/displayname" ]; then
    printf 'Calcurse\n' >"${VDIR}/displayname"
fi

log "exported $(grep -c '^BEGIN:VEVENT' "$OUT") event(s) to $OUT"

# trigger a refetch of the vdir account (config-reload re-inits the calendar service)
if command -v noctalia >/dev/null 2>&1; then
    timeout 5 noctalia msg config-reload >/dev/null 2>&1 || true
fi

# close the lock fd for any backgrounded child
9>&-

exit 0
