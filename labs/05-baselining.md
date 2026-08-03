# Lab 05 — Baselining and the anomaly signatures miss

Lab 01 caught an attack because somebody had written a rule for it. This
lab is about the attacks nobody has written a rule for — where the traffic
is perfectly ordinary and the only thing wrong with it is *who* is doing
it, *when*.

To have a "when" at all, this network runs on a clock. Each office works
its own hours, and time is compressed so a full 24-hour day takes about 24
minutes.

Prerequisites: [Lab 00](00-tour.md). Lab 01 helps.

## 1. Watch the sun move

```sh
make clock
```

```
simulated time 05:41 UTC   (1 simulated hour = 60s real, so a day takes 24 min)

  OFFICE     LOCAL    STATE
  Perth      13:41    working
  Pilbara    13:41    working
  London     05:41    closed
  LA         21:41    closed
```

Now confirm the offices behave the way the clock says:

```sh
make activity
```

That counts packets per office subnet for ten seconds. Only the offices
that are *awake* show up. Run `make clock` and `make activity` a few times
over several minutes and watch the busy office change.

This is the whole point of a multinational network: **there is no such
thing as "night".** Something is always awake, so "unusual hour" only
means anything relative to the office the traffic came from.

## 2. Meet the satellite site

The fourth office is different. Pilbara is a remote mine site on a
satellite link, and it also has no DNS resolver of its own.

```sh
make pilbara
ping -c 5 10.10.20.80          # ~600ms, and the RTT wobbles
dig intranet.corp.lab          # every lookup crosses the satellite
```

Compare with London, which has a local resolver:

```sh
make london
dig intranet.corp.lab ; dig intranet.corp.lab    # second one is instant
```

Two things to notice, both of which matter for detection:

- **Jitter.** The satellite RTT varies by tens of milliseconds while the
  terrestrial links are rock steady. If you were alerting on "RTT above
  X", this site would page you forever.
- **Every Pilbara lookup appears at the Perth resolver.** From Perth's
  point of view, one small site generates a disproportionate share of DNS
  traffic. Normal for this network — and indistinguishable, on volume
  alone, from DNS tunnelling.

A baseline that does not know about the satellite site will be wrong about
it in both directions.

## 3. Record a full day

Capture a whole simulated day — about 25 real minutes. Start it and go do
something else:

```sh
make capture FILE=fullday.pcap NET=10.10.20 SECS=1500
```

Then profile it:

```sh
make baseline PCAP=fullday.pcap
```

You get activity per office, per **simulated local hour**:

```
                 0  1  2  3  4  5  6  7  8  9  10 11 12 13 14 15 16 17 18 19 20 ...
  LA                    #              =  +  +  +  +  +  +  +  +  +  =  =
  London                #              =  =  +  +  +  =  +  +  +  *  =  =
  Perth                 #              =  =  *  *  *  +  *  +  +  *  =  =
  Perth-servers   *  +  %  +  =  +  +  *  *  *  #  *  +  *  *  *  *  *  #  +  =
  Pilbara               @              =  =  +  +  +  =  +  +  +  +  =  =  :
```

Read it before you read the next paragraph. What do you notice?

Two patterns should jump out. Each office is busy across its own working
day and silent either side of it; and every office spikes at 02:00 local,
when its nightly backup runs. The backup is out of hours, large, and
completely legitimate. (There is also a shallow dip around 12:00 local —
lunch — though on a log scale it is subtle, and clearer at some offices
than others.)

The row that matters most is **Perth-servers**, and it is the only one
busy around the clock. It is not doing anything unusual: it is serving
London in Perth's evening, LA in Perth's night, and Perth in the morning.
That is what a headquarters looks like in a company that spans time zones,
and it is why "out of hours" is meaningless as a global rule. It has to be
asked per office.

Note the scale is **logarithmic**. The backup moves an order of magnitude
more data than an hour of browsing, so on a linear scale the entire working
day flattens into the bottom level and the rhythm disappears. Choosing the
scale is part of the analysis, not decoration.

And the backup is the trap. A naive rule — "alert on large transfers
outside business hours" — fires on it every single night, at four
different offices, forever. Within a week nobody reads those alerts any
more, and that is how the real one gets missed.

## 4. Now hide something in it

Pick an office the clock says is closed, and stage a bulk transfer from it:

```sh
make clock                     # find a closed office
make anomaly SITE=london       # or la / perth / pilbara
```

There is nothing malicious in those packets. No exploit, no malware, no
suspicious user agent. It is the same HTTP GET the office makes all day —
just three of them, at an hour when that office is empty.

Check what the signature-based sensor made of it (clear the log first so
you are looking only at this):

```sh
make ids-reset
make anomaly SITE=london
make ids-summary
```

Nothing at all. **Suricata is not wrong.** No signature matched because no
signature *could* match: every packet was well-formed, expected, and
individually innocent. Signatures answer "is this packet bad?". They
cannot answer "is this normal for this office at this hour?".

Now capture and profile again, and find it in the heatmap:

```sh
make capture FILE=after.pcap NET=10.10.20 SECS=180
make baseline PCAP=after.pcap
```

## 5. Build a rule that would actually work

Sketch a detection for this. Be specific about what it needs:

1. **What is the baseline?** Per office, per hour, what volume is normal?
   How many days of data before you would trust it?
2. **How do you exclude the backup?** By time window, by destination, by
   source host, or by size? Each choice is wrong in a different way —
   describe how an attacker beats each one.
3. **Where does the satellite site fit?** Pilbara is low-volume, high-
   latency, and DNS-heavy. Does it get its own baseline, or does one
   network-wide threshold cover everything?
4. **What is your false-positive budget?** An analyst who gets more than a
   handful of alerts per shift stops reading them. Work backwards from
   that to a threshold.

Try it: run `make anomaly` with a volume small enough that your proposed
threshold misses it. How small did you have to go? That number is what
your detection actually costs the attacker.

## 6. A note on why the sensor is quiet enough to trust

Run `make ids-summary` on a normal day and you get almost nothing. That is
not the default state of a sensor — it is the result of tuning, and you can
read it in `config/ids/threshold.config`.

Watching Docker `veth` interfaces, Suricata is handed frames whose captured
length disagrees with their claimed length, and it reports each one:
"truncated packet", "invalid checksum", "excessive retransmissions". An
8 MB transfer produced about **1,600 of these**. None of them is a
detection; all of them are the engine describing its own view of the wire.

Left alone they would bury every real alert — which is how sensors fail in
practice. Not by missing attacks, but by producing so much noise that
nobody reads the output. The suppressions in that file are documented, and
they touch no attack signature: `make attack` still fires every rule from
Lab 01.

Worth internalising: **a quiet sensor is a maintained sensor.** If yours
has never been tuned, its silence means nothing.

## 7. Speed the clock up (optional)

`SIM_HOUR` is the real seconds per simulated hour. Drop it to see many
days quickly:

```sh
make down
SIM_HOUR=10 make up            # a full day every 4 minutes
make clock SIM_HOUR=10
make baseline PCAP=x.pcap SIM_HOUR=10
```

Anything you use to read the data has to be told the same `SIM_HOUR`, or
your hour buckets will be nonsense — which is its own lesson about
timestamps and timezones in log analysis.

## Questions to take away

1. Your sensor saw every packet of the anomaly and alerted on none of
   them. Was it working correctly? Justify the answer to a manager who
   just paid for it.
2. The nightly backup and the exfiltration look nearly identical on the
   wire. List everything *outside* the packets that would tell them apart.
3. A global company has no quiet hours. What replaces "out of hours" as
   the useful signal?
4. Pilbara has 600ms RTT, jitter, and packet loss as its *normal* state.
   What does that do to detection that relies on timing or on
   session-completion rates?
5. You have four offices. Roughly how much traffic history would you need
   before "unusual for a Tuesday" is a statement you could defend?
