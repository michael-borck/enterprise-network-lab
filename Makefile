# On native Linux the lab runs directly on the host's Docker. On Docker
# Desktop (macOS/Windows) container networking goes through a userspace
# switch that only delivers frames to IPs registered on each network —
# transit routing through the FRR containers is impossible there. So on
# Desktop the whole lab runs nested inside a privileged docker:dind
# container ($(LAB_HOST)), where networks are real kernel bridges.
LAB_HOST    = enterprise-lab-vm
ON_DESKTOP := $(shell docker info -f '{{.OperatingSystem}}' 2>/dev/null | grep -c 'Docker Desktop')

ifeq ($(ON_DESKTOP),1)
DC = docker exec -w /lab $(LAB_HOST) docker compose
else
DC = docker compose
endif

.PHONY: up down destroy host build ps logs test routes neighbors perth london la \
        wan-cut wan-blackhole wan-heal attack capture replay \
        ids-alerts ids-watch ids-summary ids-reload \
        fw-load fw-list fw-flush fw-counters fw-test

up: host
	@find . -name '._*' -delete 2>/dev/null || true
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
	$(DC) exec perth-router sh -c 'i=$$(ip -o -4 addr show | awk "/172\.16\.1\./ {print \$$2; exit}" | cut -d@ -f1); ip link set $$i up; tc qdisc replace dev $$i root netem delay 125ms'

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

# Re-read config/ids/local.rules after you edit it
ids-reload:
	$(DC) restart ids
	@echo "sensor reloaded — rules now:"
	@sleep 12; $(DC) exec ids sh -c 'grep "rule files processed" /var/log/suricata/suricata.log | tail -1'

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

# Interactive shells on each office's workstation
perth:
	$(DC) exec -it perth-ws1 bash

london:
	$(DC) exec -it london-ws1 bash

la:
	$(DC) exec -it la-ws1 bash
