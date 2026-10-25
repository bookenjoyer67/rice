#!/bin/bash

CACHE_FILE="/tmp/deepseek_usd_rate.cache"
CACHE_TTL=3600

if [ -f "$CACHE_FILE" ] && [ $(($(date +%s) - $(stat -c %Y "$CACHE_FILE"))) -lt $CACHE_TTL ]; then
    RATE=$(cat "$CACHE_FILE")
else
    RATE=$(curl -s "https://api.frankfurter.app/latest?from=CNY&to=USD" | jq -r '.rates.USD')
    if [ -z "$RATE" ] || [ "$RATE" = "null" ]; then
        RATE="0.14"
    fi
    echo "$RATE" > "$CACHE_FILE"
fi

NOW_BJ=$(TZ='Asia/Shanghai' date +%s)

HOUR=$(TZ='Asia/Shanghai' date +%H)
DOW=$(TZ='Asia/Shanghai' date +%u)

TODAY_MIDNIGHT=$(TZ='Asia/Shanghai' date -d "$(TZ='Asia/Shanghai' date +%Y-%m-%d) 00:00:00" +%s)

if [ "$DOW" -eq 6 ] || [ "$DOW" -eq 7 ]; then
    PERIOD="🟢 Off-peak"
    RMB_PRICE=13.5
    DAYS_UNTIL_MON=$(( (8 - DOW) % 7 ))
    TARGET_TS=$((TODAY_MIDNIGHT + DAYS_UNTIL_MON * 86400 + 9 * 3600))
else
    if [ $HOUR -lt 9 ]; then
        TARGET_HOUR=9
    elif [ $HOUR -lt 12 ]; then
        TARGET_HOUR=12
    elif [ $HOUR -lt 14 ]; then
        TARGET_HOUR=14
    elif [ $HOUR -lt 18 ]; then
        TARGET_HOUR=18
    else
        TARGET_HOUR=9
    fi

    TARGET_TS=$((TODAY_MIDNIGHT + TARGET_HOUR * 3600))
    if [ $TARGET_TS -lt $NOW_BJ ]; then
        TARGET_TS=$((TARGET_TS + 86400))
    fi

    if [[ $HOUR -ge 9 && $HOUR -lt 12 ]] || [[ $HOUR -ge 14 && $HOUR -lt 18 ]]; then
        PERIOD="🔴 Peak"
        RMB_PRICE=27
    else
        PERIOD="🟢 Off-peak"
        RMB_PRICE=13.5
    fi
fi

REMAINING=$((TARGET_TS - NOW_BJ))
if [ $REMAINING -lt 0 ]; then
    REMAINING=0
fi

MINUTES=$((REMAINING / 60))
HOURS=$((MINUTES / 60))
MINS=$((MINUTES % 60))
TIME_LEFT="${HOURS}h ${MINS}m"

USD_PRICE=$(echo "$RMB_PRICE * $RATE" | bc -l)
USD_PRICE=$(printf "%.2f" "$USD_PRICE")

BAL_CACHE="/tmp/deepseek_balance.cache"
BAL_TTL=300
[ "$1" = "--force" ] && BAL_TTL=0
BALANCE=""

if [ -n "$DEEPSEEK_API_KEY" ]; then
    DS_KEY="$DEEPSEEK_API_KEY"
elif [ -r "$HOME/.config/komun-sandbox/deepseek.key" ]; then
    DS_KEY=$(tr -d '\r\n' < "$HOME/.config/komun-sandbox/deepseek.key")
elif [ -r "$HOME/.hermes/.env" ]; then
    DS_KEY=$(grep -m1 '^DEEPSEEK_API_KEY=' "$HOME/.hermes/.env" | cut -d= -f2- | tr -d '"'"'"'\r\n')
fi

if [ -f "$BAL_CACHE" ] && [ $(($(date +%s) - $(stat -c %Y "$BAL_CACHE"))) -lt $BAL_TTL ]; then
    BALANCE=$(cat "$BAL_CACHE")
elif [ -n "$DS_KEY" ]; then
    BAL_JSON=$(curl -s --max-time 8 -H "Authorization: Bearer $DS_KEY" https://api.deepseek.com/user/balance)
    BAL_AMT=$(echo "$BAL_JSON" | jq -r '.balance_infos[0].total_balance // empty' 2>/dev/null)
    BAL_CUR=$(echo "$BAL_JSON" | jq -r '.balance_infos[0].currency // "USD"' 2>/dev/null)
    if [ -n "$BAL_AMT" ] && [ "$BAL_AMT" != "null" ]; then
        case "$BAL_CUR" in
            CNY) BAL_SYM="¥" ;;
            *)   BAL_SYM="\$" ;;
        esac
        BALANCE=$(printf '%s%.2f' "$BAL_SYM" "$BAL_AMT")
        echo "$BALANCE" > "$BAL_CACHE"
    fi
fi

if [ -z "$BALANCE" ] && [ -r "$BAL_CACHE" ]; then
    BALANCE=$(cat "$BAL_CACHE")
fi

echo "{\"period\": \"$PERIOD\", \"price\": \"\$$USD_PRICE USD/M\", \"time_left\": \"$TIME_LEFT\", \"balance\": \"$BALANCE\"}"
