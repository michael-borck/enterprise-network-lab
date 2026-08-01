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

.PHONY: up down destroy host build ps logs test routes neighbors perth london la wan-cut wan-blackhole wan-heal

up: host
	@find . -name '._*' -delete 2>/dev/null || true
	$(DC) up -d --build

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

# Interactive shells on each office's workstation
perth:
	$(DC) exec -it perth-ws1 bash

london:
	$(DC) exec -it london-ws1 bash

la:
	$(DC) exec -it la-ws1 bash
