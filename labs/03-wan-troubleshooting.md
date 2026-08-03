# Lab 03 — WAN troubleshooting

Seven faults can be injected into this network. Your job is to work out
what is wrong using only the tools a network engineer actually has — and
then say *which link, which direction, and what kind of fault*.

This lab is a fair test only if you do not read the Makefile targets under
"Lab 03" or the answer key at the bottom until you have committed to a
diagnosis. Injecting a fault is one command:

```sh
make fault N=1        # inject fault 1
make fault-clear      # remove all faults, back to normal
```

Get someone else to pick the number if you can.

## Your toolkit

Everything runs from a workstation shell (`make perth`, `make london`,
`make la`) or from the host:

| Command | What it tells you |
|---|---|
| `ping -c 20 <ip>` | loss, RTT, variation. The first thing, always. |
| `traceroute -n <ip>` | which path, and where the latency appears |
| `mtr -n --report -c 20 <ip>` | loss *per hop* — ping and traceroute combined |
| `make iperf` | throughput Perth→London (see the caveat below) |
| `dig <name>` / `dig @<server> <name>` | name resolution, and whether a specific server answers |
| `curl -w "%{time_total}"` | what the user actually experiences |
| `tcpdump -ni eth0` | ground truth, when you stop believing the tools |
| `make routes` / `make neighbors` | what the router believes about the topology |

Two lab-specific ones worth knowing:

- `http://10.10.20.80/` is the small intranet page.
- `http://10.10.20.80:8080/large.bin` is an 8 MB file. Size matters —
  several faults only show up on a large transfer.

A caveat on measuring throughput here: an 8-second `iperf3` run across a
250ms link spends most of its time in TCP slow start, so even a healthy
link reports only ~1.4 Mbit/s. That is not a fault, it is the
bandwidth-delay product — and it is exactly why long-distance links need
window tuning. For this lab, time the 8 MB download instead; it is the
more honest measure:

```sh
curl -o /dev/null -w "%{size_download} bytes at %{speed_download} B/s\n" \
     http://10.10.20.80:8080/large.bin
```

A healthy Perth→London path manages roughly 2–3 MB/s.

## Method

Work outside-in, and write down what you observe before you interpret it:

1. **Is it reachable at all?** `ping` by IP, not by name.
2. **Is it a name problem?** If IP works and the name does not, stop
   looking at the WAN.
3. **Which link?** `traceroute` from both ends. The RTT jump is the link.
4. **What kind of fault?** Loss, latency, jitter, throughput, or size.
   These have different signatures — see below.
5. **Which direction?** This is the step people skip. A one-way fault
   looks like a two-way fault from one end only.

### Signatures

| Symptom | Likely fault |
|---|---|
| Steady RTT, some packets missing | plain packet loss |
| RTT jumps around wildly (min 130 / max 400) | jitter |
| Ping fine, small pages fine, big transfers stall completely | MTU / size-related black hole |
| Everything works but slowly, at a suspiciously round rate | bandwidth limit |
| Name lookups fail, IPs work | DNS |
| RTT higher than it should be, path has an extra hop | traffic taking the long way |
| Loss visible from one end only | one-way fault |

## The exercises

Run each of these, diagnose it, then clear it:

```sh
make fault N=1 ; ... ; make fault-clear
```

For each fault, write down:

1. What the user would complain about ("the intranet is slow" is not
   specific enough — slow how?).
2. Which link and which direction.
3. The single command whose output convinced you.
4. What you would ask the carrier to check.

**Faults 1–7 exist.** Some are subtle. At least one will look like a
different fault than it is if you only ping.

## A worked example — fault 1

```
$ make fault N=1
$ make perth
perth-ws1> ping -c 30 10.20.10.101
30 packets transmitted, 26 received, 13% packet loss
rtt min/avg/max/mdev = 252.141/257.226/267.764/4.066 ms
```

Loss, but the RTT is rock steady — 252 to 267ms with 4ms deviation. That
rules out congestion (which would inflate and vary the RTT as queues fill)
and points at a link dropping frames: a bad cable, a dirty fibre, a
failing SFP. Confirm the link with `mtr`:

```
perth-ws1> mtr -n --report -c 20 10.20.10.101
```

The hop where loss first appears — and stays — is the one to report.

Note the trap: loss at an *intermediate* hop in `mtr` that does not carry
through to the final hop is usually a router deprioritising ICMP to its
own control plane, not real loss. Only loss that persists to the
destination counts.

## Escalating properly

"The London link is broken" gets you nowhere with a carrier. This does:

> Perth→London (172.16.1.0/24), sustained 12% packet loss on traffic
> Perth→London only; return path clean. RTT stable at 253ms with 4ms
> deviation, so not congestion. Started 14:05 AWST. Ping from 172.16.1.1
> to 172.16.1.2: 30 packets, 4 lost. Small transfers unaffected;
> throughput on an 8 MB transfer fell from ~2.6 MB/s to ~300 KB/s.

Direction, evidence, timing, and what you already ruled out.

## Questions to take away

1. Fault 4 lets ping and small web pages through but kills large
   transfers. Explain to a helpdesk colleague why "the network is fine,
   I can ping it" is wrong.
2. Two faults produce roughly the same download speed for very different
   reasons. Which two, and what distinguishes them?
3. One fault changes the *path* rather than damaging it. How would you
   have noticed if you had only measured throughput?
4. If a fault only affects one direction, which of your tools can see
   that, and which cannot?

---

<details>
<summary><b>Answer key</b> — don't open until you've committed to a diagnosis</summary>

| N | Fault | Where | How to confirm |
|---|---|---|---|
| 1 | 12% packet loss | Perth→London egress | `ping` shows loss with stable RTT; `mtr` localises it |
| 2 | Heavy jitter (125ms ± 95ms) | Perth→London egress | RTT min/max spread of hundreds of ms, large mdev |
| 3 | 30% loss, **one direction only** | London→Perth egress | Loss from Perth; London sees requests arriving fine. `tcpdump` on both ends settles it |
| 4 | Path-MTU black hole — packets over 1200 bytes to London silently dropped, no ICMP | Perth router, forward path | ping fine, `/` fine, `large.bin` returns 0 bytes. `ping -s 1400 -M do` fails while `-s 1000` works |
| 5 | London's DNS resolver stopped | London office | `dig` times out; `curl` by IP works. Classic "it's always DNS" |
| 6 | Bandwidth capped to 1 Mbit | Perth→London egress | `large.bin` drops to ~115 KB/s, roughly 20x slower than healthy; latency and loss both normal. `iperf3` is a poor test here — see the caveat above |
| 7 | Static route sends Perth→London via LA; return path still direct | Perth router | `traceroute` from both ends shows different paths; RTT ~300ms instead of 250ms |

Fault 4 is the one that punishes ping-only diagnosis. Fault 3 is the one
that punishes testing from one end. Fault 7 is invisible to throughput
tests but obvious to `traceroute`.

</details>
