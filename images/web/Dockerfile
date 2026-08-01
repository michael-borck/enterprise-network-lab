FROM nginx:1.27-alpine

RUN apk add --no-cache iproute2 tcpdump

COPY init-web.sh /init-web.sh

ENTRYPOINT ["/bin/sh", "/init-web.sh"]
