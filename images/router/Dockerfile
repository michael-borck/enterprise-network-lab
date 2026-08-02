FROM quay.io/frrouting/frr:10.4.4

RUN apk add --no-cache iproute2 tcpdump nftables

COPY init-router.sh /init-router.sh

ENTRYPOINT ["/sbin/tini", "--"]
CMD ["/bin/sh", "/init-router.sh"]
