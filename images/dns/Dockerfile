FROM alpine:3.21

RUN apk add --no-cache dnsmasq iproute2 tcpdump bind-tools

COPY init-dns.sh /init-dns.sh

CMD ["/bin/sh", "/init-dns.sh"]
