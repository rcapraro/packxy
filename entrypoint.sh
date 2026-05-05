#!/bin/sh
set -eu

: "${FORTI_HOST:?missing FORTI_HOST}"
: "${FORTI_USER:?missing FORTI_USER}"
: "${FORTI_PASS:?missing FORTI_PASS}"

CONFIG=/etc/openfortivpn/config
VPN_LOG=/tmp/openfortivpn.log
MAX_RECONNECTS=5
RECONNECT_DELAY=30

# Errors that mean retrying with the same credentials cannot succeed
# (e.g. expired OTP after the laptop slept). When seen, exit fast instead
# of burning reconnect attempts and risking a FortiGate account lockout.
AUTH_ERROR_RE='Could not authenticate to gateway|check the password, client certificate|Authentication failed|Invalid (password|OTP)|OTP required'

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

# Keep the tunnel alive against NAT/firewall idle timeouts and trigger a
# fast pppd exit when the link goes silent, so the monitor loop can reconnect.
write_ppp_options() {
    mkdir -p /etc/ppp
    cat > /etc/ppp/options <<EOF
lcp-echo-interval ${PPP_LCP_ECHO_INTERVAL:-30}
lcp-echo-failure ${PPP_LCP_ECHO_FAILURE:-4}
EOF
}

write_ppp_options

# --- Save original DNS so we can merge later ---
cp /etc/resolv.conf /etc/resolv.conf.orig

# --- Start openfortivpn and wait for ppp0 ---
# Returns 0 on success, 1 on failure.
# Sets VPN_PID and PPP0_IP on success.
start_vpn() {
    build_config

    : > "$VPN_LOG"
    openfortivpn -c "$CONFIG" $EXTRA_ARGS >> "$VPN_LOG" 2>&1 &
    VPN_PID=$!

    # Mirror openfortivpn output to stdout so it shows up in `docker logs`,
    # while the file copy stays available for grep-based error detection.
    tail -n +1 -f "$VPN_LOG" &
    TAIL_PID=$!

    # Wait for ppp0 to get an IP address
    PPP0_IP=""
    for i in $(seq 1 60); do
        PPP0_IP=$(ip -4 addr show ppp0 2>/dev/null | awk '/inet / {split($2, a, "/"); print a[1]}')
        if [ -n "${PPP0_IP}" ]; then
            break
        fi
        if ! kill -0 "${VPN_PID}" 2>/dev/null; then
            echo "VPN process terminated unexpectedly." >&2
            wait "${VPN_PID}" 2>/dev/null || true
            sleep 1
            stop_tail
            return 1
        fi
        sleep 1
    done

    if [ -z "${PPP0_IP}" ]; then
        echo "VPN did not create ppp0 or no IP assigned." >&2
        kill "${VPN_PID}" 2>/dev/null || true
        wait "${VPN_PID}" 2>/dev/null || true
        stop_tail
        return 1
    fi

    # Wait for openfortivpn to finish setting up routes and DNS
    for i in $(seq 1 15); do
        ip route show dev ppp0 2>/dev/null | grep -q . && break
        sleep 1
    done

    ip link set dev ppp0 mtu 1300 2>/dev/null || true
    return 0
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

stop_tail() {
    if [ -n "${TAIL_PID:-}" ]; then
        kill "${TAIL_PID}" 2>/dev/null || true
        wait "${TAIL_PID}" 2>/dev/null || true
        TAIL_PID=""
    fi
}

# Returns 0 if the last openfortivpn run failed with an auth-class error.
vpn_auth_failed() {
    grep -Eq "${AUTH_ERROR_RE}" "$VPN_LOG" 2>/dev/null
}

# --- Cleanup on exit ---
VPN_PID=""
DANTE_PID=""
TAIL_PID=""

cleanup() {
    [ -n "${VPN_PID}" ]   && kill "${VPN_PID}"   2>/dev/null || true
    [ -n "${DANTE_PID}" ] && kill "${DANTE_PID}" 2>/dev/null || true
    [ -n "${TAIL_PID}" ]  && kill "${TAIL_PID}"  2>/dev/null || true
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
        # Wait briefly for the tail to flush openfortivpn's last lines.
        wait "${VPN_PID}" 2>/dev/null || true
        sleep 1
        stop_tail

        # Auth errors (notably: expired OTP after suspend) cannot be fixed
        # by retrying the same credentials — exit fast for a clean restart.
        if vpn_auth_failed; then
            echo "VPN authentication failed — credentials/OTP no longer valid." >&2
            echo "Exiting without retry to avoid lockout. Restart packxy for a fresh OTP." >&2
            exit 2
        fi

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
            if vpn_auth_failed; then
                echo "VPN authentication failed — credentials/OTP no longer valid." >&2
                echo "Exiting without retry to avoid lockout. Restart packxy for a fresh OTP." >&2
                exit 2
            fi
        fi
    fi

    sleep 5
done
