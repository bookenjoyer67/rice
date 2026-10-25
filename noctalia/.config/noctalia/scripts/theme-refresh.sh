#!/usr/bin/env bash
set -uo pipefail

RESTART_BRAVE=0
case "${1:-}" in
    --restart-brave) RESTART_BRAVE=1 ;;
esac

log() { printf '%s %s\n' "$(date '+%F %T')" "$*"; }

CACHE="$HOME/.cache/wallpaper"
A="$CACHE/refresh-a.jpg"
B="$CACHE/refresh-b.jpg"

WALL="$(noctalia msg wallpaper-get 2>/dev/null || true)"
if [ -z "$WALL" ] || [ ! -f "$WALL" ]; then
    WALL="$(readlink -f "$HOME/.config/backgrounds/current-wallpaper" 2>/dev/null || true)"
fi
if [ -z "$WALL" ] || [ ! -f "$WALL" ]; then
    log "theme-refresh: no wallpaper to sample (${WALL:-<empty>})" >&2
    exit 1
fi

if [ "$WALL" = "$A" ]; then
    SUB="$B"
else
    SUB="$A"
fi
mkdir -p "$CACHE"
if ! cp -f "$WALL" "$SUB"; then
    log "theme-refresh: could not copy $WALL -> $SUB" >&2
    exit 1
fi

log "theme-refresh: re-syncing palette from $WALL (via $SUB)"

if command -v matugen >/dev/null 2>&1; then
    matugen image "$SUB" -m dark --prefer darkness --quiet 2>/dev/null || true
fi

MODE="$(noctalia msg theme-mode-get 2>/dev/null || echo dark)"
case "$MODE" in light|dark) ;; *) MODE=dark ;; esac
SCHEME="$(noctalia msg color-scheme-get 2>/dev/null | awk 'NR==1{print $2}')"
[ -n "${SCHEME:-}" ] || SCHEME=vibrant
CLI_MODE=--dark
[ "$MODE" = light ] && CLI_MODE=--light

RING="$HOME/.config/niri/focus-ring.kdl"
ring_primary() {
    grep -oE 'active-gradient[[:space:]]+from="#[0-9a-fA-F]{6}"' "$RING" 2>/dev/null \
        | head -1 | grep -oE '[0-9a-fA-F]{6}'
}

EXPECTED=""
if command -v noctalia >/dev/null 2>&1; then
    EXPECTED="$(noctalia theme "$SUB" --scheme "$SCHEME" "$CLI_MODE" 2>/dev/null \
        | python3 -c 'import json,sys; print(json.load(sys.stdin).get("primary","").lstrip("#"))' 2>/dev/null || true)"
fi

if ! noctalia msg wallpaper-set "$SUB" >/dev/null 2>&1; then
    log "theme-refresh: 'noctalia msg wallpaper-set' failed" >&2
    exit 1
fi

if [ -n "$EXPECTED" ]; then
    for _ in $(seq 1 40); do
        [ "$(ring_primary)" = "$EXPECTED" ] && break
        sleep 0.5
    done
    [ "$(ring_primary)" = "$EXPECTED" ] || log "theme-refresh: palette still catching up after 20s" >&2
else
    sleep 2
fi

noctalia msg templates-apply >/dev/null 2>&1 || log "theme-refresh: templates-apply failed" >&2

BRAVE_DIR="$HOME/.config/BraveSoftware/Brave-Browser"
BRAVE_PREFS="$BRAVE_DIR/Default/Preferences"
BRAVE_THEME="$HOME/.local/share/noctalia/brave-theme"
BRAVE_APPLY="$HOME/.local/state/noctalia/community-templates/brave/apply.sh"
BRAVE_LOG="$HOME/.cache/noctalia/brave-theme-apply.log"

BRO_DIR="$HOME/.config/BraveSoftware/Brave-Origin"
BRO_PREFS="$BRO_DIR/Default/Preferences"
BRO_THEME="$HOME/.local/share/noctalia/brave-origin-theme"
BRO_APPLY="$HOME/.local/state/noctalia/community-templates/brave-origin/apply.sh"
BRO_TMPL="$HOME/.local/state/noctalia/community-templates/brave-origin/manifest.json"
BRO_CACHE="$HOME/.cache/noctalia/brave-origin-theme/manifest.json"

browser_pids() {
    local kind="$1" d pid exe
    for d in /proc/[0-9]*; do
        pid="${d#/proc/}"
        [ -O "$d" ] || continue
        exe="$(readlink -f "$d/exe" 2>/dev/null)" || continue
        case "$kind:$exe" in
            brave:*/brave-bin/*)  printf '%s\n' "$pid" ;;
            origin:*/brave-origin-bin/*) printf '%s\n' "$pid" ;;
        esac
    done
}

browser_alive() {
    [ -n "$(browser_pids "$1")" ]
}

brave_running() { browser_alive brave; }
origin_running() { browser_alive origin; }

clear_theme_cache() {
    rm -f "$BRAVE_THEME/Cached Theme.pak"
}

theme_loaded_in() {
    local prefs="$1" dir="$2"
    [ -f "$prefs" ] || return 1
    python3 - "$prefs" "$dir" >/dev/null 2>&1 <<'PY'
import json, sys
from pathlib import Path

prefs, theme_dir = Path(sys.argv[1]), str(Path(sys.argv[2]).resolve())
data = json.loads(prefs.read_text())
ext = data.get("extensions", {})
pack = str(Path(ext.get("theme", {}).get("pack")).resolve()) if ext.get("theme", {}).get("pack") else ""
if pack == theme_dir:
    raise SystemExit(0)
for entry in (ext.get("settings") or {}).values():
    if not isinstance(entry, dict):
        continue
    path = entry.get("path") or ""
    if path and str(Path(path).resolve()) == theme_dir:
        raise SystemExit(0)
    if (entry.get("manifest") or {}).get("name") == "Noctalia":
        raise SystemExit(0)
raise SystemExit(1)
PY
}

brave_theme_loaded()  { theme_loaded_in "$BRAVE_PREFS" "$BRAVE_THEME"; }
origin_theme_loaded() { theme_loaded_in "$BRO_PREFS" "$BRO_THEME"; }

manifest_in_sync() {
    local manifest="$1"
    [ -n "$EXPECTED" ] && [ -f "$manifest" ] || return 0
    python3 - "$manifest" "$EXPECTED" >/dev/null 2>&1 <<'PY'
import json, sys
from pathlib import Path

colors = json.loads(Path(sys.argv[1]).read_text()).get("theme", {}).get("colors", {})
accent = colors.get("ntp_link")
want = sys.argv[2].lower()
if not (isinstance(accent, list) and len(accent) == 3):
    raise SystemExit(0)
raise SystemExit(0 if ("%02x%02x%02x" % tuple(int(c) for c in accent[:3])) == want else 1)
PY
}

brave_manifest_in_sync() { manifest_in_sync "$BRAVE_THEME/manifest.json"; }

BRAVE_MSG=""
mkdir -p "$(dirname "$BRAVE_LOG")"

if [ -x "$BRAVE_APPLY" ] && [ -d "$BRAVE_DIR" ]; then
    brave_running || clear_theme_cache
    bash "$BRAVE_APPLY" "$MODE" >>"$BRAVE_LOG" 2>&1 || log "theme-refresh: Brave theme apply failed (see $BRAVE_LOG)" >&2

    for _ in 1 2 3; do
        brave_manifest_in_sync && break
        sleep 1
        noctalia msg templates-apply >/dev/null 2>&1 || true
        bash "$BRAVE_APPLY" "$MODE" >>"$BRAVE_LOG" 2>&1 || true
    done
fi

if [ -x "$BRO_APPLY" ] && [ -d "$BRO_DIR" ]; then
    mkdir -p "$(dirname "$BRO_CACHE")"
    noctalia theme "$SUB" --scheme "$SCHEME" "$CLI_MODE" -r "$BRO_TMPL:$BRO_CACHE" >/dev/null 2>&1 \
        || log "theme-refresh: Brave Origin manifest render failed" >&2
    origin_running || rm -f "$BRO_THEME/Cached Theme.pak"
    bash "$BRO_APPLY" "$MODE" >>"$BRAVE_LOG" 2>&1 \
        || log "theme-refresh: Brave Origin theme apply failed (see $BRAVE_LOG)" >&2
fi

browser_label() {
    case "$1" in
        brave)  printf 'Brave' ;;
        origin) printf 'Brave Origin' ;;
    esac
}

restart_one() {
    local kind="$1" launch="$2" apply="$3" theme="$4" name pids
    name="$(browser_label "$kind")"
    pids="$(browser_pids "$kind")"
    [ -n "$pids" ] || return 0
    log "theme-refresh: restarting $name for the new palette"
    kill -TERM $pids 2>/dev/null || true
    for _ in $(seq 1 40); do
        browser_alive "$kind" || break
        sleep 0.5
    done
    if browser_alive "$kind"; then
        BRAVE_MSG="$BRAVE_MSG $name did not exit; restart it by hand to apply the palette."
        return 0
    fi
    sleep 1
    rm -f "$theme/Cached Theme.pak"
    if [ -x "$apply" ]; then
        bash "$apply" "$MODE" >>"$BRAVE_LOG" 2>&1 || true
    fi
    setsid nohup "$launch" --restore-last-session >/dev/null 2>&1 &
    sleep 3
    if browser_alive "$kind"; then
        BRAVE_MSG="$BRAVE_MSG $name restarted with the new palette."
    else
        BRAVE_MSG="$BRAVE_MSG $name was closed but did not relaunch — start it again by hand."
    fi
}

if [ "${RESTART_BRAVE:-0}" = "1" ] && { brave_running || origin_running; }; then
    if brave_running; then
        restart_one brave /usr/bin/brave "$BRAVE_APPLY" "$BRAVE_THEME"
    fi
    if origin_running; then
        restart_one origin /usr/bin/brave-origin "$BRO_APPLY" "$BRO_THEME"
    fi
else
    for kind in brave origin; do
        browser_alive "$kind" || continue
        name="$(browser_label "$kind")"
        case "$kind" in
            brave)  theme_dir="$BRAVE_THEME"; scheme_url='brave://extensions' ;;
            origin) theme_dir="$BRO_THEME";   scheme_url='brave://extensions' ;;
        esac
        if [ "$kind" = brave ]; then
            loaded=0; brave_theme_loaded || loaded=1
        else
            loaded=0; origin_theme_loaded || loaded=1
        fi
        if [ "$loaded" = 1 ]; then
            BRAVE_MSG="$BRAVE_MSG Load $name's theme once: $scheme_url → Developer mode → Load unpacked → $theme_dir — then restart $name."
        else
            BRAVE_MSG="$BRAVE_MSG Restart $name to apply it (or click the refresh button)."
        fi
    done
    [ -n "$BRAVE_MSG" ] || BRAVE_MSG=" Brave opens with it next launch."
fi

if [ -x "$HOME/.local/bin/refresh-lock-backdrops.sh" ]; then
    "$HOME/.local/bin/refresh-lock-backdrops.sh" >/dev/null 2>&1 &
fi

log "theme-refresh: done"
printf 'Palette re-synced from wallpaper.%s\n' "$BRAVE_MSG"
