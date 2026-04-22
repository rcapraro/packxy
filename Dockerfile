FROM debian:bookworm-slim

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
    bash \
    iproute2 \
    openfortivpn \
    ppp \
    dante-server \
    tini \
    ca-certificates \
    procps \
    && rm -rf /var/lib/apt/lists/*

COPY entrypoint.sh /entrypoint.sh
COPY danted.conf /etc/danted.conf

RUN chmod +x /entrypoint.sh

HEALTHCHECK --interval=10s --timeout=5s --retries=3 \
  CMD ip link show ppp0 >/dev/null 2>&1 && pgrep danted >/dev/null

ENTRYPOINT ["/usr/bin/tini", "--", "/entrypoint.sh"]
