#!/bin/bash

CACHE="$HOME/.cache/eww-weather"
MAX_AGE=1800

if [ -f "$CACHE" ]; then
    age=$(($(date +%s) - $(stat -c %Y "$CACHE")))
    if [ "$age" -lt "$MAX_AGE" ]; then
        cat "$CACHE"
        exit 0
    fi
fi

raw=$(curl -s --max-time 10 "https://wttr.in/St.+Louis?format=%c+%t&lang=en" 2>/dev/null)

if [ -z "$raw" ] || [ "$raw" = "Unknown location" ]; then
    echo "Offline" > "$CACHE"
    echo "Offline"
    exit 0
fi

cond="${raw%  *}"   # everything before the double-space
temp="${raw##*  }"  # everything after the double-space

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
        icon="" ;;  # nf-fa-tint
esac

weather="${icon}  ${temp}"
echo "$weather" > "$CACHE"
echo "$weather"
