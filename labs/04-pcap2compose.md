# Lab 04 — Rebuild a network from its traffic

The capstone. You are handed a packet capture from an organisation you
have never seen. No diagrams, no asset register, nobody to ask. From the
traffic alone, work out what their network looked like — then stand a
working copy of it back up in Docker and replay the incident into it.

Prerequisites: [Lab 01](01-ids.md) (you need a capture, and the replay
tooling).

## 1. Get a capture

Use the one you made in Lab 01, or make a fresh one:

```sh
make capture FILE=incident.pcap SECS=60     # terminal 1
make attack                                 # terminal 2
```

From here on, pretend you know nothing about this network.

## 2. Read the evidence

```sh
python3 scripts/pcap2compose.py pcaps/incident.pcap -o rebuilt/
```

No dependencies — a forensic workstation should not need `pip install`
before it can look at evidence. It writes two files:

- `rebuilt/REPORT.md` — what was inferred, and how confident it is
- `rebuilt/docker-compose.yml` — a runnable reconstruction

Read the report first. On the standard capture it finds roughly:

```
938 packets over 36 seconds
8 hosts in 4 subnet(s)
protocols: tcp 799, arp 78, udp 56, ip/89 4, icmp 1
```

Work through it and satisfy yourself *how* each conclusion was reached
before you look at the code:

**Hosts** are easy — every source address that sent a packet.

**Subnets** are a guess. A capture never shows you a netmask; the tool
assumes /24 because that is what most office networks use. If the real
network used /22, the reconstruction still runs but the boundaries are
wrong, and nothing in the evidence would tell you.

**Services** are inferred from what *answered*, not what was asked for.
A TCP SYN-ACK from port 80 proves something was listening. A SYN to port
25 with no reply proves only that somebody was curious. The report keeps
those in separate columns — "answered on" and "probed for" — and the
difference between those two columns is the difference between an asset
inventory and an attacker's wishlist.

**Routers** are the interesting one. Every packet a router forwards keeps
the original sender's IP but gets the router's MAC address. So a MAC
address seen carrying source addresses from subnets it is not itself
addressed in must be forwarding. The tool uses ARP to establish which
addresses a MAC genuinely owns, because ARP is a host *claiming* an
address — something a relayed frame never does.

**Scanning** falls out for free: a host probed on 301 different ports,
answering on one, is not a busy server. It is a target.

## 3. Stand it back up

```sh
cd rebuilt/
docker compose -p rebuilt up -d
docker compose -p rebuilt ps
```

(On Docker Desktop, run it inside the nested host like the main lab does:
`docker exec -w /lab/rebuilt enterprise-lab-vm docker compose -p rebuilt up -d`.
You must `make down` the main lab first — the reconstruction claims the
same subnets, and Docker will not allow two networks on one subnet.)

Then prove it is a real network, not a diagram:

```sh
docker compose -p rebuilt exec host-10-10-10-101 ping -c2 10.10.20.80
docker compose -p rebuilt exec host-10-10-10-101 ping -c2 10.20.10.102
```

Traffic crosses subnets, through a router that you inferred from MAC
addresses, on a network you rebuilt from a file.

## 4. Now find what is wrong with it

This is the part that matters. Your reconstruction is **confidently
incorrect** in several ways, and a real investigation lives or dies on
knowing which parts of a finding are evidence and which are inference.

Compare `rebuilt/REPORT.md` against the real thing
([the README topology](../README.md)) and find the differences. Some to
look for:

1. **The three routers became one.** The real network has a router in
   each office. The capture was taken on a single segment in Perth, so
   only the Perth router's MAC was ever seen; the other two are invisible
   and their subnets appear to hang directly off the one router you found.
   *A capture only documents the network from where you stood.*
2. **Three of the four router addresses are guesses.** Look for the
   `# GUESS` comments in the compose file — the tool synthesised `.254`
   because it never saw the router addressed on those subnets. It says so.
3. **The WAN links are gone.** The real offices are joined by point-to-point
   links with 250ms of latency. Nothing in a capture taken inside one
   office reveals them, so the rebuild connects everything at LAN speed.
4. **Hosts that stayed quiet do not exist.** Anything that did not transmit
   during your 60-second window is simply absent.
5. **The intranet is not really there.** The tool records that something
   answered on port 80 but does not start a web server. A capture proves a
   port answered; it cannot tell you what software it was or what it would
   have said to the next request.

Write these up. "The network has one router" is a finding you would have
to defend, and the honest version is: *"a single forwarding device was
observed; the capture cannot exclude others."*

## 5. Replay the incident into your reconstruction

```sh
make replay PCAP=incident.pcap SENSOR=10.10.20.254
```

The attack plays out again inside the network you rebuilt from it. This is
the closed loop: evidence → reconstruction → re-enactment.

And it is also where replay's limits bite. Nothing in the rebuilt network
*responds* — the packets are a recording. You can test whether a sensor
would have caught the attack. You cannot ask "what if the firewall had
been configured differently?", because there is no live conversation to
change.

## 6. Try it on a capture you did not make

Take a capture from somewhere else in the lab and see how the picture
changes:

```sh
make capture FILE=wan.pcap NET=172.16.1 SECS=60
python3 scripts/pcap2compose.py pcaps/wan.pcap -o rebuilt-wan/
```

That one is taken on the WAN link between Perth and London. Compare its
report to the first: different vantage point, different network, same
organisation. Which one would you rather have as an investigator, and why?

## Questions to take away

1. The tool separates "answered on" from "probed for". Why is treating
   those as the same thing a career-limiting mistake in an IR report?
2. Your reconstruction shows one router. Write the sentence you would put
   in a report — one that is true, useful, and does not overstate.
3. What would you need *in addition* to the capture to produce a
   reconstruction you would stake a court appearance on?
4. The tool assumes /24 everywhere. Design a heuristic that would do
   better, and describe the traffic it would need to see.
5. You can rebuild the topology but not the *behaviour*. Which security
   questions can this method answer, and which can it never answer?
