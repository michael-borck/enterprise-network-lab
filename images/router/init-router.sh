#!/bin/sh
# Apply WAN latency shaping, then hand off to FRR.
#
# WAN_DELAY is a SEMICOLON-separated list of <ip-prefix>=<netem args>, e.g.
#   WAN_DELAY="172.16.1.=delay 125ms;172.16.4.=delay 300ms 20ms loss 0.5%"
# Anything valid after `netem` can go on the right, so a link can carry
# jitter and loss as well as distance -- that is what separates a satellite
# hop from a long terrestrial one. Semicolons separate entries because the
# arguments themselves contain spaces.
#
# The shaping is applied as egress netem on whichever interface holds an
# address matching the prefix. Each side of a link shapes its own egress,
# so the RTT is the sum of both sides.

set -u

OLDIFS="$IFS"
IFS=';'
for spec in ${WAN_DELAY:-}; do
    IFS="$OLDIFS"
    [ -n "$spec" ] || continue
    prefix="${spec%%=*}"
    netem_args="${spec#*=}"
    iface=$(ip -o -4 addr show | awk -v p="$prefix" 'index($4, p) == 1 {print $2; exit}' | cut -d@ -f1)
    if [ -n "$iface" ]; then
        tc qdisc del dev "$iface" root 2>/dev/null
        # shellcheck disable=SC2086
        tc qdisc add dev "$iface" root netem $netem_args
        echo "netem: ${iface} (${prefix}*) <- ${netem_args}"
    else
        echo "netem: WARNING no interface matches prefix ${prefix}" >&2
    fi
    IFS=';'
done
IFS="$OLDIFS"

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
    OLDIFS="$IFS"; IFS=';'
    for spec in ${WAN_DELAY:-}; do
        IFS="$OLDIFS"
        prefix="${spec%%=*}"
        iface=$(ip -o -4 addr show | awk -v p="$prefix" 'index($4, p) == 1 {print $2; exit}')
        [ -n "$iface" ] && vtysh -c 'configure terminal' \
            -c "interface $iface" -c 'ip ospf network non-broadcast'
        IFS=';'
    done
    IFS="$OLDIFS"
) &

exec /usr/lib/frr/docker-start
