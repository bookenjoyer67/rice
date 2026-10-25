#!/usr/bin/env bash
# Toggle screen recording of the FOCUSED output with wf-recorder.
#
#   ~/.config/niri/scripts/record-screen.sh          # toggle: start / stop
#   REC_AUDIO=0 ...                                  # no desktop audio
#   REC_OUTPUT=DP-1 ...                              # record a specific output
#   REC_CODEC=h264_nvenc ...                         # GPU encode (default libx264)
#
# Stop = SIGINT to wf-recorder, which is what finalises the mp4.
set -uo pipefail

OUTDIR="$HOME/Videos/Recordings"
LOGFILE="${XDG_RUNTIME_DIR:-/tmp}/wf-recorder.log"
PIDFILE="${XDG_RUNTIME_DIR:-/tmp}/wf-recorder.pid"
mkdir -p "$OUTDIR"

say() { command -v notify-send >/dev/null 2>&1 && notify-send -a Record "$@"; }

stop_recording() {
    pid="$1"
    kill -INT "$pid" 2>/dev/null
    for _ in $(seq 1 100); do
        kill -0 "$pid" 2>/dev/null || break
        sleep 0.1
    done
    rm -f "$PIDFILE"
    last=$(ls -t "$OUTDIR"/recording-*.mp4 2>/dev/null | head -n1)
    if [ -n "$last" ]; then
        dur=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$last" 2>/dev/null)
        say "Recording saved" "$(basename "$last")  ${dur}s"
        printf '%s\n' "$last"
    else
        say "Recording stopped" "no file written, see $LOGFILE"
    fi
}

# Already recording? -> stop.
if [ -s "$PIDFILE" ]; then
    oldpid=$(cat "$PIDFILE")
    if kill -0 "$oldpid" 2>/dev/null; then
        stop_recording "$oldpid"
        exit 0
    fi
    rm -f "$PIDFILE"
fi

# Which output? focused by default.
output="${REC_OUTPUT:-}"
if [ -z "$output" ]; then
    output=$(niri msg --json focused-output 2>/dev/null | jq -r '.name // empty')
fi

file="$OUTDIR/recording-$(date +%Y-%m-%d_%H-%M-%S).mp4"
codec="${REC_CODEC:-libx264}"
args=(-f "$file" -c "$codec")
case "$codec" in
    libx264)  args+=(-p preset=veryfast -p crf=21) ;;
esac
if [ -n "$output" ]; then
    args+=(-o "$output")
fi

# Desktop audio (default sink monitor) unless REC_AUDIO=0.
if [ "${REC_AUDIO:-1}" != "0" ]; then
    sink=$(pactl get-default-sink 2>/dev/null)
    if [ -n "$sink" ]; then
        args+=("--audio=${sink}.monitor")
    fi
fi

setsid wf-recorder "${args[@]}" >"$LOGFILE" 2>&1 &
pid=$!
echo "$pid" >"$PIDFILE"

sleep 1
if ! kill -0 "$pid" 2>/dev/null; then
    rm -f "$PIDFILE"
    say "Recording failed" "$(tail -n 2 "$LOGFILE" | tr '\n' ' ')"
    echo "failed: $(tail -n 3 "$LOGFILE")" >&2
    exit 1
fi

say "Recording ${output:-screen}" "$(basename "$file") — Mod+Shift+R to stop"
printf 'recording %s (pid %s)\n' "$file" "$pid"
