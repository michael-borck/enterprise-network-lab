# enterprise-network-lab

**Landing page: https://enterprisenetwork.borck.education/**

A miniature multi-site enterprise network that runs entirely in Docker.
Four sites — **Perth (HQ)**, **London**, **Los Angeles**, and a remote
**Pilbara** mine site on a satellite link — connected by latency-shaped WAN
links and routed with real OSPF (FRR). Each office keeps its own working
hours, so traffic follows the sun around the network.

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
    subgraph Pilbara["Pilbara mine site (10.40.0.0/16)"]
        MR[pilbara-router]
        MU["users 10.40.10.0/24<br/>ws1 .101 · sim .102<br/><i>no local DNS</i>"]
        MU --- MR
    end
    PR ==|"172.16.1.0/24<br/>~250ms RTT"| LR
    PR ==|"172.16.2.0/24<br/>~150ms RTT"| AR
    LR ==|"172.16.3.0/24<br/>~140ms RTT"| AR
    PR ==|"172.16.4.0/24<br/>satellite: ~600ms RTT<br/>jitter + 0.5% loss"| MR
```

## Addressing plan

| Network | Subnet | Notable hosts |
|---|---|---|
| perth-users | 10.10.10.0/24 | ws1 `.101`, gateway `.254` |
| perth-servers | 10.10.20.0/24 | dns `.53`, intranet `.80`, gateway `.254` |
| perth-dmz | 10.10.30.0/24 | (empty for now), gateway `.254` |
| london-users | 10.20.10.0/24 | ws1 `.101`, dns `.53`, user-sim `.102`, gateway `.254` |
| la-users | 10.30.10.0/24 | ws1 `.101`, dns `.53`, user-sim `.102`, gateway `.254` |
| pilbara-users | 10.40.10.0/24 | ws1 `.101`, user-sim `.102`, gateway `.254` — **no local resolver** |
| wan-perth-london | 172.16.1.0/24 | perth `.1`, london `.2` — 125ms egress delay each side |
| wan-perth-la | 172.16.2.0/24 | perth `.1`, la `.2` — 75ms each side |
| wan-london-la | 172.16.3.0/24 | london `.1`, la `.2` — 70ms each side |
| wan-perth-pilbara | 172.16.4.0/24 | perth `.1`, pilbara `.2` — satellite: 300ms each side, ±20ms jitter, 0.5% loss |

DNS: Perth's resolver (`10.10.20.53`) is authoritative for `corp.lab`.
London and LA resolvers forward `corp.lab` queries to Perth across the
WAN and cache the answers — first lookup is slow, the next is instant.
Pilbara deliberately has **no resolver of its own**, so every lookup there
makes the full satellite round trip. The contrast is the point.

## Follow the sun

Each office works its own hours (09:00–17:00 local, with a lunch dip and a
02:00 nightly backup). Time is compressed — one simulated hour per 60 real
seconds by default, so a full day takes 24 minutes:

```sh
make clock       # where each office is in its working day
make activity    # who is actually transmitting right now
```

Set `SIM_HOUR` to change the compression (`SIM_HOUR=10 make up` gives a day
every 4 minutes; `SIM_HOUR=3600` is real time). Anything reading the data
back — `make baseline` — needs the same value.

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
  container is impossible there, no matter the configuration. So
  `make up` transparently starts one privileged `docker:dind` container
  (`enterprise-lab-vm`) and runs the entire lab nested inside it, where
  networks are ordinary kernel bridges and everything behaves like Linux.
  Every `make` target proxies through it; the workflow is identical.

### Podman

Podman runs the same compose file. On macOS and Windows the Podman machine is
a Linux VM with real kernel bridges, so the lab runs directly — no DinD layer.
On Linux it runs against the host's netavark bridges.

```bash
CONTAINER_ENGINE=podman make up
CONTAINER_ENGINE=podman make test
CONTAINER_ENGINE=podman make down
```

Use **rootful** Podman: the routers need `SYS_ADMIN`/`NET_ADMIN`, `tc netem`
and `net.ipv4.ip_forward` sysctls.

```bash
# macOS/Windows
podman machine set --rootful
podman machine stop && podman machine start
```

Every network sets `isolate: "false"`. Podman 6 / netavark 2 isolates bridge
networks by default, which would otherwise drop traffic forwarded between the
router containers' interfaces. Docker ignores the option and keeps using
`gateway_mode_ipv4=routed`; Podman ignores the Docker-only gateway mode and
uses the isolation opt-out.

`make up` does not rely on the compose front-end preserving that option:
`scripts/podman-networks.sh` creates the networks natively with
`isolate=false` (including the `.200` WAN gateways), and the Makefile passes
`scripts/podman-networks.yml` so Compose treats them as external.

One difference from the Docker setup: Podman's managed bridge driver NATs
outbound traffic by default, where Docker's `routed` mode does not. The lab's
own traffic never needs real internet, so if you want the Docker version's
"no path to the internet" guarantee, block egress at the host firewall.

## How it works

- **Networks use `routed` gateway mode (Docker) / `isolate: "false"` (Podman)
  and are not `internal`** — both are required for a container to forward
  transit traffic (see the section above). There is no NAT anywhere, so the
  lab has no path to the internet;
  cross-subnet traffic can only flow through the FRR routers, and what you
  see in `traceroute` is real routing.
- **Editable configs are mounted as directories, not files.** Rewriting a
  bind-mounted *file* on the host does not reliably reach the container —
  the container can see a truncated copy. `config/nftables/` and
  `config/ids/` are therefore directory mounts.
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

## Labs

| Lab | Topic |
|---|---|
| [00-tour](labs/00-tour.md) | Guided tour: feel the latency, trace the routing, watch DNS cross the WAN, break a link and watch OSPF heal it |
| [01-ids](labs/01-ids.md) | Intrusion detection: attack the network, watch Suricata catch it, capture the incident, replay it, write and tune your own rule |
| [02-firewall](labs/02-firewall.md) | Edge firewall: write real nftables policy, contain the branch offices, stop lateral movement, and learn why rule order is everything |
| [03-wan-troubleshooting](labs/03-wan-troubleshooting.md) | Diagnose seven injected WAN faults — loss, jitter, one-way loss, an MTU black hole, DNS, a bandwidth cap, and asymmetric routing |
| [04-pcap2compose](labs/04-pcap2compose.md) | Capstone: reconstruct an unknown network from a packet capture, stand it back up in Docker, and find everything the reconstruction gets confidently wrong |
| [05-baselining](labs/05-baselining.md) | Behavioural detection: profile a full simulated day per office, then find an attack made entirely of ordinary packets sent at the wrong hour |
