#!/usr/bin/env python3
"""Profile who talks when, from a capture.

Buckets traffic by office and by simulated local hour, prints it as a
heatmap, and flags activity that happened outside the office's working
day. Signature detection asks "is this packet bad?"; this asks "is this
normal for this office at this hour?" — a different and often better
question.

    python3 scripts/baseline.py pcaps/day.pcap
"""

import argparse
import ipaddress
import math
import sys
from collections import defaultdict

from pcap2compose import parse_pcap        # same directory

# subnet prefix -> (office, hours from UTC)
OFFICES = {
    "10.10.10": ("Perth", 8),
    "10.10.20": ("Perth-servers", 8),
    "10.20.10": ("London", 0),
    "10.30.10": ("LA", -8),
    "10.40.10": ("Pilbara", 8),
}
WORK_START, WORK_END = 7, 19        # generous: includes shoulder hours
RAMP = ".:-=+*#%@"


def office_of(ip):
    try:
        if ipaddress.IPv4Address(ip).is_multicast:
            return None
    except ipaddress.AddressValueError:
        return None
    return OFFICES.get(".".join(ip.split(".")[:3]))


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("pcap")
    ap.add_argument("--sim-hour", type=int, default=60,
                    help="real seconds per simulated hour (default 60)")
    ap.add_argument("--bytes", action="store_true",
                    help="weight by bytes rather than packet count")
    args = ap.parse_args()

    counts = defaultdict(lambda: defaultdict(int))   # office -> hour -> n
    for p in parse_pcap(args.pcap):
        if not p.src_ip:
            continue
        site = office_of(p.src_ip)
        if not site:
            continue
        name, offset = site
        utc_hour = (p.ts // args.sim_hour) % 24
        local = int((utc_hour + offset) % 24)
        counts[name][local] += (p.length if args.bytes and p.proto != "tcp" else 1)

    if not counts:
        sys.exit("no traffic from any known office subnet in this capture")

    unit = "bytes" if args.bytes else "packets"
    peak = max(v for hours in counts.values() for v in hours.values())
    print(f"\nActivity by simulated LOCAL hour at each office ({unit}, peak {peak})\n")
    print(" " * 17 + "".join(f"{h:<3}" for h in range(24)))

    anomalies = []
    for name in sorted(counts):
        row = []
        for h in range(24):
            n = counts[name].get(h, 0)
            if n == 0:
                row.append("   ")
                continue
            # Log scale. The nightly backup is an order of magnitude larger
            # than a working hour's browsing, so on a linear scale every
            # working hour flattens to the lowest level and the daily
            # rhythm -- the thing you are here to see -- disappears.
            frac = math.log1p(n) / math.log1p(peak)
            level = RAMP[max(0, min(len(RAMP) - 1, int(frac * (len(RAMP) - 1))))]
            row.append(f" {level} ")
            if not (WORK_START <= h < WORK_END):
                anomalies.append((name, h, n))
        print(f"  {name:<15}" + "".join(row))

    print("\n  legend: blank = silent, then " + " ".join(RAMP)
          + "  (logarithmic)")
    print(f"  working day treated as {WORK_START:02d}:00-{WORK_END:02d}:00 local\n")

    if anomalies:
        print("Out-of-hours activity:")
        for name, h, n in sorted(anomalies, key=lambda a: -a[2]):
            note = " (02:00 = scheduled backup window)" if h == 2 else ""
            print(f"  {name:<14} {h:02d}:00 local   {n:>7,} {unit}{note}")
        print("\n  Out of hours is not the same as malicious. The backup window"
              "\n  is legitimate; anything else here is worth a question.")
    else:
        print("No activity outside working hours in this capture.")


if __name__ == "__main__":
    main()
