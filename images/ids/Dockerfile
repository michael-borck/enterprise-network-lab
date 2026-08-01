FROM jasonish/suricata:7.0

USER root
RUN dnf install -y iproute ethtool >/dev/null 2>&1 \
 || (apt-get update -qq && apt-get install -y -qq iproute2 ethtool && rm -rf /var/lib/apt/lists/*)

# The lab networks have no internet access, so the Emerging Threats Open
# ruleset is downloaded at build time and baked into the image. Students
# get a working sensor offline, and the rules stay pinned for the class.
RUN suricata-update update-sources && suricata-update --no-test --no-reload

# The lab's own rules are bind-mounted from config/ids/local.rules and wired
# into the config by init-ids.sh at startup, so students edit rules on the
# host and reload with `make ids-reload` — no rebuild needed.
COPY init-ids.sh /init-ids.sh

ENTRYPOINT ["/bin/bash", "/init-ids.sh"]
