#!/bin/sh
# Route via the office router so replies reach other offices, then start
# nginx via its normal entrypoint.

set -eu

ip route replace default via "$GATEWAY"
exec /docker-entrypoint.sh nginx -g "daemon off;"
