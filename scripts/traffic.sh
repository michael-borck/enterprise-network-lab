#!/bin/bash
# Background "office worker": browses the intranet and makes DNS lookups
# at random intervals so there is always live traffic on the WAN.

NAMES=(intranet.corp.lab ws1.perth.corp.lab dns.perth.corp.lab gw.london.corp.lab)

while true; do
    curl -s -o /dev/null --max-time 10 http://intranet.corp.lab/ || true
    dig +short "${NAMES[RANDOM % ${#NAMES[@]}]}" >/dev/null 2>&1 || true
    sleep $((RANDOM % 8 + 2))
done
