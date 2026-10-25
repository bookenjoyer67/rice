#!/usr/bin/env bash
set -euo pipefail

q="$(wl-paste --primary --no-newline 2>/dev/null || true)"
if [ -z "$q" ]; then
    q="$(wl-paste --no-newline 2>/dev/null || true)"
fi
q="$(printf '%s' "$q" | tr '\n' ' ' | sed -E 's/ +/ /g; s/^ +//; s/ +$//')"
if [ -z "$q" ]; then
    exit 0   # nothing selected/copied — do nothing
fi

if command -v jq >/dev/null 2>&1; then
    enc="$(printf '%s' "$q" | jq -sRr @uri)"
else
    enc="$(printf '%s' "$q" | python3 -c 'import sys,urllib.parse; print(urllib.parse.quote(sys.stdin.read()))')"
fi
url="https://search.brave.com/search?q=$enc"

comp="unknown"
if [ -n "${NIRI_SOCKET:-}" ] && niri msg workspaces >/dev/null 2>&1; then
    comp="niri"
elif command -v hyprctl >/dev/null 2>&1 && hyprctl activeworkspace >/dev/null 2>&1; then
    comp="hyprland"
fi

if [ "${SEARCH_DRY_RUN:-0}" = "1" ]; then
    printf 'compositor=%s\nurl=%s\n' "$comp" "$url"
    exit 0
fi

if command -v brave >/dev/null 2>&1; then
    launch=(brave --new-window "$url")
else
    launch=(xdg-open "$url")
fi

case "$comp" in
    niri)
        ws="$(niri msg -j workspaces 2>/dev/null | jq -r '.[] | select(.is_focused) | .id' | head -1 || true)"
        [ -z "$ws" ] && ws=1
        before="$(niri msg -j windows 2>/dev/null | jq -r '[.[].id] | @tsv' || true)"
        "${launch[@]}" >/dev/null 2>&1 &
        new=""
        for _ in $(seq 1 34); do
            after="$(niri msg -j windows 2>/dev/null | jq -r '[.[].id] | @tsv' || true)"
            for id in $after; do
                case " $before " in
                    *" $id "*) ;;
                    *) new="$id"; break ;;
                esac
            done
            [ -n "$new" ] && break
            sleep 0.15
        done
        if [ -n "$new" ]; then
            niri msg action move-window-to-workspace "$ws" --window-id "$new" >/dev/null 2>&1 || true
            niri msg action focus-window --id "$new" >/dev/null 2>&1 || true
        fi
        ;;
    hyprland)
        ws="$(hyprctl activeworkspace -j 2>/dev/null | jq -r '.id' 2>/dev/null || true)"
        [ -z "$ws" ] || [ "$ws" = "null" ] && ws="$(hyprctl activeworkspace 2>/dev/null | sed -nE 's/.*workspace ID ([0-9]+).*/\1/p' || true)"
        [ -z "$ws" ] || [ "$ws" = "null" ] && ws=1
        before="$(hyprctl clients -j 2>/dev/null | jq -r '[.[].address] | @tsv' || true)"
        "${launch[@]}" >/dev/null 2>&1 &
        new=""
        for _ in $(seq 1 34); do
            after="$(hyprctl clients -j 2>/dev/null | jq -r '[.[].address] | @tsv' || true)"
            for addr in $after; do
                case " $before " in
                    *" $addr "*) ;;
                    *) new="$addr"; break ;;
                esac
            done
            [ -n "$new" ] && break
            sleep 0.15
        done
        if [ -n "$new" ]; then
            hyprctl dispatch movetoworkspace "$ws,address:$new" >/dev/null 2>&1 || true
            hyprctl dispatch focuswindow "address:$new" >/dev/null 2>&1 || true
        fi
        ;;
    *)
        "${launch[@]}" >/dev/null 2>&1 &
        ;;
esac
