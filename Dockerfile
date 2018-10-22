FROM alpine:3.8

RUN apk add --no-cache bash iptables iproute2

COPY run.sh /tmp
COPY any_proxy /tmp

WORKDIR /tmp

ENTRYPOINT [ "/tmp/run.sh" ]
