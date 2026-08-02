# Lab 02 — Firewall the edge

Lab 01 detected attacks. This one stops them. You will write real
`nftables` policy on the Perth router — the same firewall engine running
on every modern Linux box and inside most Linux-based appliances — and
prove it works against live connections, not against a simulator.

Prerequisites: [Lab 00](00-tour.md). Lab 01 helps but is not required.

## 1. The router is wide open

Every packet between two subnets crosses the Perth router. Right now
nothing is filtered. Confirm it:

```sh
make fw-load     # apply config/nftables/perth.nft as shipped
make fw-test     # four real connection attempts
```

All four succeed. Two of them should worry you: a London workstation can
ping a Perth workstation, and any branch machine can reach anything in the
HQ servers subnet.

Look at the policy you just loaded:

```sh
make fw-list
```

Then open `config/nftables/perth.nft` in your editor. Read it top to
bottom — it is about 60 lines and every one of them is doing something.
Note the structure:

- **`input`** — traffic addressed *to the router itself*. OSPF lives here.
- **`forward`** — traffic *passing through*. This is where office policy goes.
- **Named sets** (`@branch_users`, `@hq_servers`) so rules read like English.
- **`ct state established,related accept`** at the top of `forward`.

That last one deserves a moment. It accepts return traffic for connections
already allowed, so every rule below it only has to decide about *new*
connections. Delete it and a rule that permits a request will still break,
because the reply gets blocked. This is the single most common firewall
mistake, and it is one line.

## 2. Watch before you block

The two `counter` rules have no verdict — they measure without changing
anything. Generate some traffic and watch them move:

```sh
make fw-counters
make fw-test
make fw-counters
```

This is how you write policy on a network you do not fully understand:
count first, block second. Blocking something you have not measured is how
you take the business offline at 9am.

## 3. Exercise 1 — contain the branch offices

London and LA should reach the intranet web server and nothing else in the
HQ servers subnet. In `config/nftables/perth.nft`, uncomment the two lines
under **Exercise 1**, then:

```sh
make fw-load
make fw-test
```

Loading is atomic: if you make a syntax error, nftables rejects the entire
file and your previous ruleset stays live. You cannot half-apply a policy.

Expected: intranet HTTP still works, the ping to the HQ DNS server is now
blocked — **and DNS is broken too.** That is not a bug in the lab; it is
the trap. Keep going.

## 4. Exercise 3 (yes, out of order) — you just broke DNS

```sh
make london
dig gw.la.corp.lab
```

`no servers could be reached`. London's resolver forwards `corp.lab`
queries to Perth's DNS server at `10.10.20.53`, and you just dropped
everything from the branches to the servers subnet except port 80.

Fix it by uncommenting **Exercise 3** — but *where* you put the line
decides whether it works. nftables evaluates rules top to bottom and the
first verdict wins. Put the DNS `accept` **after** the Exercise 1 `drop`
and it will never be reached; the packet is already gone.

Move it above the drop, reload, and verify:

```sh
make fw-load
make fw-test
```

All three of the first checks should now pass, with the ping still blocked.

**This is the lesson of the whole lab.** A firewall rule is not a
statement of intent, it is a position in an ordered list. "I allowed DNS"
is not true if the drop above it ran first.

## 5. Exercise 2 — stop lateral movement

The most valuable single control on an office network: workstations have
no business talking to workstations in other offices. Uncomment
**Exercise 2**, reload, and confirm with `make fw-test` that the last check
flips to BLOCKED.

Now check you did not break the office:

```sh
make fw-test          # intranet + DNS must still work
make london
curl http://intranet.corp.lab/     # the business still functions
```

Then confirm from the attacker's side — if you have done Lab 01:

```sh
make attack
```

The port scan and the C2 beacon now fail at the network layer instead of
merely being detected. Compare `make ids-summary` before and after: fewer
alerts, because fewer packets ever arrived.

## 6. Prove the drops

`log prefix "FW-DROP..."` writes to the kernel ring buffer — which a
container is not permitted to read (`dmesg` fails inside the router). In
this lab you observe drops with counters instead:

```sh
make fw-counters
```

On a real router you would ship those log lines to a SIEM. Worth knowing
the difference between "the rule fired" (counter) and "I can prove what it
dropped, when, to whom" (log).

## 7. Reset

```sh
make fw-flush     # wide open again, file untouched
```

## Exercise 4 — break it on purpose

The `input` chain is deliberately `policy accept`. Change it to
`policy drop`, reload, and wait about 40 seconds:

```sh
make routes
```

The OSPF routes are gone and the offices are partitioned. You dropped your
own routing protocol. This is a genuine outage cause: the firewall did
exactly what you told it to.

Fix it properly — keep `policy drop` but add the rules that let the router
be a router:

```
ip protocol ospf accept
ct state established,related accept
iif lo accept
```

Reload, wait for OSPF to re-converge, and confirm with `make neighbors`
and `make routes`. `make fw-flush` if you want out.

## Questions to take away

1. `ct state established,related accept` is one line. Explain to someone
   non-technical why removing it breaks a rule that "obviously" allows
   web browsing.
2. Your policy blocks branch→HQ except the intranet. What does it do about
   HQ→branch? Should it?
3. You blocked workstation-to-workstation across offices. What lateral
   movement does that *not* stop?
4. Exercise 4 partitioned the network from a two-word change. What would
   you do differently on a router you could not physically reach?
