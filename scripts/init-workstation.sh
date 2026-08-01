#!/bin/bash
# Workstation bootstrap: send traffic through the office router instead of
# Docker's bridge gateway, and use the office resolver directly (bypassing
# Docker's embedded DNS so queries are visible on the wire with tcpdump).

set -eu

ip route replace default via "$GATEWAY"

cat > /etc/resolv.conf <<EOF
nameserver $DNS
search corp.lab
EOF

if [ "${TRAFFIC:-}" = "1" ] && [ -f /traffic.sh ]; then
    exec bash /traffic.sh
fi

exec sleep infinity
