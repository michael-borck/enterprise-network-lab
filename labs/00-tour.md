# Lab 00 — Tour of the enterprise

A guided first walk through the network. Everything here is done with
standard tools from a workstation shell — no lab magic.

Bring the enterprise up first:

```sh
make up
```

Give it ~15 seconds for OSPF to converge, then grab a shell in Perth:

```sh
make perth
```

## 1. Feel the geography

```sh
ping -c 4 10.20.10.101     # London workstation
ping -c 4 10.30.10.101     # LA workstation
```

London answers in ~250ms, LA in ~150ms. Same datacentre, same laptop —
the distance is `tc netem` on the WAN links, but your tools can't tell
the difference. Now trace the path:

```sh
traceroute -n 10.20.10.101
```

Three hops: your office router, the London router, the workstation.
Notice where the latency appears — the WAN hop.

## 2. Watch DNS cross the WAN

Still in Perth, names resolve locally (fast — the resolver is in the
servers subnet next door):

```sh
dig intranet.corp.lab
```

Now exit and go to London (`exit`, then `make london`):

```sh
dig gw.perth.corp.lab      # first time: slow (~250ms+) — forwarded to Perth
dig gw.perth.corp.lab      # second time: ~0ms — answered from London's cache
```

(Why not `intranet.corp.lab`? The simulated users browse it constantly,
so it's almost always already in the cache — check with `dig` and see.)

Look at `Query time:` in each response. That difference *is* why every
office runs its own resolver.

## 3. Browse the intranet like a Londoner

```sh
curl -w "\ntotal: %{time_total}s\n" http://intranet.corp.lab/
```

A full TCP handshake plus HTTP exchange at 250ms RTT — count the round
trips the total time implies.

## 4. Find the routing protocol (recon)

Someone is chattering on your office LAN. From any workstation:

```sh
timeout 15 tcpdump -ni eth0 not tcp and not udp
```

Those multicast packets to `224.0.0.5` are OSPF hellos from your office
router. You've just fingerprinted the routing protocol without touching
a router. Now look at it from the inside (from your host machine):

```sh
make neighbors    # who Perth's router peers with
make routes       # O = routes learned via OSPF
```

## 5. Break a WAN link and watch the network heal

Start a slow ping from Perth to London and leave it running:

```sh
make perth
ping 10.20.10.101
```

In another terminal, cut the Perth–London cable:

```sh
make wan-cut
```

Watch the ping closely. You'll likely lose *nothing* — but two things
change mid-stream: the RTT jumps from ~250ms to ~300ms, and the TTL
drops by one. Traffic to London now goes via **LA** (Perth→LA 150ms +
LA→London 140ms = one extra router hop). Perth's router saw its own
interface die and re-ran SPF immediately; the updated LSAs reached
London through LA within a second. Confirm with `make routes` — the
metric for 10.20.10.0/24 went from 20 to 30.

Repair the cable with `make wan-heal` and watch it switch back. Notice
the asymmetry: failover was instant, but fail-*back* takes about a
minute — the routers must re-discover each other, wait out the DR
election timer, and re-sync their databases before the direct route
returns. Breaking is always faster than trusting again.

**Now try a *silent* failure.** An admin-down is a clean signal; real
WANs more often just start eating packets. Simulate that with netem —
the interface stays up but drops everything:

```sh
make wan-blackhole
```

This time the ping goes dark for ~40 seconds before OSPF gives up on
the neighbour (the dead-interval) and reroutes. That's the difference
between failure *detection* and failure *signalling* — and why real
WANs run BFD. Repair it with `make wan-heal`.

## Questions to take away

1. Why does the second `dig` from London return in ~0ms? What TTL is
   the cached answer carrying, and when will London pay the WAN cost again?
2. The `curl` from London took several round trips. List them.
3. OSPF hellos are visible on the users subnet. What could an attacker
   do with that? What would you change on the router?
4. During the link failure, roughly how long was the outage? What OSPF
   timers control that, and what's the trade-off in tuning them down?
