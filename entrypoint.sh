#!/bin/sh
set -eu

: "${FORTI_HOST:?missing FORTI_HOST}"
: "${FORTI_USER:?missing FORTI_USER}"
: "${FORTI_PASS:?missing FORTI_PASS}"

CONFIG=/etc/openfortivpn/config

# --- Build openfortivpn config ---
# set-routes = 1 : import VPN routes so danted can reach internal hosts through ppp0
# set-dns = 1    : use the DNS servers pushed by the FortiGate VPN
#                  (required so danted can resolve internal hostnames for SOCKS5 clients)
# pppd-use-peerdns = 1 : also accept DNS from PPP negotiation
cat > "$CONFIG" <<'STATIC'
set-routes = 1
set-dns = 1
pppd-use-peerdns = 1
STATIC

printf 'host = %s\n' "${FORTI_HOST}" >> "$CONFIG"
printf 'port = %s\n' "${FORTI_PORT:-443}" >> "$CONFIG"
printf 'username = %s\n' "${FORTI_USER}" >> "$CONFIG"
printf 'password = %s\n' "${FORTI_PASS}" >> "$CONFIG"

if [ -n "${FORTI_TRUSTED_CERT:-}" ]; then
    printf 'trusted-cert = %s\n' "${FORTI_TRUSTED_CERT}" >> "$CONFIG"
fi

if [ -n "${FORTI_REALM:-}" ]; then
    printf 'realm = %s\n' "${FORTI_REALM}" >> "$CONFIG"
fi

if [ -n "${FORTI_OTP:-}" ]; then
    printf 'otp = %s\n' "${FORTI_OTP}" >> "$CONFIG"
fi

if [ -n "${FORTI_OTP_PROMPT:-}" ]; then
    printf 'otp-prompt = %s\n' "${FORTI_OTP_PROMPT}" >> "$CONFIG"
fi

EXTRA_ARGS=""
if [ "${FORTI_NO_FTM_PUSH:-}" = "1" ]; then
    EXTRA_ARGS="--no-ftm-push"
fi

# --- Save original DNS so we can merge later ---
cp /etc/resolv.conf /etc/resolv.conf.orig

# --- Start openfortivpn in background ---
openfortivpn -c "$CONFIG" $EXTRA_ARGS &
VPN_PID=$!

DANTE_PID=""

cleanup() {
    kill "${VPN_PID}" 2>/dev/null || true
    [ -n "${DANTE_PID}" ] && kill "${DANTE_PID}" 2>/dev/null || true
    wait 2>/dev/null || true
}
trap cleanup INT TERM EXIT

# --- Wait for the PPP tunnel to get an IP address ---
PPP0_IP=""
for i in $(seq 1 60); do
    PPP0_IP=$(ip -4 addr show ppp0 2>/dev/null | awk '/inet / {split($2, a, "/"); print a[1]}')
    if [ -n "${PPP0_IP}" ]; then
        break
    fi
    if ! kill -0 "${VPN_PID}" 2>/dev/null; then
        echo "VPN process terminated unexpectedly." >&2
        exit 1
    fi
    sleep 1
done

if [ -z "${PPP0_IP}" ]; then
    echo "VPN did not create ppp0 or no IP assigned" >&2
    wait "${VPN_PID}" || true
    exit 1
fi

# --- Merge DNS: keep VPN nameservers first, append Docker DNS as fallback ---
# openfortivpn (set-dns=1) overwrites resolv.conf with VPN DNS.
# Append the original Docker nameservers so external names still resolve.
if [ -f /etc/resolv.conf.orig ]; then
    grep '^nameserver' /etc/resolv.conf.orig | while IFS= read -r line; do
        if ! grep -qF "$line" /etc/resolv.conf 2>/dev/null; then
            echo "$line" >> /etc/resolv.conf
        fi
    done
fi

# --- Configure danted external interface ---
sed -i "s/^external: ppp0$/external: ${PPP0_IP}/" /etc/danted.conf

# --- Start danted in background ---
danted -f /etc/danted.conf &
DANTE_PID=$!

echo "SOCKS proxy running on port 1080 (VPN via ${PPP0_IP})"

# --- Monitor both processes: exit if either dies ---
# tini (PID 1) forwards signals to us; the trap above cleans up both children.
while true; do
    if ! kill -0 "${VPN_PID}" 2>/dev/null; then
        echo "VPN process died, shutting down." >&2
        exit 1
    fi
    if ! kill -0 "${DANTE_PID}" 2>/dev/null; then
        echo "Dante process died, shutting down." >&2
        exit 1
    fi
    sleep 5
done
