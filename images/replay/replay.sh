#!/bin/sh
# Replay a capture file onto this container's network segment.
#
# Replayed packets carry the addresses baked into the capture — nothing on
# the network answers them. They are a recording being played back, not a
# conversation. That is exactly what an IDS sensor needs to see, and it is
# also the honest limitation of replay: use it for detection practice, not
# for anything that requires a reply.
#
#   PCAP   file under /pcaps to replay        (required)
#   LOOP   how many times to play it          (default 1, 0 = forever)
#   MBPS   replay rate in megabits/sec        (default: original timing)
#   IFACE  interface to transmit on           (default eth0)

set -eu

: "${PCAP:?set PCAP to a file under /pcaps}"
IFACE="${IFACE:-eth0}"
LOOP="${LOOP:-1}"

if [ ! -f "/pcaps/$PCAP" ]; then
    echo "replay: /pcaps/$PCAP not found. Available:" >&2
    ls /pcaps >&2
    exit 1
fi

# Without this the NIC rewrites checksums after the sensor has seen the
# frame, and every replayed packet is reported as corrupt.
ethtool -K "$IFACE" tx off >/dev/null 2>&1 || true

if [ -n "${MBPS:-}" ]; then
    RATE="--mbps=$MBPS"
else
    RATE="--multiplier=1"
fi

# Packets captured on the sending host are recorded before the NIC computes
# their checksums, so a raw capture is full of "invalid checksum" packets.
# Suricata refuses to inspect the payload of a packet whose checksum is
# wrong, so replaying an unfixed capture produces nothing but checksum
# alerts. tcprewrite recomputes them — always do this before replaying.
SRC="/pcaps/$PCAP"
FIXED="/tmp/$(basename "$PCAP" .pcap)-fixed.pcap"

# A switch only delivers a unicast frame to the port that owns the
# destination MAC — spraying a capture onto a segment does NOT make a
# sensor elsewhere see it. Real deployments solve this with a SPAN/mirror
# port; here the destination MAC is rewritten to the sensor host's, so
# every replayed frame is delivered to it. (SENSOR_IP is the router's
# address on this segment; its MAC is learned with a single ping.)
SENSOR_IP="${SENSOR_IP:-10.10.30.254}"
ping -c1 -W2 "$SENSOR_IP" >/dev/null 2>&1 || true
DMAC=$(ip neigh show "$SENSOR_IP" | awk '{for(i=1;i<=NF;i++) if($i=="lladdr") print $(i+1)}')

REWRITE="--fixcsum"
if [ -n "$DMAC" ]; then
    echo "replay: addressing frames to the sensor at $SENSOR_IP ($DMAC)"
    REWRITE="$REWRITE --enet-dmac=$DMAC"
else
    echo "replay: WARNING could not resolve $SENSOR_IP — the sensor may not see this" >&2
fi

# Packets captured on the sending host are recorded before the NIC computes
# their checksums, so a raw capture is full of "invalid checksum" packets.
# Suricata will not inspect the payload of a packet whose checksum is wrong,
# so an unfixed replay produces nothing but checksum alerts.
echo "replay: rewriting ($REWRITE)"
tcprewrite --infile="$SRC" --outfile="$FIXED" $REWRITE
SRC="$FIXED"

echo "replay: playing $PCAP on $IFACE (loop=$LOOP)"
exec tcpreplay --intf1="$IFACE" --loop="$LOOP" $RATE "$SRC"
