#!/bin/sh
# Point the default route at the office router, then run dnsmasq in the
# foreground. The route matters: remote-office resolvers forward corp.lab
# queries to Perth across the WAN.

set -eu

ip route replace default via "$GATEWAY"
exec dnsmasq -k --log-queries --log-facility=-
