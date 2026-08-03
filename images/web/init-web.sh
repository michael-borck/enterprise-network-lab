#!/bin/sh
# Route via the office router so replies reach other offices, then start
# nginx via its normal entrypoint.

set -eu

ip route replace default via "$GATEWAY"

# A file big enough to need many full-size TCP segments. Lab 03 uses it:
# a path with a broken MTU serves the small pages fine and stalls here.
mkdir -p /var/www/extra
[ -f /var/www/extra/large.bin ] || dd if=/dev/zero of=/var/www/extra/large.bin bs=1M count=8 2>/dev/null

exec /docker-entrypoint.sh nginx -g "daemon off;"
