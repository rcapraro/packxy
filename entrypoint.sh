#!/bin/sh
set -eu

: "${FORTI_HOST:?missing FORTI_HOST}"
: "${FORTI_USER:?missing FORTI_USER}"
: "${FORTI_PASS:?missing FORTI_PASS}"

CONFIG=/etc/openfortivpn/config
MAX_RECONNECTS=5
RECONNECT_DELAY=30

# --- Build openfortivpn config ---
# set-routes = 1 : import VPN routes so danted can reach internal hosts through ppp0
# set-dns = 1    : use the DNS servers pushed by the FortiGate VPN
#                  (required so danted can resolve internal hostnames for SOCKS5 clients)
# pppd-use-peerdns = 1 : also accept DNS from PPP negotiation
build_config() {
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
}

EXTRA_ARGS=""
if [ "${FORTI_NO_FTM_PUSH:-}" = "1" ]; then
    EXTRA_ARGS="--no-ftm-push"
fi

# --- Save original DNS so we can merge later ---
cp /etc/resolv.conf /etc/resolv.conf.orig

# --- Start openfortivpn and wait for ppp0 ---
# Returns 0 on success, 1 on failure.
# Sets VPN_PID and PPP0_IP on success.
start_vpn() {
    build_config

    openfortivpn -c "$CONFIG" $EXTRA_ARGS &
    VPN_PID=$!

    PPP0_IP=""
    for i in $(seq 1 60); do
        PPP0_IP=$(ip -4 addr show ppp0 2>/dev/null | awk '/inet / {split($2, a, "/"); print a[1]}')
        if [ -n "${PPP0_IP}" ]; then
            return 0
        fi
        if ! kill -0 "${VPN_PID}" 2>/dev/null; then
            echo "VPN process terminated unexpectedly." >&2
            return 1
        fi
        sleep 1
    done

    echo "VPN did not create ppp0 or no IP assigned." >&2
    kill "${VPN_PID}" 2>/dev/null || true
    wait "${VPN_PID}" 2>/dev/null || true
    return 1
}

# --- Merge DNS: keep VPN nameservers first, append Docker DNS as fallback ---
merge_dns() {
    if [ -f /etc/resolv.conf.orig ]; then
        grep '^nameserver' /etc/resolv.conf.orig | while IFS= read -r line; do
            if ! grep -qF "$line" /etc/resolv.conf 2>/dev/null; then
                echo "$line" >> /etc/resolv.conf
            fi
        done
    fi
}

# --- Configure and start danted ---
# Updates the external interface IP and (re)starts danted.
# Sets DANTE_PID on success.
start_dante() {
    # Reset danted.conf to template (ppp0) then substitute the actual IP
    sed -i "s/^external: .*$/external: ${PPP0_IP}/" /etc/danted.conf

    danted -f /etc/danted.conf &
    DANTE_PID=$!
}

stop_dante() {
    if [ -n "${DANTE_PID:-}" ]; then
        kill "${DANTE_PID}" 2>/dev/null || true
        wait "${DANTE_PID}" 2>/dev/null || true
        DANTE_PID=""
    fi
}

# --- Cleanup on exit ---
VPN_PID=""
DANTE_PID=""

cleanup() {
    [ -n "${VPN_PID}" ]   && kill "${VPN_PID}"   2>/dev/null || true
    [ -n "${DANTE_PID}" ] && kill "${DANTE_PID}" 2>/dev/null || true
    wait 2>/dev/null || true
}
trap cleanup INT TERM EXIT

# =====================================================================
#  Initial connection — fail fast on auth errors (no retries)
# =====================================================================

if ! start_vpn; then
    echo "Initial VPN connection failed — exiting (no retry to avoid lockout)." >&2
    exit 1
fi

merge_dns
start_dante
echo "SOCKS proxy running on port 1080 (VPN via ${PPP0_IP})"

# =====================================================================
#  Monitor loop — reconnect on drops, exit on persistent failure
# =====================================================================

reconnect_count=0

while true; do
    # Check danted
    if ! kill -0 "${DANTE_PID}" 2>/dev/null; then
        echo "Dante process died, restarting..." >&2
        start_dante
    fi

    # Check openfortivpn
    if ! kill -0 "${VPN_PID}" 2>/dev/null; then
        reconnect_count=$((reconnect_count + 1))

        if [ "${reconnect_count}" -gt "${MAX_RECONNECTS}" ]; then
            echo "VPN dropped ${MAX_RECONNECTS} times — giving up." >&2
            exit 1
        fi

        echo "VPN connection lost (attempt ${reconnect_count}/${MAX_RECONNECTS}), reconnecting in ${RECONNECT_DELAY}s..." >&2
        stop_dante
        sleep "${RECONNECT_DELAY}"

        if start_vpn; then
            echo "VPN reconnected (via ${PPP0_IP})" >&2
            merge_dns
            start_dante
            echo "SOCKS proxy running on port 1080 (VPN via ${PPP0_IP})"
            reconnect_count=0
        else
            echo "Reconnection failed." >&2
        fi
    fi

    sleep 5
done
