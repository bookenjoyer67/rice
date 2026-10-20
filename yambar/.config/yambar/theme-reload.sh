#!/usr/bin/env bash
# Rebuild the per-monitor yambar configs with the new palette and restart the
# running bars. Called from matugen's post_hook on every wallpaper change.
#
# Why a restart at all: yambar has no live config reload. It installs no
# SIGHUP / SIGUSR1 handler (the only signal names in the binary are SIGINT and
# SIGTERM, and SIGUSR1's default action would simply kill it), so new colours
# mean respawning the bar. The gap is well under a second and every module
# re-polls on start.
#
# Why the restart goes through `niri msg action spawn`: that is exactly how the
# session starts the bars (`spawn-at-startup bash yambar-monitor.sh <OUTPUT>`),
# so the new instance gets the session environment and is detached from the
# caller's process tree. Restarting with a plain background `setsid` from a
# post_hook left the bar dead (yambar exited on a Wayland refresh error).
set -uo pipefail

WRAP="$HOME/.config/yambar/yambar-monitor.sh"
COLORS="$HOME/.config/yambar/colors.yml"
STAMP="$HOME/.cache/yambar/.last-applied-palette"

[ -x "$WRAP" ] || exit 0

# One run at a time. A wallpaper switch can fire this while the previous restart
# is still in flight, and two concurrent restarts -- one pkill-ing a bar the
# other has just started -- leave yambar dead. Serialising also coalesces a burst
# of switches: a run that takes the lock after another has already applied the
# current palette simply exits.
LOCK="$HOME/.cache/yambar/.theme-reload.lock"
mkdir -p "$(dirname "$LOCK")"
exec 9>"$LOCK"
flock -w 15 9 || exit 0

# Palette unchanged since the last restart -> don't churn the bar.
if [ -f "$COLORS" ] && [ -f "$STAMP" ] && cmp -s "$COLORS" "$STAMP"; then
    exit 0
fi

# Which bars are running, and on which output? The output name is encoded in the
# config path each instance was started with (.../yambar-<OUTPUT>.yml).
running_pids() { pgrep -x yambar; }

mon_of_pid() {
    tr '\0' '\n' < "/proc/$1/cmdline" 2>/dev/null \
        | sed -n 's#.*/yambar-\(.*\)\.yml#\1#p' | head -n1
}

count_for() {
    local pid n=0
    for pid in $(running_pids); do
        [ "$(mon_of_pid "$pid")" = "$1" ] && n=$((n + 1))
    done
    printf '%s' "$n"
}

mons=()
for pid in $(running_pids); do
    mon="$(mon_of_pid "$pid")"
    [ -n "$mon" ] && mons+=("$mon")
done

# Rebuild every config we might need: all enabled outputs (so the next session
# picks the palette up) plus wherever a bar is actually running.
targets="$(niri msg --json outputs 2>/dev/null \
           | jq -r 'to_entries[] | select(.value.logical != null) | .key')"
for mon in ${mons[@]+"${mons[@]}"}; do
    targets="${targets}"$'\n'"${mon}"
done

while IFS= read -r mon; do
    [ -n "$mon" ] || continue
    bash "$WRAP" --build "$mon" 2>/dev/null || true
done <<< "$targets"

if [ -f "$COLORS" ]; then
    mkdir -p "$(dirname "$STAMP")"
    cp -f "$COLORS" "$STAMP" 2>/dev/null || true
fi

# No bar running (matugen called from outside the session): the configs above
# are already fresh, that is all that was needed.
[ ${#mons[@]} -eq 0 ] && exit 0

start_bar() {
    if [ "$USE_NIRI" = 1 ]; then
        niri msg action spawn -- bash "$WRAP" "$1" >/dev/null 2>&1 && return 0
    fi
    setsid bash "$WRAP" "$1" 9>&- >/dev/null 2>&1 &
}

USE_NIRI=0
niri msg --json version >/dev/null 2>&1 && USE_NIRI=1

pkill -x yambar
for _ in $(seq 1 30); do
    [ -z "$(running_pids)" ] && break
    sleep 0.1
done

for mon in "${mons[@]}"; do
    start_bar "$mon"
done

# The bar is the only place this desktop shows system status, so verify it came
# back and retry the stragglers rather than leave the user with no bar.
sleep 1.5
for mon in "${mons[@]}"; do
    [ "$(count_for "$mon")" -ge 1 ] && continue
    setsid bash "$WRAP" "$mon" 9>&- >/dev/null 2>&1 &
done
