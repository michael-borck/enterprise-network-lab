# Lab 01 — Intrusion detection

There is a Suricata sensor on the Perth router. It sees every packet
crossing the office boundary: all three Perth subnets and both WAN links.
In this lab you attack the network, watch the sensor notice, record the
incident, replay it, and then write a rule of your own.

Prerequisites: [Lab 00](00-tour.md), and the lab running (`make up`).

## 1. Meet the sensor

```sh
make ids-alerts
```

Probably nothing yet — the simulated office users are not doing anything
suspicious. Leave a live view running in a second terminal:

```sh
make ids-watch
```

The sensor is loading two rule files: the **Emerging Threats Open**
ruleset (about 52,000 real-world signatures, baked into the image so the
lab works offline) and **`config/ids/local.rules`** — seven short rules
written for this lab, which you can read end to end in two minutes.

Open `config/ids/local.rules` now. Every rule there is deliberately simple.

## 2. Attack the network

From a second terminal, run the scripted intrusion. It plays the part of
an attacker who already has a foothold on a Perth workstation:

```sh
make attack
```

Six things happen — a ping sweep, a port scan, a web fingerprint, an
admin-path probe, a cleartext credential post, and a C2 beacon plus a
DNS-exfil query. Watch them land in `make ids-watch`, then:

```sh
make ids-summary
```

You should see most of the seven `LAB` rules fire, plus at least one real
Emerging Threats signature — `ET SCAN Possible Nmap User-Agent Observed`.
Nothing here was faked for the demo: that ET rule is the same one running
in production networks, and it caught a real Nmap request.

**Question.** Two rules fired that describe the *same* Nmap activity — one
of yours and one from ET. Which is more specific, and which would you keep
if you had to keep only one?

## 3. Record the incident

Real analysts do not stare at a live feed; they capture and work the
evidence. Record the servers segment for 60 seconds while you attack it:

```sh
make capture FILE=my-incident.pcap SECS=60     # terminal 1
make attack                                    # terminal 2, straight away
```

The file lands in `pcaps/my-incident.pcap` on your machine. Look at it:

```sh
make perth
tcpdump -r /pcaps/my-incident.pcap -nn | head -20
tcpdump -r /pcaps/my-incident.pcap -nn 'tcp[tcpflags] & tcp-syn != 0 and src 10.10.10.101' | wc -l
```

That last count is the port scan, on its own, in one line.

Notice what else is in there: the London and LA user simulators browsing
the intranet the whole time. **Your attack is a minority of the traffic.**
That is the real problem with detection, and it is why this lab has
background noise at all.

## 4. Replay it

A capture can be played back onto the network. Nothing answers it — the
addresses in the file belong to conversations that already finished — but
a sensor cannot tell the difference, which makes replay the standard way
to test detection.

```sh
make replay PCAP=my-incident.pcap
make ids-summary
```

The same signatures fire again. You have just turned an incident into a
repeatable test case.

Two things had to happen first, and the replay container prints both:

- **`--fixcsum`.** A capture taken on the sending host records packets
  *before* the network card computes their checksums, so a raw capture is
  full of packets that look corrupt. Suricata will not inspect the payload
  of a packet with a bad checksum — replay an unfixed capture and the only
  thing you get is a pile of checksum alerts. `tcprewrite` recomputes them.
- **`--enet-dmac`.** A switch delivers a unicast frame only to the port
  that owns the destination MAC address. Spraying a capture onto a segment
  does *not* make a sensor elsewhere see it — this is exactly why real
  networks need a SPAN/mirror port or a network TAP. Here the replay
  rewrites the destination MAC to the sensor's, so every frame reaches it.

Try it without the second one and watch detection collapse:

```sh
make replay PCAP=my-incident.pcap SENSOR=10.10.30.99
```

That address does not exist, so no MAC can be resolved, the frames keep
their original destinations, and the switch delivers them to ports the
sensor is not on. Check `make ids-summary` — the counts barely move, even
though `tcpreplay` reports every packet sent successfully. **Traffic being
on the network is not the same as your sensor seeing it.**

## 5. Write a rule

The intranet has no `/admin` page, so *every* request for one is
suspicious. There is already a rule for that. Write the next one yourself.

Open `config/ids/local.rules` and add a rule that alerts when anyone
outside Perth requests the intranet at all — London and LA browsing HQ is
normal here, so this will be noisy, which is the point:

```
alert http [10.20.0.0/16,10.30.0.0/16] any -> 10.10.20.80 80 ( \
    msg:"LAB Branch office reached the intranet"; \
    flow:to_server; classtype:not-suspicious; sid:9000100; rev:1;)
```

Reload and watch:

```sh
make ids-reload
make ids-watch
```

Within seconds you will be drowning in alerts from the London and LA user
simulators. **That is the lesson.** A rule that fires on normal behaviour
is worse than no rule: it buries the seven alerts that mattered.

Now fix it. Some options, in increasing order of sophistication:

1. Narrow it to a path that is genuinely sensitive (`/admin`, `/export`).
2. Add a `threshold` so it alerts once per source per hour, not per request.
3. Invert it — alert on branch traffic to anything *except* the intranet.

Pick one, implement it, `make ids-reload`, and confirm the noise stops
while `make attack` still gets caught.

## 6. Clean up

```sh
: > logs/suricata/fast.log     # reset the alert log
```

## Questions to take away

1. The sensor sits on the router and sees everything crossing the office
   boundary. What does it *not* see? (Hint: two workstations on
   `perth-users` talking to each other.) What would you deploy to fix that,
   and what would it cost?
2. Your capture contained ~900 packets, of which the attack was a few
   hundred. In a real office of 500 people, what is that ratio?
3. Replay proved the signature works. What can replay *never* test?
4. The ET ruleset has ~52,000 rules and fired twice. Yours has seven and
   fired six times. What does that tell you about tuning a sensor for a
   specific network?
