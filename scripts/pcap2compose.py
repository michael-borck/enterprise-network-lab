#!/usr/bin/env python3
"""Reconstruct a network topology from a packet capture.

Reads a pcap, works out who was on the network, how it was segmented, which
machines were routing, and what services were answering — then writes a
docker-compose.yml that stands the whole thing back up, plus a report of
what was inferred and how confident it is.

Pure standard library on purpose: a forensic workstation should not need
`pip install` before it can look at evidence.

    python3 scripts/pcap2compose.py pcaps/incident.pcap -o rebuilt/
"""

import argparse
import ipaddress
import struct
import sys
from collections import Counter, defaultdict
from pathlib import Path

# ── pcap parsing ─────────────────────────────────────────────────────────

PCAP_MAGICS = {
    0xA1B2C3D4: ("<", 1),          # little-endian, microseconds
    0xD4C3B2A1: (">", 1),
    0xA1B23C4D: ("<", 1000),       # nanosecond variants
    0x4D3CB2A1: (">", 1000),
}
LINKTYPE_ETHERNET = 1


class Packet:
    __slots__ = ("ts", "src_mac", "dst_mac", "src_ip", "dst_ip",
                 "proto", "src_port", "dst_port", "length", "arp_sender")

    def __init__(self):
        self.src_ip = self.dst_ip = None
        self.src_port = self.dst_port = None
        self.proto = None
        self.arp_sender = None


def mac(raw):
    return ":".join(f"{b:02x}" for b in raw)


def parse_pcap(path):
    """Yield Packet objects. Raises SystemExit on formats we can't read."""
    data = Path(path).read_bytes()
    if len(data) < 24:
        sys.exit(f"{path}: too short to be a capture file")

    magic = struct.unpack("<I", data[:4])[0]
    if magic == 0x0A0D0D0A:
        sys.exit(f"{path}: this is a pcapng file. Convert it first:\n"
                 f"  editcap -F pcap {path} {path}.pcap")
    if magic not in PCAP_MAGICS:
        sys.exit(f"{path}: not a pcap file (magic {magic:#x})")

    endian, _ = PCAP_MAGICS[magic]
    linktype = struct.unpack(endian + "I", data[20:24])[0]
    if linktype != LINKTYPE_ETHERNET:
        sys.exit(f"{path}: link type {linktype} is not Ethernet.\n"
                 "Captures taken with `tcpdump -i any` use Linux cooked capture,\n"
                 "which has no Ethernet header — recapture on a single interface.")

    off = 24
    while off + 16 <= len(data):
        ts_sec, _ts_frac, caplen, origlen = struct.unpack(
            endian + "IIII", data[off:off + 16])
        off += 16
        frame = data[off:off + caplen]
        off += caplen
        if len(frame) < 14:
            continue

        p = Packet()
        p.ts = ts_sec
        p.length = origlen
        p.dst_mac = mac(frame[0:6])
        p.src_mac = mac(frame[6:12])
        ethertype = struct.unpack(">H", frame[12:14])[0]
        payload = frame[14:]

        # 802.1Q tag — step over it and re-read the ethertype
        if ethertype == 0x8100 and len(payload) >= 4:
            ethertype = struct.unpack(">H", payload[2:4])[0]
            payload = payload[4:]

        if ethertype == 0x0806 and len(payload) >= 28:      # ARP
            p.proto = "arp"
            p.arp_sender = (str(ipaddress.IPv4Address(payload[14:18])),
                            mac(payload[8:14]))
            yield p
            continue

        if ethertype != 0x0800 or len(payload) < 20:        # IPv4 only
            continue

        ihl = (payload[0] & 0x0F) * 4
        if ihl < 20 or len(payload) < ihl:
            continue
        proto_num = payload[9]
        p.src_ip = str(ipaddress.IPv4Address(payload[12:16]))
        p.dst_ip = str(ipaddress.IPv4Address(payload[16:20]))
        rest = payload[ihl:]

        if proto_num == 6 and len(rest) >= 14:
            p.proto = "tcp"
            p.src_port, p.dst_port = struct.unpack(">HH", rest[0:4])
            p.length = rest[13]                              # TCP flags
        elif proto_num == 17 and len(rest) >= 8:
            p.proto = "udp"
            p.src_port, p.dst_port = struct.unpack(">HH", rest[0:4])
        elif proto_num == 1:
            p.proto = "icmp"
        else:
            p.proto = f"ip/{proto_num}"
        yield p


# ── inference ────────────────────────────────────────────────────────────

WELL_KNOWN = {
    22: ("ssh", "linuxserver/openssh-server"),
    25: ("smtp", None),
    53: ("dns", "alpine"),
    80: ("http", "nginx:alpine"),
    123: ("ntp", None),
    143: ("imap", None),
    443: ("https", "nginx:alpine"),
    445: ("smb", None),
    3306: ("mysql", "mariadb"),
    5432: ("postgres", "postgres"),
    8080: ("http-alt", "nginx:alpine"),
}
TCP_SYN, TCP_ACK = 0x02, 0x10


class Topology:
    def __init__(self):
        self.ip_macs = defaultdict(Counter)     # ip -> macs seen sending it
        self.arp_owner = {}                     # ip -> mac, straight from ARP
        self.talkers = Counter()                # ip -> packets
        self.pairs = Counter()                  # (src,dst) -> packets
        self.listening = defaultdict(Counter)   # ip -> ports it served from
        self.probed = defaultdict(Counter)      # ip -> ports someone tried
        self.protocols = Counter()
        self.packets = 0
        self.first_ts = self.last_ts = None

    def add(self, p):
        self.packets += 1
        if self.first_ts is None:
            self.first_ts = p.ts
        self.last_ts = p.ts
        self.protocols[p.proto] += 1

        if p.proto == "arp" and p.arp_sender:
            ip, m = p.arp_sender
            if ip != "0.0.0.0":
                self.ip_macs[ip][m] += 1
                # ARP is authoritative: the sender is announcing "this IP is
                # mine, at this MAC". Frames merely *relayed* by a router
                # never claim ownership like this.
                self.arp_owner[ip] = m
            return

        if not p.src_ip:
            return
        self.talkers[p.src_ip] += 1
        self.pairs[(p.src_ip, p.dst_ip)] += 1
        self.ip_macs[p.src_ip][p.src_mac] += 1

        if p.proto in ("tcp", "udp") and p.dst_port is not None:
            # A service is something that ANSWERS. For TCP that means a
            # SYN-ACK from the port; for UDP, any packet sent *from* it.
            if p.proto == "tcp":
                flags = p.length
                if flags & TCP_SYN and flags & TCP_ACK:
                    self.listening[p.src_ip][p.src_port] += 1
                elif flags & TCP_SYN:
                    self.probed[p.dst_ip][p.dst_port] += 1
            else:
                if p.src_port < 1024:
                    self.listening[p.src_ip][p.src_port] += 1
                if p.dst_port < 1024:
                    self.probed[p.dst_ip][p.dst_port] += 1

    # ── derived views ────────────────────────────────────────────────
    def hosts(self):
        return sorted(
            (ip for ip in self.talkers
             if not ipaddress.IPv4Address(ip).is_multicast
             and ip != "255.255.255.255"),
            key=lambda i: ipaddress.IPv4Address(i))

    def subnets(self):
        """Group hosts into /24s — the safe assumption without config."""
        nets = defaultdict(list)
        for ip in self.hosts():
            nets[str(ipaddress.ip_network(ip + "/24", strict=False))].append(ip)
        return dict(sorted(nets.items()))

    def owned_by(self, m):
        """IPs this MAC actually owns, per ARP (falling back to sole-sender)."""
        owned = {ip for ip, om in self.arp_owner.items() if om == m}
        if not owned:
            owned = {ip for ip, macs in self.ip_macs.items()
                     if list(macs) == [m] and len(macs) == 1}
        return owned

    def routers(self):
        """A router relays: frames leave its MAC carrying source IPs that
        belong to somebody else, in subnets it is not itself addressed in.

        The distinction matters. Every forwarded packet keeps the original
        sender's IP but gets the router's MAC, so simply listing "IPs seen
        behind this MAC" would credit the router with owning half the
        network. ARP tells us which addresses are really its own.
        """
        mac_seen = defaultdict(set)
        for ip, macs in self.ip_macs.items():
            for m in macs:
                mac_seen[m].add(ip)

        found = {}
        for m, seen in mac_seen.items():
            owned = self.owned_by(m) & seen
            relayed = seen - owned
            relayed_nets = {str(ipaddress.ip_network(i + "/24", strict=False))
                            for i in relayed}
            owned_nets = {str(ipaddress.ip_network(i + "/24", strict=False))
                          for i in owned}
            if relayed_nets - owned_nets or len(owned_nets) > 1:
                found[m] = {
                    "owned": sorted(owned, key=lambda i: ipaddress.IPv4Address(i)),
                    "relayed_nets": sorted(relayed_nets | owned_nets),
                }
        return found

    def services(self):
        out = {}
        for ip, ports in self.listening.items():
            confirmed = [p for p, n in ports.items() if n >= 1]
            if confirmed:
                out[ip] = sorted(confirmed)
        return out


# ── output ───────────────────────────────────────────────────────────────

def slug(ip):
    return "host-" + ip.replace(".", "-")


def net_name(cidr):
    return "net-" + cidr.split("/")[0].replace(".", "-")


def write_compose(topo, out_dir):
    subnets = topo.subnets()
    routers = topo.routers()
    router_own_ips = {ip for info in routers.values() for ip in info["owned"]}
    services = topo.services()

    lines = ["# Reconstructed from a packet capture by pcap2compose.py.",
             "# Every address, subnet and service here was inferred from",
             "# observed traffic — read REPORT.md before trusting it.",
             "",
             "services:"]

    # Routers first: one container per relaying MAC, attached to every
    # subnet whose traffic it carried. Where the capture never revealed the
    # router's address on a subnet, .254 is synthesised and flagged.
    for i, (m, info) in enumerate(sorted(routers.items()), 1):
        owned_by_net = {str(ipaddress.ip_network(ip + "/24", strict=False)): ip
                        for ip in info["owned"]}
        lines += [f"  router-{i}:",
                  "    image: nicolaka/netshoot:latest",
                  "    cap_add: [NET_ADMIN]",
                  "    sysctls: [net.ipv4.ip_forward=1]",
                  '    command: ["sleep", "infinity"]',
                  f"    # observed MAC {m}",
                  "    networks:"]
        for cidr in info["relayed_nets"]:
            ip = owned_by_net.get(cidr)
            if ip:
                lines.append(f"      {net_name(cidr)}: {{ipv4_address: {ip}}}")
            else:
                guess = cidr.rsplit(".", 1)[0] + ".254"
                lines.append(f"      {net_name(cidr)}: {{ipv4_address: {guess}}}"
                             "   # GUESS: address never seen in the capture")
        lines.append("")

    # Every reconstructed host runs the same toolbox image and points its
    # default route at the router, so the rebuilt network actually routes.
    # The service a host was seen answering is recorded as a comment rather
    # than started for real: the capture proves a port answered, not what
    # software was behind it or what it would have said next.
    gw_for = {}
    for info in routers.values():
        owned = {str(ipaddress.ip_network(i + "/24", strict=False)): i
                 for i in info["owned"]}
        for cidr in info["relayed_nets"]:
            gw_for[cidr] = owned.get(cidr, cidr.rsplit(".", 1)[0] + ".254")

    for ip in topo.hosts():
        if ip in router_own_ips:
            continue
        cidr = str(ipaddress.ip_network(ip + "/24", strict=False))
        ports = services.get(ip, [])
        gw = gw_for.get(cidr)
        if gw and gw != ip:
            cmd = (f'["sh", "-c", "ip route replace default via {gw}; '
                   f'sleep infinity"]')
        else:
            cmd = '["sleep", "infinity"]'
        lines.append(f"  {slug(ip)}:")
        lines.append("    image: nicolaka/netshoot:latest")
        lines.append("    cap_add: [NET_ADMIN]")
        lines.append(f"    command: {cmd}")
        if ports:
            named = ", ".join(
                f"{p}/{WELL_KNOWN.get(p, ('?',))[0]}" for p in ports)
            lines.append(f"    # was answering on: {named}")
        lines.append("    networks:")
        lines.append(f"      {net_name(cidr)}: {{ipv4_address: {ip}}}")
        lines.append("")

    lines.append("networks:")
    for cidr in subnets:
        lines += [f"  {net_name(cidr)}:",
                  "    driver_opts:",
                  "      com.docker.network.bridge.gateway_mode_ipv4: routed",
                  f"    ipam: {{config: [{{subnet: {cidr}}}]}}"]
    lines.append("")

    (out_dir / "docker-compose.yml").write_text("\n".join(lines))


def write_report(topo, src, out_dir):
    subnets = topo.subnets()
    routers = topo.routers()
    services = topo.services()
    duration = (topo.last_ts - topo.first_ts) if topo.first_ts else 0

    r = [f"# What was in `{Path(src).name}`", "",
         f"- **{topo.packets:,} packets** over **{duration} seconds**",
         f"- **{len(topo.hosts())} hosts** in **{len(subnets)} subnet(s)**",
         f"- protocols: " + ", ".join(f"{k} {v:,}" for k, v in topo.protocols.most_common()),
         "", "## Subnets", "",
         "Inferred as /24s — a capture cannot show you a netmask, so this is",
         "an assumption. If the real network used something else, the",
         "reconstruction will still work but the boundaries will be wrong.", ""]

    for cidr, ips in subnets.items():
        r.append(f"### {cidr} — {len(ips)} host(s)")
        r.append("")
        r.append("| host | packets sent | answered on | probed for |")
        r.append("|---|---|---|---|")
        for ip in ips:
            svc = ", ".join(f"{p}/{WELL_KNOWN.get(p, ('?',))[0]}"
                            for p in services.get(ip, [])) or "—"
            prb = topo.probed.get(ip)
            prb_s = f"{len(prb)} ports" if prb and len(prb) > 3 else (
                ", ".join(str(p) for p in sorted(prb)) if prb else "—")
            r.append(f"| `{ip}` | {topo.talkers[ip]:,} | {svc} | {prb_s} |")
        r.append("")

    r += ["## Routers", ""]
    if routers:
        r.append("A host whose MAC address carried traffic for more than one")
        r.append("subnet is forwarding — that is what a router does.")
        r.append("")
        for m, info in sorted(routers.items()):
            own = ", ".join(f"`{i}`" for i in info["owned"]) or "*never seen addressed*"
            r.append(f"- MAC `{m}` — its own address(es): {own}; relayed "
                     f"traffic for {len(info['relayed_nets'])} subnet(s): "
                     + ", ".join(f"`{c}`" for c in info["relayed_nets"]))
        r.append("")
    else:
        r += ["None detected. Either the capture is from a single segment, or",
              "it was taken somewhere that never saw the router's frames.", ""]

    r += ["## Signs of scanning", ""]
    scanned = [(ip, len(p)) for ip, p in topo.probed.items() if len(p) > 10]
    if scanned:
        for ip, n in sorted(scanned, key=lambda x: -x[1]):
            attackers = [s for (s, d) in topo.pairs if d == ip]
            r.append(f"- `{ip}` was probed on **{n} different ports** "
                     f"by: " + ", ".join(f"`{a}`" for a in attackers[:5]))
        r.append("")
        r.append("Ports that were probed but never answered are closed — they")
        r.append("tell you what the attacker was looking for, not what existed.")
    else:
        r.append("No host was probed on more than 10 ports.")
    r += ["", "## Caveats", "",
          "- Hosts that were silent during the capture are invisible here.",
          "- A service that never answered during the capture looks closed.",
          "- Subnet masks, VLANs, routing protocols and firewall policy are",
          "  not recoverable from traffic alone — only their consequences.",
          "- Timings are wall-clock from the capture, not the original link",
          "  latencies; the rebuilt network will feel faster than the real one."]

    (out_dir / "REPORT.md").write_text("\n".join(r) + "\n")


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("pcap")
    ap.add_argument("-o", "--out", default="rebuilt",
                    help="output directory (default: rebuilt/)")
    args = ap.parse_args()

    topo = Topology()
    for p in parse_pcap(args.pcap):
        topo.add(p)

    if not topo.packets:
        sys.exit("no packets could be parsed")

    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    write_compose(topo, out)
    write_report(topo, args.pcap, out)

    print(f"read {topo.packets:,} packets from {args.pcap}")
    print(f"  {len(topo.hosts())} hosts, {len(topo.subnets())} subnet(s), "
          f"{len(topo.routers())} router(s)")
    print(f"wrote {out}/docker-compose.yml and {out}/REPORT.md")


if __name__ == "__main__":
    main()
