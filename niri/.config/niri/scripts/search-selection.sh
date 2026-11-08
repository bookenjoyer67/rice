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
url="https://duckduckgo.com/?q=$enc"

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

browser=()
if command -v brave-origin >/dev/null 2>&1; then
    browser=(brave-origin)
elif [ -x "$HOME/.local/bin/brave-origin" ]; then
    browser=("$HOME/.local/bin/brave-origin")
elif [ -x /usr/bin/brave-origin ]; then
    browser=(/usr/bin/brave-origin)
fi

if [ "${#browser[@]}" -eq 0 ]; then
    xdg-open "$url" >/dev/null 2>&1 &
    exit 0
fi

case "$comp" in
    niri)
        existing="$(niri msg -j windows 2>/dev/null | jq -r '[.[] | select(.app_id == "brave-origin")] | sort_by([(.focus_timestamp.secs // 0), (.focus_timestamp.nanos // 0)]) | last | .id // empty' || true)"
        if [ -n "$existing" ]; then
            prev_focus="$(niri msg -j windows 2>/dev/null | jq -r '.[] | select(.is_focused) | .id' | head -1 || true)"
            prev_ws="$(niri msg -j workspaces 2>/dev/null | jq -r '.[] | select(.is_focused) | .idx' | head -1 || true)"
            "${browser[@]}" --new-tab "$url" >/dev/null 2>&1 &
            for _ in 1 2 3 4 5; do
                sleep 0.1
                cur="$(niri msg -j windows 2>/dev/null | jq -r '.[] | select(.is_focused) | .id' | head -1 || true)"
                [ "$cur" = "$prev_focus" ] && break
                if [ -n "$prev_focus" ]; then
                    niri msg action focus-window --id "$prev_focus" >/dev/null 2>&1 || true
                elif [ -n "$prev_ws" ]; then
                    niri msg action focus-workspace "$prev_ws" >/dev/null 2>&1 || true
                fi
            done
            exit 0
        fi

        ws="$(niri msg -j workspaces 2>/dev/null | jq -r '.[] | select(.is_focused) | .id' | head -1 || true)"
        [ -z "$ws" ] && ws=1
        before="$(niri msg -j windows 2>/dev/null | jq -r '[.[].id] | @tsv' || true)"
        "${browser[@]}" --new-window "$url" >/dev/null 2>&1 &
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
        existing="$(hyprctl clients -j 2>/dev/null | jq -r '[.[] | select((.class // "") | test("brave-origin"; "i"))] | .[0].address // empty' 2>/dev/null || true)"
        if [ -n "$existing" ]; then
            prev_focus="$(hyprctl activewindow -j 2>/dev/null | jq -r '.address // empty' 2>/dev/null || true)"
            "${browser[@]}" --new-tab "$url" >/dev/null 2>&1 &
            for _ in 1 2 3 4 5; do
                sleep 0.1
                cur="$(hyprctl activewindow -j 2>/dev/null | jq -r '.address // empty' 2>/dev/null || true)"
                [ "$cur" = "$prev_focus" ] && break
                [ -n "$prev_focus" ] && hyprctl dispatch focuswindow "address:$prev_focus" >/dev/null 2>&1 || true
            done
            exit 0
        fi

        ws="$(hyprctl activeworkspace -j 2>/dev/null | jq -r '.id' 2>/dev/null || true)"
        [ -z "$ws" ] || [ "$ws" = "null" ] && ws="$(hyprctl activeworkspace 2>/dev/null | sed -nE 's/.*workspace ID ([0-9]+).*/\1/p' || true)"
        [ -z "$ws" ] || [ "$ws" = "null" ] && ws=1
        before="$(hyprctl clients -j 2>/dev/null | jq -r '[.[].address] | @tsv' || true)"
        "${browser[@]}" --new-window "$url" >/dev/null 2>&1 &
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
        "${browser[@]}" "$url" >/dev/null 2>&1 &
        ;;
esac
