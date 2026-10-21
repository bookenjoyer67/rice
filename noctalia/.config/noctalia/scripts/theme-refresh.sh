#!/usr/bin/env bash
# theme-refresh.sh — force the rice palette to re-derive from the wallpaper
# that is actually on screen, and push it into Brave.
#
# Noctalia re-extracts its shell palette when it is handed an image. Handing it
# the SAME path it already holds is a no-op, so this script copies the current
# wallpaper to one of two stable scratch paths and alternates between them:
# every press is therefore a new path with the same pixels, which makes the
# shell recompute the palette and re-render the theme templates.
#
# What it does:
#   1. matugen regenerates the app palettes (kitty / nvim / starship / palette).
#   2. Alternating copy + `noctalia msg wallpaper-set` -> shell palette
#      (bar, panels, widgets, OSD) is re-extracted from the wallpaper.
#   3. Waits for the async extraction by polling the rendered niri focus ring
#      against the accent the CLI derives from the same image, then runs
#      `noctalia msg templates-apply` so every template renders from the NEW
#      palette (not the previous one).
#   4. Brave: installs the rendered theme files, retries the render if the
#      manifest accent still disagrees with the palette, deletes Chromium's
#      stale "Cached Theme.pak" (it is served at startup and hides manifest
#      changes), and (with --restart-brave) restarts Brave gracefully with
#      --restore-last-session so the theme rebuilds from the new palette.
#   5. Lock backdrops are re-graded in the background.
#
# Deliberately does NOT re-paint with awww: the wallpaper on screen is already
# correct, only the colours derived from it are stale.
set -uo pipefail

# The bar button's left click passes --restart-brave: Chromium only reads a
# theme extension at startup, so the only way to apply a new palette to a
# running Brave is to restart it.
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

# Alternate scratch copy so `wallpaper-set` never receives the path it already
# holds (which it ignores).
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

# 1. app palettes (kitty, nvim, starship, lock-screen palette)
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

# Accent the shell palette should have for this image, from the same generator
# the shell uses. Polling against it tells us when async extraction has landed.
EXPECTED=""
if command -v noctalia >/dev/null 2>&1; then
    EXPECTED="$(noctalia theme "$SUB" --scheme "$SCHEME" "$CLI_MODE" 2>/dev/null \
        | python3 -c 'import json,sys; print(json.load(sys.stdin).get("primary","").lstrip("#"))' 2>/dev/null || true)"
fi

# 2. shell palette: hand the shell an image path it does not already hold
if ! noctalia msg wallpaper-set "$SUB" >/dev/null 2>&1; then
    log "theme-refresh: 'noctalia msg wallpaper-set' failed" >&2
    exit 1
fi

# 3. Palette extraction is asynchronous. When the rendered ring already shows
# the expected accent (same image, palette current) this is a no-op; otherwise
# wait for it before rendering templates, so nothing is one palette behind.
if [ -n "$EXPECTED" ]; then
    for _ in $(seq 1 40); do
        [ "$(ring_primary)" = "$EXPECTED" ] && break
        sleep 0.5
    done
    [ "$(ring_primary)" = "$EXPECTED" ] || log "theme-refresh: palette still catching up after 20s" >&2
else
    sleep 2
fi

# 4. theme templates (niri focus ring, Brave manifest and the app palettes)
noctalia msg templates-apply >/dev/null 2>&1 || log "theme-refresh: templates-apply failed" >&2

# 5. Brave — the community "brave" template renders a Chromium theme manifest.
BRAVE_DIR="$HOME/.config/BraveSoftware/Brave-Browser"
BRAVE_PREFS="$BRAVE_DIR/Default/Preferences"
BRAVE_THEME="$HOME/.local/share/noctalia/brave-theme"
BRAVE_APPLY="$HOME/.local/state/noctalia/community-templates/brave/apply.sh"
BRAVE_LOG="$HOME/.cache/noctalia/brave-theme-apply.log"

# Brave Origin is a separate profile AND a separate binary, but its process is
# also named "brave", so it must be told apart by the real executable path.
BRO_DIR="$HOME/.config/BraveSoftware/Brave-Origin"
BRO_PREFS="$BRO_DIR/Default/Preferences"
BRO_THEME="$HOME/.local/share/noctalia/brave-origin-theme"
BRO_APPLY="$HOME/.local/state/noctalia/community-templates/brave-origin/apply.sh"
BRO_TMPL="$HOME/.local/state/noctalia/community-templates/brave-origin/manifest.json"
BRO_CACHE="$HOME/.cache/noctalia/brave-origin-theme/manifest.json"

# Chromium family, matched by executable path: "brave" owns /opt/brave-bin,
# Brave Origin owns /opt/brave-origin-bin. Both binaries are literally named
# brave, so `pgrep -x brave` matches either browser and cannot be trusted.
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

# Chromium compiles the unpacked theme into "Cached Theme.pak" inside the theme
# directory and serves THAT at startup; editing manifest.json/images does
# nothing until the pak is gone (this is why a manual re-load appeared to fix
# it). Delete it while Brave is closed so the next start rebuilds from the new
# palette.
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

# The rendered manifest's accent must be the palette primary.
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

# --- palette files, per browser: each pack writes only into its own profile ---
if [ -x "$BRAVE_APPLY" ] && [ -d "$BRAVE_DIR" ]; then
    brave_running || clear_theme_cache
    bash "$BRAVE_APPLY" "$MODE" >>"$BRAVE_LOG" 2>&1 || log "theme-refresh: Brave theme apply failed (see $BRAVE_LOG)" >&2

    # If the palette landed after the first render pass, re-render the manifest.
    for _ in 1 2 3; do
        brave_manifest_in_sync && break
        sleep 1
        noctalia msg templates-apply >/dev/null 2>&1 || true
        bash "$BRAVE_APPLY" "$MODE" >>"$BRAVE_LOG" 2>&1 || true
    done
fi

# Brave Origin is not in settings.toml's community_ids, so templates-apply does
# not render it; render this one manifest explicitly from the same palette.
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

# Chromium only reads a theme extension at startup, so a live palette change
# needs the browser to restart. Restart ONE browser at a time, only if it is
# actually up, and relaunch the same one with session restore.
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
    # No restart requested (or nothing running): report per running browser.
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

# 6. lockscreen backdrops (pre-graded per output)
if [ -x "$HOME/.local/bin/refresh-lock-backdrops.sh" ]; then
    "$HOME/.local/bin/refresh-lock-backdrops.sh" >/dev/null 2>&1 &
fi

log "theme-refresh: done"
printf 'Palette re-synced from wallpaper.%s\n' "$BRAVE_MSG"
