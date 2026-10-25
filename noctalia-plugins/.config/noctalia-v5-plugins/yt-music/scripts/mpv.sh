#!/usr/bin/env bash

DIR="/tmp/yt-music"
PIDFILE="$DIR/mpv.pid"
SOCK="$DIR/mpv.sock"
GENFILE="$DIR/mpv.gen"

DUMMY="av://lavfi:anullsrc=r=48000:cl=stereo"
mkdir -p "$DIR"

NC_N=0
if command -v nc >/dev/null 2>&1; then
  _ncerr=$(printf '' | nc -N -w1 "$DIR/nc-probe-never" 2>&1)
  case "$_ncerr" in *nvalid*|*sage*|*llegal*) ;; *) NC_N=1 ;; esac
fi

nc_send() {   # $1=sock $2=timeout
  if [ "$NC_N" = 1 ]; then
    nc -U -N -w"$2" "$1"
  else
    nc -U -w"$2" "$1"
  fi
}
nc_check() {   # $1=sock $2=timeout
  printf '' | nc_send "$1" "$2" >/dev/null 2>&1
}

mpv_play() {   # $1=volume $2=url_file $3=title_file $4=cover_file(optional)
  local vol="${1:-100}"
  local cover_opts=""
  [ -n "$4" ] && [ -f "$4" ] && cover_opts="--cover-art-file=$4"

  URL=$(cat "$2")
  TITLE=$(cat "$3" 2>/dev/null)
  START_MS=$(date +%s%N)
  if command -v flock >/dev/null 2>&1; then
    exec 9>"$DIR/mpv.lock"
    flock 9 || exit 1
  fi
  if [ -f "$PIDFILE" ]; then
    PREV=$(cat "$PIDFILE" 2>/dev/null)
    [ -n "$PREV" ] && kill "$PREV" >/dev/null 2>&1
    rm -f "$PIDFILE"
  fi
  pkill -f "input-ipc-server=$SOCK" >/dev/null 2>&1
  for i in $(seq 1 20); do
    pgrep -f "input-ipc-server=.*mpv[.]sock" >/dev/null 2>&1 || break
    sleep 0.1
  done
  pkill -9 -f "input-ipc-server=$SOCK" >/dev/null 2>&1
  sleep 0.1
  rm -f "$SOCK"
  nohup mpv "$DUMMY" "$URL" "$DUMMY" --playlist-start=1 \
    --no-video --vo=null --vd=null --audio-display=no --no-osc --no-osd-bar \
    --demuxer-max-bytes=20M --demuxer-readahead-secs=60 --really-quiet --no-terminal \
    --keep-open=always --pause=no \
    --force-media-title="$TITLE" \
    $cover_opts \
    --input-ipc-server="$SOCK" --ao=pulse,pipewire,alsa,auto \
    >/dev/null 2>&1 9>&- &
  echo $! > "$PIDFILE"
  echo $(( $(cat "$GENFILE" 2>/dev/null || echo 0) + 1 )) > "$GENFILE"
  for i in 1 2 3 4 5 6 7 8 9 10; do
    [ -S "$SOCK" ] && nc_check "$SOCK" 1 && break
    sleep 0.2
  done
  [ -S "$SOCK" ] && {
    echo "READY=1 MS=$(( ($(date +%s%N) - START_MS) / 1000000 ))"
    printf '{"command":["set_property","volume",%s]}\n' "$vol" | nc_send "$SOCK" 1 >/dev/null 2>&1
  }
  if command -v flock >/dev/null 2>&1; then
    flock -u 9 2>/dev/null
    exec 9>&- 2>/dev/null
  fi
}

mpv_send() {   # $1=payload json
  local payload="$1"
  [ -S "$SOCK" ] || exit 0
  TMP=$(mktemp)
  printf '%s\n' "$payload" > "$TMP"
  nc_send "$SOCK" 2 < "$TMP" >/dev/null 2>&1
  rm -f "$TMP"
}

mpv_kill() {
  if command -v flock >/dev/null 2>&1; then
    exec 9>"$DIR/mpv.lock"
    flock 9 || exit 1
  fi
  if [ -f "$PIDFILE" ]; then
    PREV=$(cat "$PIDFILE" 2>/dev/null)
    [ -n "$PREV" ] && kill -9 "$PREV" >/dev/null 2>&1
    rm -f "$PIDFILE"
  fi
  pkill -9 -f "input-ipc-server=$SOCK" >/dev/null 2>&1
  echo $(( $(cat "$GENFILE" 2>/dev/null || echo 0) + 1 )) > "$GENFILE"
  rm -f "$SOCK"
}

mpv_stream() {
  local pid gen
  [ -S "$SOCK" ] || exit 0
  pid=$(cat "$PIDFILE" 2>/dev/null)
  [ -n "$pid" ] || exit 0
  gen=$(cat "$GENFILE" 2>/dev/null)
  while [ -S "$SOCK" ] && kill -0 "$pid" 2>/dev/null && [ "$(cat "$GENFILE" 2>/dev/null)" = "$gen" ]; do
    timeout 120 bash <<EOF
{
echo '{"command":["observe_property",1,"pause"]}'
echo '{"command":["observe_property",2,"duration"]}'
echo '{"command":["observe_property",3,"eof-reached"]}'
echo '{"command":["observe_property",4,"audio-codec-name"]}'
echo '{"command":["observe_property",5,"audio-params/samplerate"]}'
echo '{"command":["observe_property",6,"playlist-pos"]}'
i=0
while [ -S "$SOCK" ] && kill -0 "$pid" 2>/dev/null && [ "\$(cat "$GENFILE" 2>/dev/null)" = "$gen" ]; do
  echo '{"command":["get_property","time-pos"],"request_id":100}'
  if [ \$((i % 10)) -eq 0 ]; then
    echo '{"command":["get_property","audio-bitrate"],"request_id":200}'
  fi
  i=\$((i + 1))
  sleep 1
done
} | nc -U "$SOCK"
EOF
    sleep 1
  done
}

fn="${1:?fn required}"; shift
type -t "$fn" >/dev/null 2>&1 || { echo "unknown fn: $fn" >&2; exit 1; }
"$fn" "$@"
