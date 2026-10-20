#!/usr/bin/env bash
# fetch-wallpaper.sh — pull ONE random wallpaper from the source and cache it.
#
# Source: wallhaven.cc. The look is psychedelic, with surreal, vaporwave and
# synthwave mixed in, and anime-category psychedelia included (see POOL below).
# SFW only (purity=100), at least 2560x1440, 16:9 / 16:10 / 21:9.
#
# This replaces the old "folder full of wallpapers" model: the cache holds
# exactly ONE image at a time and is overwritten on every fetch.
#
# On success it prints the path of the cached image (exit 0).
# If the API/download fails it falls back to the cached image (exit 0) so a
# session can still start offline; only a total miss exits 1.
#
# Swipe-reject: wallhaven ids listed one-per-line in $CACHE_DIR/rejected are
# never returned (see swipe-delete-wallpaper.sh).
#
# See which query was used: WALLPAPER_DEBUG=1 bash fetch-wallpaper.sh
set -euo pipefail

CACHE_DIR="$HOME/.cache/wallpaper"
REJECTED="$CACHE_DIR/rejected"
RECENT="$CACHE_DIR/recent"
STATE_ID="$CACHE_DIR/current.id"
UA="Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36"
MIN_BYTES=100000
# Default minimum resolution for a pick.
MIN_RES="2560x1440"
# Psychedelic means vivid: mean HSL saturation below this is treated as a dud
# and re-rolled (dark game art, greyscale minimalism, muted landscapes).
MIN_SATURATION="${WALLPAPER_MIN_SAT:-0.30}"
MAX_ATTEMPTS=4

# Query pool: "<wallhaven categories>|<search term>".
#
# Wallhaven category flags are a bitmask: 100 = general art, 010 = anime,
# 001 = people, 111 = all. Free-text search matches tags loosely (psychedelic
# and trippy resolve to the same tag cluster), so the pool leans on several
# distinct terms rather than one.
#
# The 010 entries are what deliver *psychedelic anime*: those terms only have
# ~10-30 images each at 1440p, but they are the real thing.
#
# Pool sizes below are the number of matching images at >=2560x1440, SFW,
# 16:9-21:9, as of adding them. Bigger numbers mean more variety before
# anything repeats.
#
# An entry may carry a third field to override MIN_RES ("cat|term|1920x1080").
# Used for aesthetic tags whose 1440p pool is nearly empty.
POOL=(
    # --- psychedelic core ---
    "111|psychedelic"      # 186
    "111|trippy"           # 186
    "111|acid"             #  39
    "111|lsd"              #  38
    "111|fractal"          # 287
    "111|glitch"           # 314
    "111|surreal"          # 231
    "111|spiral"           # 218
    "111|geometric"        # 599
    "111|liquid"           # 196
    "111|mushroom"         # 148
    "111|optical illusion" #  32
    # --- vaporwave / synthwave / retro ---
    "111|vaporwave"        # 192
    "111|synthwave"        # 138
    "111|retrowave"        # 267
    "111|outrun"           #  34
    "111|cyberpunk"        # 2354
    "111|neon"             # 1371
    "111|80s"              #  80
    "111|chrome"           #  47
    "111|statue"           # 323
    "111|palm tree"        # 543
    "111|tropical"         # 394
    "111|aqua"             # 371
    "111|abstract"         # 4564
    "111|solarpunk|1920x1080"      #   5 at 1080p (2 at 1440p)
    "111|frutiger aero|1920x1080"  #  38 at 1080p (16 at 1440p)
    # --- psychedelic / organic ---
    "111|prism|1920x1080"           #  29
    "111|refraction|1920x1080"      #  24
    "111|iridescence|1920x1080"     #  43
    "111|kaleidoscope|1920x1080"    #  23
    "111|plasma|1920x1080"          #  33
    "111|ink"                       # 168
    "111|jellyfish"                 # 149
    "111|coral"                     # 150
    "111|beetle"                    # 126
    "111|aurora"                    # 419
    # --- frutiger aero / y2k / glossy ---
    "111|bubbles"                   # 659
    "111|underwater"                # 1032
    "111|swimming pool"             # 237
    "111|aquarium|1920x1080"        #  52
    "111|glossy|1920x1080"          #  24
    "111|y2k|1920x1080"             #   7
    "111|90s|1920x1080"             #  64
    # --- retro / solarpunk / liminal ---
    "111|arcade"                    # 114
    "111|pixel art"                 # 1256
    "111|overgrown|1920x1080"       #  98
    "111|wind turbine|1920x1080"    #  75
    "111|liminal|1920x1080"         #  28
    "111|dreamscape|1920x1080"      #  31
    # --- anime category (psychedelic anime) ---
    "010|psychedelic"      #  10
    "010|trippy"           #  10
    "010|abstract"         #  26
    "010|glitch"           #  18
    "010|surreal"          #   7
    "010|vaporwave"        #  28
    "010|cyberpunk"        # 199
    "010|neon"             # 319
    "010|retrowave"        #  33
)

mkdir -p "$CACHE_DIR"
touch "$REJECTED" "$RECENT"

cached() { ls "$CACHE_DIR"/wallpaper.* 2>/dev/null | head -n1; }

# Remember the last few shown ids (ring buffer) so the next switch does not
# land on an image already on screen.
remember() {
    local id="$1"
    grep -qxF -- "$id" "$RECENT" 2>/dev/null || printf '%s\n' "$id" >> "$RECENT"
    tail -n 30 "$RECENT" > "$RECENT.tmp" 2>/dev/null && mv "$RECENT.tmp" "$RECENT"
}

# Mean saturation (0..1) via ImageMagick. Empty when it is not installed.
saturation() {
    local im
    if command -v magick >/dev/null 2>&1; then im=magick
    elif command -v convert >/dev/null 2>&1; then im=convert
    else return 0; fi
    "$im" "$1" -colorspace HSL -channel G -separate -format '%[fx:mean]' info: 2>/dev/null
}

# True when the image is vivid enough to pass as psychedelic.
vivid_enough() {
    local sat
    sat="$(saturation "$1")"
    # no ImageMagick / unreadable → do not block the wallpaper on it
    [ -n "${sat:-}" ] || return 0
    awk -v s="$sat" -v m="$MIN_SATURATION" 'BEGIN { exit !(s >= m) }'
}

# Pick a random result from a random pool entry, skipping rejected ids.
# Prints "id<TAB>path" (or nothing when every result was rejected).
pick() {
    local entry="${POOL[$((RANDOM % ${#POOL[@]}))]}"
    local cat term minres qq seed idx recfile
    # "<categories>|<term>" or "<categories>|<term>|<min resolution>"
    IFS='|' read -r cat term minres <<< "$entry"
    minres="${minres:-$MIN_RES}"
    qq="$(printf '%s' "$term" | sed 's/ /%20/g')"
    seed="$RANDOM$RANDOM$RANDOM"
    idx="$RANDOM"
    recfile="$RECENT"
    # SKIP_RECENT is set on the final attempt: stop excluding recent picks so a
    # small pool cannot dead-end into "no image".
    if [ -n "${SKIP_RECENT:-}" ]; then
        recfile=/dev/null
    fi

    if [ -n "${WALLPAPER_DEBUG:-}" ]; then
        printf 'fetch-wallpaper: q=%s categories=%s\n' "$term" "$cat" >&2
    fi

    curl -fsS --max-time 30 -A "$UA" \
        "https://wallhaven.cc/api/v1/search?q=$qq&categories=$cat&purity=100&atleast=$minres&ratios=16x9,16x10,21x9&sorting=random&seed=$seed&page=1" 2>/dev/null \
    | jq -r --rawfile rej "$REJECTED" --rawfile rec "$recfile" --argjson idx "$idx" '
        # skip swiped-away ids AND the last few we already showed, so a switch
        # never lands on the image that is already on screen
        (($rej | split("\n") | map(select(length > 0)))
         + ($rec | split("\n") | map(select(length > 0)))) as $skip
        | [ .data[] | select(([.id] | inside($skip)) | not) ] as $ok
        | select(($ok | length) > 0)
        # quality floor: pick at random out of the top half of this page by
        # favourites. Taking only the top 3 funnelled every switch into the
        # same handful of popular images (the duplicate problem); half the
        # page keeps a floor without shrinking the pool.
        | ($ok | sort_by(-.favorites) | .[0:12]) as $top
        | $top[ ($idx % ($top | length)) ]
        | "\(.id)\t\(.path)"
      '
}

# Download id/path into the single-file cache. Prints the saved path.
download() {
    local id="$1" url="$2" ext dest tmp size
    ext="${url##*.}"; ext="${ext%%\?*}"
    dest="$CACHE_DIR/wallpaper.$ext"
    tmp="$dest.part"
    if ! curl -fsS --max-time 120 -A "$UA" -o "$tmp" "$url"; then
        rm -f "$tmp"; return 1
    fi
    size="$(stat -c %s "$tmp" 2>/dev/null || echo 0)"
    if [ "$size" -lt "$MIN_BYTES" ]; then
        rm -f "$tmp"; return 1
    fi
    mv -f "$tmp" "$dest"
    # drop any stale image left from a previous extension (.jpg vs .png)
    find "$CACHE_DIR" -maxdepth 1 -type f -name 'wallpaper.*' \
        ! -name "wallpaper.$ext" -delete 2>/dev/null || true
    printf '%s\n' "$id" > "$STATE_ID"
    # append-only history for the wallpaper browser (recent stays a 30-entry ring)
    printf '%s\t%s\n' "$id" "$(date +%s)" >> "$CACHE_DIR/history"
    tail -n 1000 "$CACHE_DIR/history" > "$CACHE_DIR/history.tmp" 2>/dev/null \
        && mv "$CACHE_DIR/history.tmp" "$CACHE_DIR/history"
    printf '%s\n' "$dest"
}

# Serialize fetches. Rapid repeated keypresses would otherwise run two fetches
# at once, both writing $CACHE_DIR/wallpaper.*.part and both running the
# stale-extension cleanup — which can leave a partial file or delete the image
# the other run just saved.
LOCK="$CACHE_DIR/.fetch.lock"
exec 9>"$LOCK"
if ! flock -w 25 9; then
    echo "fetch-wallpaper: another fetch is already running" >&2
    if img="$(cached)" && [ -n "$img" ]; then
        printf '%s\n' "$img"
        exit 0
    fi
    exit 1
fi

# We hold the lock, so any .part here is a leftover from a killed run.
rm -f "$CACHE_DIR"/wallpaper.*.part 2>/dev/null || true

attempt=0
chosen=""
while [ "$attempt" -lt "$MAX_ATTEMPTS" ]; do
    attempt=$((attempt + 1))
    if [ "$attempt" -eq "$MAX_ATTEMPTS" ]; then
        SKIP_RECENT=1
    fi
    entry="$(pick || true)"
    if [ -z "$entry" ]; then
        continue
    fi

    id="${entry%%$'\t'*}"
    url="${entry#*$'\t'}"
    if ! dest="$(download "$id" "$url")"; then
        continue
    fi

    if vivid_enough "$dest"; then
        chosen="$dest"
        remember "$id"
        break
    fi
    if [ -n "${WALLPAPER_DEBUG:-}" ]; then
        printf 'fetch-wallpaper: %s too dull, re-rolling\n' "$id" >&2
    fi
done

if [ -n "$chosen" ]; then
    printf '%s\n' "$chosen"
    exit 0
fi

# Every attempt was dull, or the network/API failed: the last download (if any)
# is already in the cache, so keep showing it rather than nothing.
if img="$(cached)" && [ -n "$img" ]; then
    printf '%s\n' "$img"
    exit 0
fi

echo "fetch-wallpaper: no image available (fetch failed and no cache)" >&2
exit 1
