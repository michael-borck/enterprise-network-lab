#!/bin/sh
# Where every office is in its working day, right now.
#
# Uses the same arithmetic as traffic.sh, so what this prints is exactly
# what the traffic generators believe the time is.

SIM_HOUR="${SIM_HOUR:-60}"
NOW=$(date +%s)
UTC_HOUR=$(( (NOW / SIM_HOUR) % 24 ))
MINS=$(( (NOW % SIM_HOUR) * 60 / SIM_HOUR ))

printf 'simulated time %02d:%02d UTC   (1 simulated hour = %ss real, so a day takes %s min)\n\n' \
    "$UTC_HOUR" "$MINS" "$SIM_HOUR" "$(( SIM_HOUR * 24 / 60 ))"
printf '  %-10s %-8s %s\n' OFFICE LOCAL STATE

for entry in "Perth:8" "Pilbara:8" "London:0" "LA:-8"; do
    site=${entry%%:*}
    off=${entry##*:}
    h=$(( (UTC_HOUR + off + 24) % 24 ))
    if [ "$h" -ge 9 ] && [ "$h" -lt 17 ]; then
        state="working"
        [ "$h" -eq 12 ] && state="lunch"
    elif { [ "$h" -ge 7 ] && [ "$h" -lt 9 ]; } || { [ "$h" -ge 17 ] && [ "$h" -lt 19 ]; }; then
        state="arriving/leaving"
    elif [ "$h" -eq 2 ]; then
        state="nightly backup"
    else
        state="closed"
    fi
    printf '  %-10s %02d:%02d    %s\n' "$site" "$h" "$MINS" "$state"
done
