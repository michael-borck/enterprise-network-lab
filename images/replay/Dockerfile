FROM alpine:3.21

# tcpreplay ships tcpreplay, tcprewrite and tcpprep together.
RUN apk add --no-cache tcpreplay tcpdump iproute2 ethtool

COPY replay.sh /replay.sh

ENTRYPOINT ["/bin/sh", "/replay.sh"]
