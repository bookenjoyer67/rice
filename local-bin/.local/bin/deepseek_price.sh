#!/bin/bash

# ------------------------------------------------------------
# Get exchange rate (cached for 1 hour)
# ------------------------------------------------------------
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

# ------------------------------------------------------------
# Get current Beijing time (seconds since epoch)
# ------------------------------------------------------------
NOW_BJ=$(TZ='Asia/Shanghai' date +%s)

# Get the Beijing hour and day-of-week (1=Mon .. 7=Sun)
HOUR=$(TZ='Asia/Shanghai' date +%H)
DOW=$(TZ='Asia/Shanghai' date +%u)

# ------------------------------------------------------------
# Get today's date at midnight (Beijing time)
# ------------------------------------------------------------
TODAY_MIDNIGHT=$(TZ='Asia/Shanghai' date -d "$(TZ='Asia/Shanghai' date +%Y-%m-%d) 00:00:00" +%s)

# ------------------------------------------------------------
# Weekday rule: peak 09-12 & 14-18 Beijing; off-peak otherwise.
# Weekend rule (since Aug 23, 2026): Sat+Sun are off-peak ALL day —
# no peak window at all. The next real "change" is Monday 09:00
# Beijing, when weekday peak resumes, so the countdown rolls to that.
# ------------------------------------------------------------
if [ "$DOW" -eq 6 ] || [ "$DOW" -eq 7 ]; then
    # Weekend: always off-peak
    PERIOD="🟢 Off-peak"
    RMB_PRICE=13.5
    # Days until next Monday (0-6, never 0 here): Sat(+2) Sun(+1)
    DAYS_UNTIL_MON=$(( (8 - DOW) % 7 ))
    TARGET_TS=$((TODAY_MIDNIGHT + DAYS_UNTIL_MON * 86400 + 9 * 3600))
else
    # Weekday: determine next transition hour (9, 12, 14, or 18)
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

    # Target timestamp; if passed, next day
    TARGET_TS=$((TODAY_MIDNIGHT + TARGET_HOUR * 3600))
    if [ $TARGET_TS -lt $NOW_BJ ]; then
        TARGET_TS=$((TARGET_TS + 86400))
    fi

    # Peak or off-peak on weekdays
    if [[ $HOUR -ge 9 && $HOUR -lt 12 ]] || [[ $HOUR -ge 14 && $HOUR -lt 18 ]]; then
        PERIOD="🔴 Peak"
        RMB_PRICE=27
    else
        PERIOD="🟢 Off-peak"
        RMB_PRICE=13.5
    fi
fi

# ------------------------------------------------------------
# Calculate remaining time
# ------------------------------------------------------------
REMAINING=$((TARGET_TS - NOW_BJ))
if [ $REMAINING -lt 0 ]; then
    REMAINING=0
fi

MINUTES=$((REMAINING / 60))
HOURS=$((MINUTES / 60))
MINS=$((MINUTES % 60))
TIME_LEFT="${HOURS}h ${MINS}m"

# ------------------------------------------------------------
# Convert to USD
# ------------------------------------------------------------
USD_PRICE=$(echo "$RMB_PRICE * $RATE" | bc -l)
USD_PRICE=$(printf "%.2f" "$USD_PRICE")

# ------------------------------------------------------------
# Output JSON
# ------------------------------------------------------------
echo "{\"period\": \"$PERIOD\", \"price\": \"\$$USD_PRICE USD/M\", \"time_left\": \"$TIME_LEFT\"}"
