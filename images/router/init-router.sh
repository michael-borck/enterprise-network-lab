#!/bin/sh
# Apply WAN latency shaping, then hand off to FRR.
#
# WAN_DELAY is a comma-separated list of <ip-prefix>=<delay>, e.g.
#   WAN_DELAY="172.16.1.=125ms,172.16.2.=75ms"
# The delay is applied as egress netem on whichever interface holds an
# address matching the prefix. Each side of a link shapes its own egress,
# so the RTT is the sum of both sides.

set -u

for spec in $(echo "${WAN_DELAY:-}" | tr ',' ' '); do
    prefix="${spec%%=*}"
    delay="${spec##*=}"
    iface=$(ip -o -4 addr show | awk -v p="$prefix" 'index($4, p) == 1 {print $2; exit}')
    if [ -n "$iface" ]; then
        tc qdisc replace dev "$iface" root netem delay "$delay"
        echo "netem: ${delay} egress delay on ${iface} (${prefix}*)"
    else
        echo "netem: WARNING no interface matches prefix ${prefix}" >&2
    fi
done

# Docker Desktop (macOS/Windows) bridges do not forward multicast between
# containers, so OSPF's 224.0.0.5 hellos never arrive. WAN interfaces are
# switched to non-broadcast mode: hellos go unicast to the static
# `neighbor` addresses in frr.conf. Interface names vary with network
# attach order, so this is applied at runtime once ospfd is up.
(
    for _ in $(seq 1 30); do
        sleep 2
        vtysh -c 'show ip ospf' >/dev/null 2>&1 && break
    done
    for spec in $(echo "${WAN_DELAY:-}" | tr ',' ' '); do
        prefix="${spec%%=*}"
        iface=$(ip -o -4 addr show | awk -v p="$prefix" 'index($4, p) == 1 {print $2; exit}')
        [ -n "$iface" ] && vtysh -c 'configure terminal' \
            -c "interface $iface" -c 'ip ospf network non-broadcast'
    done
) &

exec /usr/lib/frr/docker-start
