#!/usr/bin/env bash
set -uo pipefail

RT="${XDG_RUNTIME_DIR:-/tmp}"
PIDFILE="$RT/wf-recorder.pid"
OUTDIR="$HOME/Videos/Recordings"

elapsed_of() {
    local p="$1" start up hz
    [ -r "/proc/$p/stat" ] || { echo 0; return; }
    start=$(awk '{print $22}' "/proc/$p/stat" 2>/dev/null)
    up=$(cut -d' ' -f1 /proc/uptime 2>/dev/null)
    hz=$(getconf CLK_TCK 2>/dev/null || echo 100)
    awk -v u="$up" -v s="$start" -v h="$hz" \
        'BEGIN { e = u - s / h; if (e < 0) e = 0; printf "%d", e }'
}

last_file() { ls -t "$OUTDIR"/recording-*.* 2>/dev/null | head -n1; }

pid=""
if [ -s "$PIDFILE" ]; then
    pid=$(cat "$PIDFILE" 2>/dev/null)
    kill -0 "$pid" 2>/dev/null || pid=""
fi
if [ -z "$pid" ]; then
    pid=$(pgrep -x wf-recorder 2>/dev/null | head -n1)
fi
if [ -n "$pid" ]; then
    printf 'rec\t%s\t%s\n' "$(elapsed_of "$pid")" "$(last_file)"
    exit 0
fi

for opid in $(pgrep -x obs 2>/dev/null); do
    for fd in /proc/$opid/fd/*; do
        target=$(readlink "$fd" 2>/dev/null) || continue
        case "$target" in
            *.mp4 | *.mkv | *.flv | *.mov | *.ts) ;;
            *) continue ;;
        esac
        case "$target" in
            *[Rr]eplay*) continue ;;
        esac
        flags=$(awk '/^flags:/ {print $2}' "/proc/$opid/fdinfo/${fd##*/}" 2>/dev/null)
        [ -n "${flags:-}" ] || continue
        acc=$((8#$flags & 3))
        [ "$acc" -ne 0 ] || continue
        printf 'rec\t0\t%s\n' "$target"
        exit 0
    done
done

exit 0
