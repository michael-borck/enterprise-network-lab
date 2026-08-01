#!/bin/bash
# The sensor shares the Perth router's network namespace, so it sees every
# interface the router has — office LANs and both WAN links. That is a real
# edge-sensor deployment: everything crossing the office boundary is visible.

set -eu

# The upstream image declares /etc/suricata and /var/lib/suricata as VOLUMEs,
# so anything written to them during the build can be masked by a volume
# carried over from an earlier container. Wiring the lab's rule file into the
# config at startup is idempotent and immune to that.
if ! grep -q '^\s*- local.rules' /etc/suricata/suricata.yaml; then
    sed -i 's|^rule-files:|rule-files:\n  - local.rules|' /etc/suricata/suricata.yaml
fi
[ -f /var/lib/suricata/rules/local.rules ] || touch /var/lib/suricata/rules/local.rules

# "up" filters out the kernel's dummy tunnel devices (erspan0, ip_vti0,
# sit0 ...), which are always present and always down.
IFACES=$(ip -o link show up | awk -F': ' '$2 != "lo" {print $2}' | cut -d@ -f1)

ARGS=""
for i in $IFACES; do
    # Checksum offload makes the NIC fill in checksums after Suricata sees
    # the packet, so every packet looks corrupt to the sensor. Turn it off.
    ethtool -K "$i" tx off rx off gro off lro off tso off gso off >/dev/null 2>&1 || true
    ARGS="$ARGS -i $i"
    echo "sensor: watching $i"
done

exec suricata -c /etc/suricata/suricata.yaml $ARGS
