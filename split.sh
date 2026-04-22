#!/bin/bash
set -eu
cd "$(dirname "$0")"

# ===========================================================================
#  Packxy — split-tunneling manager for macOS
#
#  Two modes (selected automatically):
#    1. tun2socks  — true network-level routing (ALL protocols: SSH, Git, …)
#                    Requires: tun2socks installed + VPN_ROUTES configured
#    2. PAC proxy  — browser-only fallback (HTTP / HTTPS)
# ===========================================================================

# --- Configuration ---
PAC_FILE="${PAC_FILE:-$HOME/Proxy/packsolutions.pac}"
PAC_URL="file://${PAC_FILE}"
STATE_DIR="/tmp/forti-socks"
VPN_ERROR_PATTERNS='Could not authenticate to gateway|Authentication failed|Invalid OTP|OTP required|Connection failed|check the password, client certificate|Invalid password|Certificate error|Gateway unreachable|VPN process terminated unexpectedly|VPN did not create ppp0'

# --- UI helpers ---
step_ok()   { gum style --foreground 10 "  ✔  $1"; }
step_fail() { gum style --foreground 9  "  ✖  $1"; }
step_warn() { gum style --foreground 11 "  !  $1"; }
step_info() { gum style --foreground 8  "     $1"; }

banner() {
  local color="$1" title="$2" subtitle="${3:-}"
  if [ -n "$subtitle" ]; then
    gum style \
      --foreground "$color" --border-foreground "$color" --border double \
      --align center --width 56 --margin "1 2" --padding "1 2" \
      "$title" "" "$subtitle"
  else
    gum style \
      --foreground "$color" --border-foreground "$color" --border double \
      --align center --width 56 --margin "1 2" --padding "1 2" \
      "$title"
  fi
}

summary_line() {
  local label="$1" value="$2"
  printf "  %-10s %s\n" "$label" "$value"
}

# --- Load .env defaults ---
load_env() {
  if [ -f .env ]; then
    set -a
    # shellcheck disable=SC1091
    source .env
    set +a
  fi
}

# ========================  macOS network helpers  ==========================

get_active_service() {
  local route_iface
  route_iface=$(route -n get default 2>/dev/null | awk '/interface:/ {print $2}')
  [ -z "$route_iface" ] && return 1
  networksetup -listallhardwareports | awk -v dev="$route_iface" '
    /^Hardware Port:/ { port = substr($0, index($0,":")+2) }
    /^Device:/ && $2 == dev { print port; exit }
  '
}

# ========================  PAC proxy (fallback)  ===========================

enable_pac_proxy() {
  local service
  service=$(get_active_service) || return 1
  [ ! -f "$PAC_FILE" ] && return 1
  networksetup -setautoproxyurl "$service" "$PAC_URL"
  networksetup -setautoproxystate "$service" on
}

disable_pac_proxy() {
  local service
  service=$(get_active_service) || return 0
  networksetup -setautoproxystate "$service" off
}

# ========================  tun2socks routing  ==============================

find_tun2socks() {
  command -v tun2socks 2>/dev/null && return
  for candidate in "$HOME/go/bin/tun2socks" /usr/local/bin/tun2socks; do
    if [ -x "$candidate" ]; then
      echo "$candidate"
      return
    fi
  done
  return 1
}

has_tun2socks() { find_tun2socks >/dev/null 2>&1; }

# Split into discrete steps so the caller can show progress per step.

tunnel_create_interface() {
  local before after tun2socks_bin
  mkdir -p "$STATE_DIR"

  before=$(ifconfig -l)

  tun2socks_bin=$(find_tun2socks)
  sudo "$tun2socks_bin" -device utun -proxy socks5://127.0.0.1:1080 >/dev/null 2>&1 &
  echo $! > "$STATE_DIR/tun2socks.pid"

  sleep 2

  after=$(ifconfig -l)
  TUNNEL_DEV=$(comm -13 <(echo "$before" | tr ' ' '\n' | sort) \
                        <(echo "$after"  | tr ' ' '\n' | sort) \
               | grep '^utun' | head -1)

  if [ -z "$TUNNEL_DEV" ]; then
    stop_tunnel 2>/dev/null || true
    return 1
  fi

  echo "$TUNNEL_DEV" > "$STATE_DIR/tun_dev"
  sudo ifconfig "$TUNNEL_DEV" 198.18.0.1 198.18.0.1 up 2>/dev/null
}

tunnel_add_routes() {
  TUNNEL_ROUTES_ADDED=""
  local ifs_save="$IFS"
  IFS=','
  for route in ${VPN_ROUTES}; do
    IFS="$ifs_save"
    route=$(echo "$route" | xargs)
    [ -z "$route" ] && continue
    sudo route -q add -net "$route" -interface "$TUNNEL_DEV" >/dev/null 2>&1 || true
    echo "$route" >> "$STATE_DIR/routes"
    TUNNEL_ROUTES_ADDED="${TUNNEL_ROUTES_ADDED:+$TUNNEL_ROUTES_ADDED, }$route"
  done
  IFS="$ifs_save"
}

tunnel_configure_dns() {
  TUNNEL_DOMAINS_ADDED=""
  [ -z "${VPN_DNS:-}" ] || [ -z "${VPN_DOMAINS:-}" ] && return 0

  sudo mkdir -p /etc/resolver 2>/dev/null
  local ifs_save="$IFS"
  IFS=','
  for domain in ${VPN_DOMAINS}; do
    IFS="$ifs_save"
    domain=$(echo "$domain" | xargs)
    [ -z "$domain" ] && continue
    if echo "nameserver ${VPN_DNS}" | sudo tee "/etc/resolver/${domain}" >/dev/null 2>&1; then
      echo "$domain" >> "$STATE_DIR/domains"
      TUNNEL_DOMAINS_ADDED="${TUNNEL_DOMAINS_ADDED:+$TUNNEL_DOMAINS_ADDED, }$domain"
    fi
  done
  IFS="$ifs_save"
}

stop_tunnel() {
  if [ -f "$STATE_DIR/tun2socks.pid" ]; then
    sudo kill "$(cat "$STATE_DIR/tun2socks.pid")" 2>/dev/null || true
    rm -f "$STATE_DIR/tun2socks.pid"
  fi
  if [ -f "$STATE_DIR/domains" ]; then
    while IFS= read -r domain; do
      sudo rm -f "/etc/resolver/${domain}"
    done < "$STATE_DIR/domains"
  fi
  rm -rf "$STATE_DIR"
}

# Globals set by tunnel steps
TUNNEL_DEV=""
TUNNEL_ROUTES_ADDED=""
TUNNEL_DOMAINS_ADDED=""

extract_vpn_error() {
  local container="$1" logs error
  logs=$(docker logs --tail 50 "$container" 2>&1 || true)
  error=$(echo "$logs" | grep -iE "$VPN_ERROR_PATTERNS" | tail -n 3 || true)
  [ -z "$error" ] && error=$(echo "$logs" | grep -iE "ERROR:|error:|fatal" | tail -n 3 || true)
  [ -z "$error" ] && error="Connection timed out or failed without a specific error."
  echo "$error"
}

# ========================  Commands  =======================================

usage() {
  echo "Usage: ./split.sh start | ./split.sh stop"
  echo ""
  echo "  start   Connect to VPN and enable split tunneling"
  echo "  stop    Disconnect VPN and remove split tunneling"
  exit 1
}

cmd_stop() {
  echo ""
  stop_tunnel 2>/dev/null || true
  step_ok "Tunnel removed"

  disable_pac_proxy 2>/dev/null || true
  step_ok "Proxy disabled"

  gum spin --spinner dot --title "  Stopping container..." -- \
    bash -c "docker compose down >/dev/null 2>&1"
  step_ok "Container stopped"

  echo ""
  banner 10 "Disconnected"
  exit 0
}

cmd_start() {
  load_env

  # --- Check prerequisites ---
  if ! command -v gum >/dev/null 2>&1; then
    echo "Error: 'gum' is not installed (brew install gum)." >&2
    exit 1
  fi

  # Pre-authenticate sudo for tun2socks/DNS setup
  if has_tun2socks && [ -n "${VPN_ROUTES:-}" ]; then
    step_info "sudo is needed for the tunnel interface and DNS entries."
    sudo -v || { echo "sudo authentication failed." >&2; exit 1; }
    echo ""
  fi

  banner 212 "Packxy"
  echo ""

  # --- Credential prompts (defaults from .env) ---
  FORTI_HOST=$(gum input --header "  VPN Hostname" --placeholder "vpn.company.com" --value "${FORTI_HOST:-}")
  export FORTI_HOST

  FORTI_PORT=$(gum input --header "  VPN Port" --placeholder "443" --value "${FORTI_PORT:-443}")
  export FORTI_PORT

  FORTI_USER=$(gum input --header "  Username" --placeholder "john.doe" --value "${FORTI_USER:-}")
  export FORTI_USER

  FORTI_PASS=$(gum input --password --header "  Password" --placeholder "••••••••" --value "${FORTI_PASS:-}")
  export FORTI_PASS

  while true; do
    FORTI_OTP=$(gum input --header "  2FA Code" --placeholder "123456" --value "${FORTI_OTP:-}")
    [[ "$FORTI_OTP" =~ ^[0-9]{6}$ ]] && break
    gum style --foreground 9 "  Must be exactly 6 digits."
  done
  export FORTI_OTP

  if [ -z "${FORTI_TRUSTED_CERT:-}" ]; then
    FORTI_TRUSTED_CERT=$(gum input --header "  Trusted Certificate (optional)" --placeholder "sha256 fingerprint...")
  fi
  export FORTI_TRUSTED_CERT

  if [ -n "${FORTI_REALM:-}" ]; then
    FORTI_REALM=$(gum input --header "  Realm" --value "${FORTI_REALM}")
  fi
  export FORTI_REALM

  echo ""

  # ---- Step 1: Start the container ----
  if gum spin --spinner dot --title "  Starting container..." -- \
       bash -c "docker compose up -d >/dev/null 2>&1"; then
    step_ok "Container started"
  else
    step_fail "Container failed to start"
    step_info "Run 'docker compose up -d' manually to see the error."
    exit 1
  fi

  CONTAINER_NAME=$(docker compose ps --format '{{.Name}}' forti-socks 2>/dev/null || echo "forti-socks")

  # ---- Step 2: Wait for VPN connection ----
  if gum spin --spinner dot --title "  Connecting to VPN..." -- \
       bash -c "
    ERROR_PAT='$VPN_ERROR_PATTERNS'
    for i in \$(seq 1 40); do
      STATUS=\$(docker inspect -f '{{.State.Status}}' '$CONTAINER_NAME' 2>/dev/null || echo 'unknown')
      [ \"\$STATUS\" = 'exited' ] && exit 1
      docker exec '$CONTAINER_NAME' ip link show ppp0 >/dev/null 2>&1 && exit 0
      docker logs '$CONTAINER_NAME' 2>&1 | grep -qiE \"\$ERROR_PAT\" && exit 1
      sleep 1
    done
    exit 1
  "; then
    step_ok "VPN connected"
  else
    step_fail "VPN connection failed"
    echo ""
    extract_vpn_error "$CONTAINER_NAME" | while IFS= read -r line; do
      step_info "$line"
    done
    echo ""
    step_info "Full logs: docker compose logs"
    echo ""
    gum confirm --default=true --affirmative="OK" --negative="" "Press Enter to exit..." || true
    exit 1
  fi

  # ---- Step 3: Enable split tunneling ----

  if has_tun2socks && [ -n "${VPN_ROUTES:-}" ]; then
    # ---- tun2socks mode (all protocols) ----
    if tunnel_create_interface; then
      step_ok "Tunnel interface ${TUNNEL_DEV}"
    else
      step_fail "Tunnel setup failed"
      show_fallback
      exit 0
    fi

    tunnel_add_routes
    [ -n "$TUNNEL_ROUTES_ADDED" ] && step_ok "Routes  ${TUNNEL_ROUTES_ADDED}"

    tunnel_configure_dns
    [ -n "$TUNNEL_DOMAINS_ADDED" ] && step_ok "DNS     ${TUNNEL_DOMAINS_ADDED}"

    echo ""
    banner 10 "Connected" "All traffic to VPN networks is routed"
    echo ""
    summary_line "Proxy"  "127.0.0.1:1080"
    summary_line "Routes" "${TUNNEL_ROUTES_ADDED}"
    [ -n "$TUNNEL_DOMAINS_ADDED" ] && summary_line "DNS" "${TUNNEL_DOMAINS_ADDED}"
    echo ""
    gum style --foreground 8 "  Stop with:  ./split.sh stop"
    gum style --foreground 8 "  Logs:       docker compose logs -f"

  else
    # ---- PAC / manual SOCKS fallback ----
    show_fallback
  fi

  exit 0
}

# Shown when tun2socks is not available or failed
show_fallback() {
  local pac_ok=false
  enable_pac_proxy && pac_ok=true || true

  [ "$pac_ok" = true ] && step_ok "Browser proxy enabled (PAC)"

  echo ""
  if [ "$pac_ok" = true ]; then
    banner 10 "Connected" "Browser traffic routed via PAC proxy"
  else
    banner 11 "Connected" "SOCKS proxy available on :1080"
  fi

  echo ""
  summary_line "Proxy" "127.0.0.1:1080"
  echo ""
  gum style --foreground 7 "  For CLI tools, set the proxy manually:"
  gum style --foreground 8 "  ALL_PROXY=socks5h://127.0.0.1:1080 ssh user@host"
  gum style --foreground 8 "  ALL_PROXY=socks5h://127.0.0.1:1080 git clone ..."

  if ! has_tun2socks || [ -z "${VPN_ROUTES:-}" ]; then
    echo ""
    gum style --foreground 11 --bold "  Want full split tunneling?"
    if ! has_tun2socks; then
      gum style --foreground 8 "  Install:  go install github.com/xjasonlyu/tun2socks/v2@latest"
    fi
    if [ -z "${VPN_ROUTES:-}" ]; then
      gum style --foreground 8 "  Configure VPN_ROUTES, VPN_DNS, VPN_DOMAINS in .env"
    fi
  fi

  echo ""
  gum style --foreground 8 "  Stop with:  ./split.sh stop"
  gum style --foreground 8 "  Logs:       docker compose logs -f"
}

# --- Dispatch ---
case "${1:-}" in
  start) cmd_start ;;
  stop)  cmd_stop ;;
  *)     usage ;;
esac
