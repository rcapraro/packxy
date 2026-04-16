#!/bin/sh
set -eu

: "${FORTI_HOST:?missing FORTI_HOST}"
: "${FORTI_USER:?missing FORTI_USER}"
: "${FORTI_PASS:?missing FORTI_PASS}"

cat > /etc/openfortivpn/config <<EOF
host = ${FORTI_HOST}
port = ${FORTI_PORT:-443}
username = ${FORTI_USER}
password = ${FORTI_PASS}
set-routes = 0
set-dns = 0
pppd-use-peerdns = 0
EOF

if [ -n "${FORTI_TRUSTED_CERT:-}" ]; then
    echo "trusted-cert = ${FORTI_TRUSTED_CERT}" >> /etc/openfortivpn/config
fi

if [ -n "${FORTI_REALM:-}" ]; then
    echo "realm = ${FORTI_REALM}" >> /etc/openfortivpn/config
fi

if [ -n "${FORTI_OTP:-}" ]; then
    echo "otp = ${FORTI_OTP}" >> /etc/openfortivpn/config
fi

openfortivpn -c /etc/openfortivpn/config &
VPN_PID=$!

cleanup() {
    kill "${VPN_PID}" 2>/dev/null || true
}
trap cleanup INT TERM EXIT

for i in $(seq 1 30); do
    if ip link show ppp0 >/dev/null 2>&1; then
        break
    fi
    sleep 1
done

if ! ip link show ppp0 >/dev/null 2>&1; then
    echo "VPN did not create ppp0" >&2
    wait "${VPN_PID}" || true
    exit 1
fi

exec sockd -f /etc/danted.conf
