#!/usr/bin/env bash
# Shared wallpaper-cache bookkeeping, sourced by fetch-wallpaper.sh and the
# wallpaper-browser's apply.sh. The caller sets CACHE_DIR (and may override
# UA / MIN_BYTES) before sourcing; these functions never touch the desktop on
# their own.

# The first wallpaper.<ext> in the cache, if any.
wc_cached() {
    ls "$CACHE_DIR"/wallpaper.* 2>/dev/null | head -n1
}

# The image awww says it is displaying, unresolved.
wc_shown() {
    awww query 2>/dev/null | sed -n 's/.*currently displaying: image: //p' | head -n1
}

# Drop every other wallpaper.<ext>; the caller has already published EXT.
wc_prune() {
    local ext="${1-}"
    find "$CACHE_DIR" -maxdepth 1 -type f -name 'wallpaper.*' \
        ! -name "wallpaper.$ext" -delete 2>/dev/null || true
}

# Record the image that is actually kept/displayed: current.id, history and
# recent. Call this AFTER the download passed its checks (or was published),
# never per attempt.
wc_record() {
    local id="${1-}" ts
    [ -n "$id" ] || return 0
    ts="$(date +%s)"
    printf '%s\n' "$id" > "$CACHE_DIR/current.id"
    printf '%s\t%s\n' "$id" "$ts" >> "$CACHE_DIR/history"
    tail -n 1000 "$CACHE_DIR/history" > "$CACHE_DIR/history.tmp" 2>/dev/null \
        && mv "$CACHE_DIR/history.tmp" "$CACHE_DIR/history" || true
    grep -qxF -- "$id" "$CACHE_DIR/recent" 2>/dev/null \
        || printf '%s\n' "$id" >> "$CACHE_DIR/recent"
    tail -n 30 "$CACHE_DIR/recent" > "$CACHE_DIR/recent.tmp" 2>/dev/null \
        && mv "$CACHE_DIR/recent.tmp" "$CACHE_DIR/recent" || true
    return 0
}

# Download URL into wallpaper.<ext>, reject tiny files, prune the old
# extensions and print the destination. Does NOT record state: a re-roll may
# download several images and only the kept one is recorded by the caller.
wc_download() {
    local url="${1-}" timeout="${2:-120}" ext="${3-}"
    local dest tmp size
    [ -n "$url" ] || return 1
    if [ -z "$ext" ]; then
        ext="${url##*.}"
        ext="${ext%%\?*}"
    fi
    dest="$CACHE_DIR/wallpaper.$ext"
    tmp="$dest.part"
    if ! curl -fsS --connect-timeout 10 --max-time "$timeout" \
            -A "${UA:-Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36}" \
            -o "$tmp" "$url"; then
        rm -f "$tmp"
        return 1
    fi
    size="$(stat -c %s "$tmp" 2>/dev/null || echo 0)"
    if [ "$size" -lt "${MIN_BYTES:-100000}" ]; then
        rm -f "$tmp"
        return 1
    fi
    mv -f "$tmp" "$dest"
    wc_prune "$ext"
    printf '%s\n' "$dest"
}

# Copy what is on screen (or, if awww has no usable answer, the cache entry)
# to OUT. Returns non-zero when there is nothing to snapshot.
wc_snapshot_previous() {
    local out="${1-}" shown prev_src=""
    [ -n "$out" ] || return 1
    shown="$(wc_shown)"
    if [ -n "$shown" ]; then
        shown="$(readlink -f "$shown" 2>/dev/null || true)"
        case "$shown" in
            "$CACHE_DIR"/wallpaper.*) prev_src="$shown" ;;
        esac
    fi
    if [ -z "$prev_src" ]; then
        prev_src="$(wc_cached || true)"
    fi
    [ -n "$prev_src" ] && [ -f "$prev_src" ] || return 1
    cp -f "$prev_src" "$out" 2>/dev/null || return 1
    return 0
}
