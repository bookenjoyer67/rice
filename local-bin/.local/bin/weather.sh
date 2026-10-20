#!/bin/bash
# EWW weather widget - fetches from wttr.in, outputs Nerd Font icons
# Cache: 30 minutes. Output: "NerdIcon 71°F StL"

CACHE="$HOME/.cache/eww-weather"
MAX_AGE=1800

if [ -f "$CACHE" ]; then
    age=$(($(date +%s) - $(stat -c %Y "$CACHE")))
    if [ "$age" -lt "$MAX_AGE" ]; then
        cat "$CACHE"
        exit 0
    fi
fi

# Fetch raw weather condition code + temp
raw=$(curl -s --max-time 10 "https://wttr.in/St.+Louis?format=%c+%t&lang=en" 2>/dev/null)

if [ -z "$raw" ] || [ "$raw" = "Unknown location" ]; then
    echo "Offline" > "$CACHE"
    echo "Offline"
    exit 0
fi

# Parse: emoji condition + space + temp (e.g. "🌫️  +71°F" or "☀️  +85°F")
cond="${raw%  *}"   # everything before the double-space
temp="${raw##*  }"  # everything after the double-space

# Map wttr.in emoji to Nerd Font weather glyphs (nf-weather)
case "$cond" in
    *Sunny*|*Clear*|☀️*|☀*)
        icon="" ;;  # nf-weather-day_sunny
    *Partly*cloudy*|*partly*|⛅*|🌤️*|🌤*)
        icon="" ;;  # nf-weather-day_cloudy
    *Cloudy*|*Overcast*|*cloudy*|*overcast*|☁️*|☁*|☁*)
        icon="" ;;  # nf-fa-cloud
    *Rain*|*rain*|🌧️*|🌧*)
        icon="" ;;  # nf-fa-tint (rain drops)
    *Light*rain*|*light*rain*|🌦️*|🌦*|*shower*|*Shower*)
        icon="" ;;  # nf-fa-tint
    *Snow*|*snow*|❄️*|❄*|🌨️*|🌨*)
        icon="" ;;  # nf-fa-snowflake
    *Fog*|*fog*|*Mist*|*mist*|🌫️*|🌫*|*Haze*|*haze*)
        icon="" ;;  # nf-fa-align-justify (neutral for fog/haze)
    *Thunder*|*thunder*|⛈️*|⛈*|🌩️*|🌩*)
        icon="" ;;  # nf-fa-bolt
    *)
        # Fallback: use first char of condition or generic weather icon
        icon="" ;;  # nf-fa-tint
esac

weather="${icon}  ${temp}"
echo "$weather" > "$CACHE"
echo "$weather"
