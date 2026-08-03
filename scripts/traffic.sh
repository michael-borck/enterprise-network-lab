#!/bin/bash
# Follow-the-sun office traffic.
#
# Each office works its own hours. London is busy while Perth sleeps, LA
# starts as London goes home, and the pattern repeats. That is what makes a
# multinational network's traffic look the way it does -- and it is the
# reason "a large transfer from the London office at 03:00 local" is worth
# alerting on while the same transfer at 11:00 is not.
#
# Real time is compressed so a whole day fits inside a lab session:
# SIM_HOUR real seconds = one simulated hour (default 60, so a 24-hour day
# takes 24 minutes). Set SIM_HOUR=3600 for real time.
#
#   SITE       label used in log lines
#   TZ_OFFSET  hours from UTC for this office (Perth +8, London 0, LA -8)
#   SIM_HOUR   real seconds per simulated hour (default 60)

set -u

SITE="${SITE:-office}"
TZ_OFFSET="${TZ_OFFSET:-0}"
SIM_HOUR="${SIM_HOUR:-60}"

INTRANET="http://intranet.corp.lab"
LARGE="http://intranet.corp.lab:8080/large.bin"
NAMES=(intranet.corp.lab ws1.perth.corp.lab dns.perth.corp.lab gw.london.corp.lab)

# Simulated local hour, 0-23.
local_hour() {
    local utc_hour=$(( ($(date +%s) / SIM_HOUR) % 24 ))
    echo $(( (utc_hour + TZ_OFFSET + 24) % 24 ))
}

browse() {
    curl -s -o /dev/null --max-time 20 "$INTRANET" || true
    dig +short +time=2 +tries=1 "${NAMES[RANDOM % ${#NAMES[@]}]}" >/dev/null 2>&1 || true
}

last_hour=-1
backup_done_on=-1

while true; do
    h=$(local_hour)
    day=$(( $(date +%s) / (SIM_HOUR * 24) ))

    if [ "$h" != "$last_hour" ]; then
        printf '[%s] simulated local time %02d:00\n' "$SITE" "$h"
        last_hour=$h
    fi

    if [ "$h" -ge 9 ] && [ "$h" -lt 17 ]; then
        # Working hours: steady browsing, with a lunchtime lull.
        browse
        if [ "$h" -eq 12 ]; then
            sleep $((RANDOM % 8 + 6))
        else
            sleep $((RANDOM % 4 + 2))
        fi
    elif [ "$h" -ge 7 ] && [ "$h" -lt 9 ] || [ "$h" -ge 17 ] && [ "$h" -lt 19 ]; then
        # Shoulder hours: early starters and stragglers.
        browse
        sleep $((RANDOM % 10 + 8))
    else
        # Out of hours. Almost nothing -- except the nightly backup at 02:00,
        # which is a big transfer that is entirely legitimate. Anomaly
        # detection has to learn the difference between this and an attack.
        if [ "$h" -eq 2 ] && [ "$day" != "$backup_done_on" ]; then
            printf '[%s] 02:00 nightly backup starting\n' "$SITE"
            curl -s -o /dev/null --max-time 120 "$LARGE" || true
            backup_done_on=$day
            printf '[%s] nightly backup finished\n' "$SITE"
        fi
        sleep $((RANDOM % 15 + 20))
    fi
done
