#!/usr/bin/env bash
set -uo pipefail

IMG="${1:-}"
shift || true
if [ -z "$IMG" ] || [ ! -f "$IMG" ]; then
    echo "apply-wallpaper: no such image: ${IMG:-<empty>}" >&2
    exit 1
fi
IMG="$(readlink -f "$IMG")"

LINK="$HOME/.config/backgrounds/current-wallpaper"
WALLFX="$HOME/.local/bin/wallfx"
# The widget cut-out runs in the background, long after this script may have
# been overtaken by a second apply that replaces or deletes $IMG. Take private
# bytes of the image the transition is about to use, now that it is known good,
# and give the background task only that copy.
WIDGET_SNAP=""
if [ -x "$WALLFX" ]; then
    WIDGET_SNAP="$(mktemp "${TMPDIR:-/tmp}/wallfx-widget.XXXXXX" 2>/dev/null || true)"
    if [ -n "$WIDGET_SNAP" ] && ! cp --reflink=auto -f "$IMG" "$WIDGET_SNAP" 2>/dev/null; then
        rm -f "$WIDGET_SNAP"
        WIDGET_SNAP=""
    fi
fi

# The transition is drawn, not chosen from awww's list: wallfx-gpu paints the
# character's outline over awww and swaps it underneath (see its header). It
# needs the cut-out maps of the NEW image; `wallfx elige` prepares them once
# per wallpaper (cached by path/size/date) and notifies while it works. With no
# character, no maps, or no old image on screen (startup, hotplug), awww changes
# with a plain fade — the wallpaper must change even if the effect cannot play.
OLD_IMG="$(awww query 2>/dev/null | sed -n 's/.*currently displaying: image: //p' | head -n1)"
# The cache reuses one file name, so a wallpaper that was just re-fetched at the
# same path has already overwritten the picture on screen. fetch-wallpaper.sh and
# the panel's apply.sh keep the old one in previous.img for exactly this.
CACHE_DIR="$HOME/.cache/wallpaper"
PREV="$CACHE_DIR/previous.img"
# The cache reuses one file name per extension, so the picture that was on
# screen may have just been overwritten (same path) or deleted (a .jpg fetch
# removes wallpaper.png). fetch-wallpaper.sh and the panel's apply.sh keep it in
# previous.img; use that copy when the path awww reported is no longer usable.
# Only a copy written by THIS fetch is the picture that was on screen — an older
# one is two generations back and would animate from the wrong wallpaper.
if [ -f "$PREV" ] && ! cmp -s "$PREV" "$IMG"; then
    _d=$(( $(stat -c %Y "$IMG" 2>/dev/null || echo 0) - $(stat -c %Y "$PREV" 2>/dev/null || echo 0) ))
    [ "$_d" -lt 0 ] && _d=$(( -_d ))
    if [ "$_d" -le 10 ]; then
        if [ -z "$OLD_IMG" ] || [ ! -f "$OLD_IMG" ] \
           || [ "$(readlink -f "$OLD_IMG" 2>/dev/null)" = "$IMG" ]; then
            # Take a private copy: previous.img is a single shared name, and a
            # second apply must not replace it while this transition reads it.
            OLD_SNAP="$(mktemp "${TMPDIR:-/tmp}/wallfx-prev.XXXXXX" 2>/dev/null || true)"
            if [ -n "$OLD_SNAP" ] && cp -f "$PREV" "$OLD_SNAP" 2>/dev/null; then
                OLD_IMG="$OLD_SNAP"
                trap 'rm -f "$OLD_SNAP"' EXIT
            else
                [ -n "$OLD_SNAP" ] && rm -f "$OLD_SNAP"
                OLD_SNAP=""
                OLD_IMG="$PREV"
            fi
        fi
    fi
fi
CHOICE=""
ELIGE_RC=0
ASKED=0
# Only ask for the cut-out when it can actually be used (there is a previous
# image on screen): at startup and on a fresh output this would cost seconds
# and then be thrown away, and the desktop would appear late for nothing.
if [ -n "$OLD_IMG" ] && [ -f "$OLD_IMG" ] && [ "$(readlink -f "$OLD_IMG")" != "$IMG" ] \
   && [ -x "$WALLFX" ]; then
    ASKED=1
    CHOICE="$("$WALLFX" elige "$IMG" 2>/dev/null)" || ELIGE_RC=$?
fi
# Only exit 0 + "none" is a genuine "nobody here" for this run. Exit 3 (the
# model could not decide) or an empty answer (we did not ask) decides nothing:
# the cut-out task below asks the model itself and trusts its 0/1/2 result, so
# an undecidable run leaves the existing cut-out alone.
NOBODY=0
if [ "$ASKED" -eq 1 ] && [ "$ELIGE_RC" -eq 0 ] && [ -n "$CHOICE" ] \
   && [ "${CHOICE%% *}" != "perfil" ]; then
    NOBODY=1
fi

PAINTED=0
if [ "$ELIGE_RC" -eq 0 ] && [ "${CHOICE%% *}" = "perfil" ] \
   && [ -n "$OLD_IMG" ] && [ -f "$OLD_IMG" ] \
   && [ "$(readlink -f "$OLD_IMG")" != "$IMG" ] \
   && [ -x "$HOME/.local/bin/wallfx-gpu" ]; then
    read -r _kind CAMPO LINEA <<<"$CHOICE"
    # WALLPAPER_DEBUG=1 keeps the renderer's errors visible (WALLFX_GPU_DEBUG=1
    # makes it talk at all) — without it a silent fallback is indistinguishable
    # from the effect having played.
    _wferr="/dev/null"
    [ "${WALLPAPER_DEBUG:-0}" = "1" ] && _wferr="/dev/stderr"
    if "$HOME/.local/bin/wallfx-gpu" "$OLD_IMG" "$IMG" "$CAMPO" "$LINEA" 2>"$_wferr"; then
        PAINTED=1
    fi
fi
if [ "$PAINTED" -eq 0 ]; then
    if awww img "$IMG" --transition-type fade --transition-duration 0.5 "$@" 2>/dev/null \
       || awww img "$IMG" "$@" 2>/dev/null; then
        PAINTED=1
    elif awww query 2>/dev/null | grep -q "image: $IMG"; then
        PAINTED=1   # already showing this image (awww refuses a no-op re-apply)
    fi
fi
if [ "$PAINTED" -eq 0 ]; then
    echo "apply-wallpaper: awww did not paint $IMG (is awww-daemon running?)" >&2
    [ -n "$WIDGET_SNAP" ] && rm -f "$WIDGET_SNAP"
    exit 1
fi

ln -sf "$IMG" "$LINK"

if command -v matugen >/dev/null 2>&1; then
    if ! matugen image "$IMG" -m dark --prefer darkness --quiet >/dev/null 2>&1; then
        echo "apply-wallpaper: matugen failed — wallpapers will not re-colour" >&2
    fi
fi

if command -v noctalia >/dev/null 2>&1; then
    if ! noctalia msg wallpaper-set "$IMG" >/dev/null 2>&1; then
        echo "apply-wallpaper: noctalia wallpaper-set failed — shell palette stale" >&2
    fi
fi

(
    BRAVE_TPL="$HOME/.local/state/noctalia/community-templates/brave"
    BRAVE_OUT="$HOME/.cache/noctalia/brave-theme/manifest.json"
    if command -v noctalia >/dev/null 2>&1 && [ -f "$BRAVE_TPL/manifest.json" ]; then
        if noctalia theme "$IMG" --scheme "${NOCTALIA_SCHEME:-vibrant}" \
                -r "$BRAVE_TPL/manifest.json:$BRAVE_OUT" >/dev/null 2>&1; then
            bash "$BRAVE_TPL/apply.sh" dark >/dev/null 2>&1 || true
        fi
    fi
) &

if [ -x "$HOME/.local/bin/refresh-lock-backdrops.sh" ]; then
    "$HOME/.local/bin/refresh-lock-backdrops.sh" >/dev/null 2>&1 &
fi

# The character that stays on the wallpaper (the desktop widget reads this
# directory): cut it out of the image that is now on screen. A wallpaper the
# model found nobody in writes a transparent frame instead, so the previous
# wallpaper's character does not linger over the new one. wallfx widget exits
# 0 for a cut-out, 1 when the model found nobody, and 2 when the input or mask
# could not be read: only 0 and 1 are allowed to change what is shown, so a
# file that went away leaves the previous cut-out in place.
(
    if [ "$NOBODY" -eq 1 ]; then
        "$WALLFX" widget --empty >/dev/null 2>&1
    elif [ -n "$WIDGET_SNAP" ]; then
        "$WALLFX" widget "$WIDGET_SNAP" >/dev/null 2>&1
        _widget_status=$?
        if [ "$_widget_status" -eq 1 ]; then
            "$WALLFX" widget --empty >/dev/null 2>&1
        fi
    fi
    [ -n "$WIDGET_SNAP" ] && rm -f "$WIDGET_SNAP"
) &
