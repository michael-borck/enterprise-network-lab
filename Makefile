# On native Linux the lab runs directly on the host's Docker. On Docker
# Desktop (macOS/Windows) container networking goes through a userspace
# switch that only delivers frames to IPs registered on each network —
# transit routing through the FRR containers is impossible there. So on
# Docker Desktop the whole lab runs nested inside a privileged docker:dind
# container ($(LAB_HOST)), where networks are real kernel bridges.
#
# Podman is also supported: CONTAINER_ENGINE=podman make up. The Podman
# machine on macOS/Windows is a Linux VM with real kernel bridges, so the lab
# runs directly there too (no DinD). Use rootful Podman: the routers need
# SYS_ADMIN/NET_ADMIN, tc netem and forwarding sysctls.
ENGINE ?= $(if $(CONTAINER_ENGINE),$(CONTAINER_ENGINE),$(shell command -v docker >/dev/null 2>&1 && echo docker || echo podman))

ifeq ($(ENGINE),podman)
  COMPOSE := $(shell podman compose version >/dev/null 2>&1 && echo "podman compose" || echo "podman-compose")
  ON_DESKTOP := 0
else
  COMPOSE := docker compose
  ON_DESKTOP := $(shell docker info -f '{{.OperatingSystem}}' 2>/dev/null | grep -c 'Docker Desktop')
endif

LAB_HOST = enterprise-lab-vm

ifeq ($(ON_DESKTOP),1)
DC = docker exec -w /lab $(LAB_HOST) docker compose
else
DC = $(COMPOSE)
endif

.PHONY: up down destroy host build ps logs test routes neighbors perth london la \
        wan-cut wan-blackhole wan-heal attack capture replay \
        ids-alerts ids-watch ids-summary ids-reload ids-reset \
        fw-load fw-list fw-flush fw-counters fw-test \
        fault fault-clear iperf rebuild clock activity pilbara baseline anomaly

up: host
	@find . -name '._*' -delete 2>/dev/null || true
	@if [ "$(ENGINE)" = podman ] && \
	   [ "$$(podman info --format '{{.Host.Security.Rootless}}' 2>/dev/null)" = "true" ]; then \
	  echo "NOTE: this lab needs rootful Podman (SYS_ADMIN, tc, forwarding sysctls)."; \
	  echo "      macOS/Windows: podman machine set --rootful && podman machine stop && podman machine start"; \
	  echo "      Linux:         run make as root, or use sudo podman ..."; \
	fi
	$(DC) up -d --build
	@# The sensor lives in the Perth router's network namespace. If compose
	@# recreated that router, the sensor is still attached to the old, dead
	@# namespace and silently sees nothing — so always restart it last.
	@$(DC) restart ids >/dev/null 2>&1 || true
	@echo "enterprise is up. try: make test"

down:
	$(DC) down

# Also remove the nested Docker host and its image cache (Desktop only)
destroy: down
ifeq ($(ON_DESKTOP),1)
	docker rm -f $(LAB_HOST)
	docker volume rm enterprise-lab-images
endif

host:
ifeq ($(ON_DESKTOP),1)
	@docker start $(LAB_HOST) >/dev/null 2>&1 || \
	  docker run -d --name $(LAB_HOST) --privileged \
	    -v "$(CURDIR)":/lab \
	    -v enterprise-lab-images:/var/lib/docker \
	    docker:dind >/dev/null
	@printf 'waiting for nested docker'; \
	  until docker exec $(LAB_HOST) docker info >/dev/null 2>&1; \
	    do printf .; sleep 1; done; echo
endif

build: host
	@find . -name '._*' -delete 2>/dev/null || true
	$(DC) build

ps:
	$(DC) ps

logs:
	$(DC) logs -f

# Quick health check: latency from Perth to each office + cross-WAN HTTP
test:
	@echo "── Perth -> London (expect ~250ms) ──"
	$(DC) exec perth-ws1 ping -c 3 10.20.10.101
	@echo "── Perth -> LA (expect ~150ms) ──"
	$(DC) exec perth-ws1 ping -c 3 10.30.10.101
	@echo "── London -> intranet over WAN ──"
	$(DC) exec london-ws1 curl -s -o /dev/null -w "HTTP %{http_code} in %{time_total}s\n" http://intranet.corp.lab/

routes:
	$(DC) exec perth-router vtysh -c "show ip route"

neighbors:
	$(DC) exec perth-router vtysh -c "show ip ospf neighbor"

# Fail (and repair) the Perth<->London WAN link, two different ways:
# wan-cut is a clean interface-down (instant OSPF reroute via LA);
# wan-blackhole keeps the link up but drops every packet (silent failure —
# nothing moves until the OSPF dead-interval expires). wan-heal fixes both.
wan-cut:
	$(DC) exec perth-router sh -c 'ip link set $$(ip -o -4 addr show | awk "/172\.16\.1\./ {print \$$2; exit}" | cut -d@ -f1) down'

wan-blackhole:
	$(DC) exec perth-router sh -c 'tc qdisc change dev $$(ip -o -4 addr show | awk "/172\.16\.1\./ {print \$$2; exit}" | cut -d@ -f1) root netem delay 125ms loss 100%'

wan-heal:
	$(DC) exec perth-router sh -c 'i=$$(ip -o -4 addr show | awk "/172\.16\.1\./ {print \$$2; exit}" | cut -d@ -f1); ip link set $$i up; tc qdisc del dev $$i root 2>/dev/null; tc qdisc add dev $$i root netem delay 125ms'

# ── Lab 01: intrusion detection ───────────────────────────────────────
# The sensor watches every interface of the Perth router. Alerts land in
# logs/suricata/ on the host, so you can tail them from a normal terminal.
ids-alerts:
	@tail -n 40 logs/suricata/fast.log 2>/dev/null || echo "no alerts yet — try 'make attack'"

ids-watch:
	tail -f logs/suricata/fast.log

# Which rules fired, most frequent first
ids-summary:
	@grep -oE '\[1:[0-9]+:[0-9]+\] [^[]+' logs/suricata/fast.log 2>/dev/null \
	  | sed -E 's/\[1:([0-9]+):[0-9]+\] /\1  /' | sort | uniq -c | sort -rn \
	  || echo "no alerts yet"

# Clear the alert log. Truncating a file Suricata holds open leaves the
# writer at its old offset (you get a screenful of NULs), so the sensor is
# restarted alongside it.
ids-reset:
	@: > logs/suricata/fast.log
	@$(DC) restart ids >/dev/null
	@echo "alert log cleared and sensor restarted"

# Re-read config/ids/*.rules after you edit them.
#
# On Docker Desktop an edit on the host can take a few seconds to appear
# inside the container (the file crosses macOS -> the Desktop VM -> the
# nested Docker host). Restarting the sensor before the edit has landed
# silently reloads the OLD file, so this waits until the container sees the
# same byte count the host has, then reports what actually loaded.
ids-reload:
	@want=$$(wc -c < config/ids/local.rules); \
	 printf 'waiting for the sensor to see your edit'; \
	 for i in $$(seq 1 30); do \
	   got=$$($(DC) exec -T ids wc -c < /lab-rules/local.rules 2>/dev/null | tr -d ' \r'); \
	   [ "$$got" = "$$want" ] && break; printf '.'; sleep 1; \
	 done; echo
	@$(DC) restart ids >/dev/null
	@sleep 14
	@$(DC) exec ids sh -c 'grep -hE "rule files processed|Threshold config parsed" \
	   /var/log/suricata/suricata.log | tail -2' \
	 | sed 's/^.*Info: /  /'

# Run the scripted intrusion from the Perth workstation
attack:
	$(DC) exec perth-ws1 bash /attack-demo.sh

# Record traffic on one of the Perth router's subnets, into pcaps/ on the host.
#   make capture FILE=incident.pcap [NET=10.10.20] [SECS=60]
# NET picks the subnet to watch — 10.10.20 servers (default), 10.10.10 users,
# 172.16.1 the London WAN link. Note this captures a single Ethernet segment
# on purpose: tcpdump -i any produces Linux cooked-capture frames, which have
# no Ethernet header and therefore cannot be replayed with tcpreplay.
capture:
	@test -n "$(FILE)" || (echo "usage: make capture FILE=incident.pcap [NET=10.10.20] [SECS=60]" && exit 1)
	@echo "capturing $(or $(NET),10.10.20).0/24 for $(or $(SECS),60)s ..."
	-$(DC) exec perth-router sh -c 'i=$$(ip -o -4 addr show | awk "/$(subst .,\\.,$(or $(NET),10.10.20))\\./ {print \$$2; exit}" | cut -d@ -f1); timeout $(or $(SECS),60) tcpdump -ni $$i -w /pcaps/$(FILE) 2>&1 | tail -2'
	@echo "saved pcaps/$(FILE)"

# Replay a capture onto the Perth servers subnet, where the sensor sees it.
#   make replay PCAP=incident.pcap [LOOP=3] [MBPS=10]
#   SENSOR= overrides where frames are addressed (Lab 01 step 4 uses a
#   deliberately wrong address to show detection collapse without it).
replay:
	@test -n "$(PCAP)" || (echo "usage: make replay PCAP=<file in pcaps/> [LOOP=n] [MBPS=n] [SENSOR=ip]" && exit 1)
	$(DC) run --rm -e PCAP=$(PCAP) -e LOOP=$(or $(LOOP),1) -e MBPS=$(MBPS) \
	  -e SENSOR_IP=$(or $(SENSOR),10.10.30.254) replay

# ── Lab 02: edge firewall ─────────────────────────────────────────────
# Apply config/nftables/perth.nft to the Perth router. Loading is atomic:
# if the file has a syntax error, nftables rejects the whole thing and the
# previous ruleset stays in place.
fw-load:
	$(DC) exec perth-router nft -f /etc/nftables.lab.d/perth.nft
	@echo "policy loaded"

# Live ruleset with packet counters
fw-list:
	$(DC) exec perth-router nft -a list ruleset

# Back to wide open (does not touch the file)
fw-flush:
	$(DC) exec perth-router nft flush ruleset
	@echo "ruleset flushed — the router is wide open again"

# What each rule has matched. nftables `log` writes to the kernel ring
# buffer, which a container is not permitted to read (`dmesg` fails), so
# `counter` on a rule is how you observe drops in this lab.
fw-counters:
	@$(DC) exec perth-router nft list chain inet filter forward \
	  | grep -E 'counter|comment' | sed 's/^[[:space:]]*/  /'

# Does policy do what you think? Each line is a real connection attempt.
fw-test:
	@echo "── London -> intranet HTTP (should be allowed) ──"
	@$(DC) exec london-ws1 sh -c 'curl -s -m 5 -o /dev/null -w "  HTTP %{http_code}\n" http://10.10.20.80/ || echo "  BLOCKED"'
	@echo "── London -> HQ DNS (needed for corp.lab to resolve) ──"
	@$(DC) exec london-ws1 sh -c 'dig +short +time=3 +tries=1 @10.10.20.53 intranet.corp.lab || echo "  BLOCKED"'
	@echo "── London -> HQ DNS server, ping (nothing needs this) ──"
	@$(DC) exec london-ws1 sh -c 'ping -c1 -W3 10.10.20.53 >/dev/null 2>&1 && echo "  reachable" || echo "  BLOCKED"'
	@echo "── London workstation -> Perth workstation (lateral movement) ──"
	@$(DC) exec london-ws1 sh -c 'ping -c1 -W3 10.10.10.101 >/dev/null 2>&1 && echo "  reachable" || echo "  BLOCKED"'

# ── Lab 03: WAN troubleshooting ───────────────────────────────────────
# Inject a fault and diagnose it:  make fault N=3   ...   make fault-clear
# Don't read past this line if you want the exercise to be a fair test.
PL = $$(ip -o -4 addr show | awk "/172\.16\.1\./ {print \$$2; exit}" | cut -d@ -f1)

fault:
	@test -n "$(N)" || (echo "usage: make fault N=<1..7>   (then: make fault-clear)" && exit 1)
	@$(MAKE) --no-print-directory fault-$(N)
	@echo "fault $(N) injected. Diagnose it — see labs/03-wan-troubleshooting.md"

fault-1:
	@$(DC) exec perth-router sh -c 'tc qdisc replace dev $(PL) root netem delay 125ms loss 12%'

fault-2:
	@$(DC) exec perth-router sh -c 'tc qdisc replace dev $(PL) root netem delay 125ms 95ms distribution normal'

fault-3:
	@$(DC) exec london-router sh -c 'tc qdisc replace dev $(PL) root netem delay 125ms loss 30%'

# A path-MTU black hole: large packets toward London vanish and no ICMP
# comes back to explain it. (Done with nftables rather than by lowering the
# interface MTU -- OSPF checks MTU when forming adjacencies, so shrinking
# the interface would break routing instead of silently eating big packets.)
fault-4:
	@$(DC) exec perth-router sh -c 'nft add table inet lab_fault; \
	  nft add chain inet lab_fault hole "{ type filter hook forward priority -10; policy accept; }"; \
	  nft add rule inet lab_fault hole ip daddr 10.20.10.0/24 ip length 1201-65535 counter drop'

fault-5:
	@$(DC) stop london-dns >/dev/null

fault-6:
	@$(DC) exec perth-router sh -c 'tc qdisc replace dev $(PL) root netem delay 125ms rate 1mbit'

fault-7:
	@$(DC) exec perth-router vtysh -c "configure terminal" -c "ip route 10.20.10.0/24 172.16.2.2" >/dev/null

# `tc qdisc replace` merges options into an existing netem qdisc instead of
# replacing them, so faults would otherwise pile up. Delete, then re-add.
fault-clear:
	@$(DC) exec perth-router sh -c 'tc qdisc del dev $(PL) root 2>/dev/null; tc qdisc add dev $(PL) root netem delay 125ms; ip link set dev $(PL) mtu 1500' 2>/dev/null || true
	@$(DC) exec london-router sh -c 'tc qdisc del dev $(PL) root 2>/dev/null; tc qdisc add dev $(PL) root netem delay 125ms; ip link set dev $(PL) mtu 1500' 2>/dev/null || true
	@$(DC) exec perth-router sh -c 'nft delete table inet lab_fault' 2>/dev/null || true
	@$(DC) exec perth-router vtysh -c "configure terminal" -c "no ip route 10.20.10.0/24 172.16.2.2" >/dev/null 2>&1 || true
	@$(DC) start london-dns >/dev/null 2>&1 || true
	@echo "all faults cleared"

# Throughput between two offices — the quickest way to see a link is sick
iperf:
	@$(DC) exec -d london-ws1 iperf3 -s >/dev/null 2>&1 || true
	@sleep 1
	@$(DC) exec perth-ws1 iperf3 -c 10.20.10.101 -t 8 -i 2 || true

# ── Lab 04: reconstruct a network from a capture ──────────────────────
#   make rebuild PCAP=incident.pcap [OUT=rebuilt]
rebuild:
	@test -n "$(PCAP)" || (echo "usage: make rebuild PCAP=<file in pcaps/> [OUT=dir]" && exit 1)
	python3 scripts/pcap2compose.py pcaps/$(PCAP) -o $(or $(OUT),rebuilt)
	@echo "read $(or $(OUT),rebuilt)/REPORT.md before trusting the compose file"

# ── Follow-the-sun ────────────────────────────────────────────────────
# Where each office is in its working day. Time is compressed: one
# simulated hour per SIM_HOUR real seconds (default 60, so a day = 24 min).
clock:
	@SIM_HOUR=$(or $(SIM_HOUR),60) sh scripts/clock.sh

# Who is actually talking right now, by office
activity:
	@echo "packets seen per office subnet over 10s:"
	@$(DC) exec perth-router sh -c 'timeout 10 tcpdump -ni any -q 2>/dev/null | \
	  grep -oE "10\.(10|20|30|40)\.10\.[0-9]+" | cut -d. -f1-3 | sort | uniq -c | sort -rn' || true

# Profile a capture: who talked, at what local hour, and what fell outside
# the working day.  make baseline PCAP=day.pcap
baseline:
	@test -n "$(PCAP)" || (echo "usage: make baseline PCAP=<file in pcaps/>" && exit 1)
	@python3 scripts/baseline.py pcaps/$(PCAP) --sim-hour $(or $(SIM_HOUR),60)

# A large transfer out of an office that is closed. Entirely ordinary
# traffic -- no exploit, no malware, nothing a signature would match. The
# only thing wrong with it is the hour.  make anomaly SITE=london
anomaly:
	@echo "staging an out-of-hours bulk transfer from $(or $(SITE),london) ..."
	@$(DC) exec $(or $(SITE),london)-ws1 sh -c \
	  'for i in 1 2 3; do curl -s -o /dev/null http://intranet.corp.lab:8080/large.bin; done'
	@echo "done — now find it: make capture ... ; make baseline PCAP=..."

# Interactive shells on each office's workstation
perth:
	$(DC) exec -it perth-ws1 bash

london:
	$(DC) exec -it london-ws1 bash

la:
	$(DC) exec -it la-ws1 bash

pilbara:
	$(DC) exec -it pilbara-ws1 bash
