# enterprise-network-lab

**Landing page: https://michael-borck.github.io/enterprise-network-lab/**

A miniature multi-site enterprise network that runs entirely in Docker.
Three offices — **Perth (HQ)**, **London**, and **Los Angeles** — connected
by latency-shaped WAN links, routed with real OSPF (FRR), with per-office
DNS resolvers and background user traffic so the network feels alive.

Everything in here is the real thing: real `tcpdump`, real `nftables`
targets, real FRR routing daemons, real dnsmasq. No wrappers, no mockups.

## Topology

```mermaid
graph TB
    subgraph Perth["Perth HQ (10.10.0.0/16)"]
        PR[perth-router]
        PU["users 10.10.10.0/24<br/>ws1 .101"]
        PS["servers 10.10.20.0/24<br/>dns .53 · intranet .80"]
        PD["dmz 10.10.30.0/24"]
        PU --- PR
        PS --- PR
        PD --- PR
    end
    subgraph London["London (10.20.0.0/16)"]
        LR[london-router]
        LU["users 10.20.10.0/24<br/>ws1 .101 · dns .53 · sim .102"]
        LU --- LR
    end
    subgraph LA["Los Angeles (10.30.0.0/16)"]
        AR[la-router]
        AU["users 10.30.10.0/24<br/>ws1 .101 · dns .53 · sim .102"]
        AU --- AR
    end
    PR ==|"172.16.1.0/24<br/>~250ms RTT"| LR
    PR ==|"172.16.2.0/24<br/>~150ms RTT"| AR
    LR ==|"172.16.3.0/24<br/>~140ms RTT"| AR
```

## Addressing plan

| Network | Subnet | Notable hosts |
|---|---|---|
| perth-users | 10.10.10.0/24 | ws1 `.101`, gateway `.254` |
| perth-servers | 10.10.20.0/24 | dns `.53`, intranet `.80`, gateway `.254` |
| perth-dmz | 10.10.30.0/24 | (empty for now), gateway `.254` |
| london-users | 10.20.10.0/24 | ws1 `.101`, dns `.53`, user-sim `.102`, gateway `.254` |
| la-users | 10.30.10.0/24 | ws1 `.101`, dns `.53`, user-sim `.102`, gateway `.254` |
| wan-perth-london | 172.16.1.0/24 | perth `.1`, london `.2` — 125ms egress delay each side |
| wan-perth-la | 172.16.2.0/24 | perth `.1`, la `.2` — 75ms each side |
| wan-london-la | 172.16.3.0/24 | london `.1`, la `.2` — 70ms each side |

DNS: Perth's resolver (`10.10.20.53`) is authoritative for `corp.lab`.
London and LA resolvers forward `corp.lab` queries to Perth across the
WAN and cache the answers — first lookup is slow, the next is instant.

## Quick start

```sh
make up        # build images and start the enterprise (~a dozen containers)
make test      # feel the geography: ping London (250ms), LA (150ms), curl the intranet
make perth     # a shell on the Perth workstation (netshoot: nmap, dig, mtr, tcpdump...)
make routes    # what the Perth router knows (OSPF-learned routes marked O)
make down      # tear it all down
make destroy   # also remove the nested Docker host + image cache (Desktop only)
```

Start with [labs/00-tour.md](labs/00-tour.md) for a guided walk-through.

## Docker Desktop vs native Linux

The `Makefile` detects which Docker you have and does the right thing:

- **Native Linux Docker**: the lab runs directly. The only requirement is
  the `gateway_mode_ipv4=routed` option already set on every network —
  Docker Engine ≥ 28 otherwise installs raw-table anti-spoofing rules that
  drop any frame whose destination IP is not an endpoint on the receiving
  network, which breaks routing *through* a container.
- **Docker Desktop (macOS/Windows)**: container networking goes through a
  userspace switch that only delivers frames to IPs registered on each
  network and doesn't forward multicast — transit routing through a router
  container is impossible natively, no matter the configuration. So
  `make up` transparently starts one privileged `docker:dind` container
  (`enterprise-lab-vm`) and runs the entire lab nested inside it, where
  networks are ordinary kernel bridges and everything behaves like Linux.
  Every `make` target proxies through it; the workflow is identical.

## How it works

- **Every network is `internal`** and Docker's inter-bridge isolation blocks
  shortcuts through the host, so cross-subnet traffic can *only* flow through
  the FRR router containers. What you see in `traceroute` is real routing.
- **Workstations replace Docker's default route** with their office router,
  and write `/etc/resolv.conf` to point at the office resolver directly —
  bypassing Docker's embedded DNS so every query is visible on the wire.
- **Latency is `tc netem`** applied to each router's WAN-facing interface at
  startup (each side delays egress by half the RTT). Change the numbers in
  `docker-compose.yml` (`WAN_DELAY`) to move the offices around the planet.
- **OSPF (area 0) runs on everything**, including office LANs — which means
  a workstation running `tcpdump` can see hello packets. That's deliberate:
  finding the routing protocol is a recon exercise. The WAN links use
  unicast OSPF (non-broadcast mode with static neighbours, applied by the
  router init script) so adjacency never depends on how well a given
  Docker bridge handles multicast.

## Capturing traffic

Docker bridges learn MAC addresses, so a passive third container on a
network won't see unicast between two others. Capture where the traffic
terminates or transits instead — the routers see everything inter-office:

```sh
# watch the Perth<->London WAN link
docker compose exec perth-router sh -c \
  'tcpdump -ni $(ip -o -4 addr show | awk "/172\.16\.1\./ {print \$2; exit}")'
```

If tcpdump complains about bad TCP checksums, that's checksum offload on
veth interfaces, not corruption — add `--dont-verify-checksums` mentally,
or disable offload: `ethtool -K eth0 tx off`.

## Roadmap

- **Replay injection** — a tcpreplay container that plays labelled attack
  PCAPs (e.g. malware-traffic-analysis.net) into a subnet as IDS fodder.
- **IDS tap** — Suricata/Zeek container watching the WAN and server subnets.
- **Firewall labs** — nftables policy on office edge routers.
- **`pcap2compose`** — reconstruct a network topology from a capture file
  and replay the capture into it (forensics capstone).

## Labs

| Lab | Topic |
|---|---|
| [00-tour](labs/00-tour.md) | Guided tour: feel the latency, trace the routing, watch DNS cross the WAN, break a link and watch OSPF heal it |
