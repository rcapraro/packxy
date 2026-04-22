#!/bin/bash
set -eu
cd "$(dirname "$0")"

# ===========================================================================
#  Forti SOCKS — split-tunneling manager for macOS
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

# Get the active network service name (e.g. "Wi-Fi", "Ethernet")
get_active_service() {
  local route_iface
  route_iface=$(route -n get default 2>/dev/null | awk '/interface:/ {print $2}')
  if [ -z "$route_iface" ]; then
    return 1
  fi
  networksetup -listallhardwareports | awk -v dev="$route_iface" '
    /^Hardware Port:/ { port = substr($0, index($0,":")+2) }
    /^Device:/ && $2 == dev { print port; exit }
  '
}

# ========================  PAC proxy (fallback)  ===========================

enable_pac_proxy() {
  local service
  service=$(get_active_service) || return 1
  if [ ! -f "$PAC_FILE" ]; then
    return 1
  fi
  networksetup -setautoproxyurl "$service" "$PAC_URL"
  networksetup -setautoproxystate "$service" on
  gum style --foreground 10 "Automatic proxy enabled on ${service} → ${PAC_URL}"
}

disable_pac_proxy() {
  local service
  service=$(get_active_service) || return 0
  networksetup -setautoproxystate "$service" off
  gum style --foreground 8 "Automatic proxy disabled on ${service}"
}

# ========================  tun2socks routing  ==============================

# Look for tun2socks in PATH and common install locations
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
TUN2SOCKS_BIN=""

# Start tun2socks and configure IP routing + DNS
start_tunnel() {
  local before after tun_dev

  mkdir -p "$STATE_DIR"

  # Snapshot current interfaces
  before=$(ifconfig -l)

  # Start tun2socks (creates a utun device routed through the SOCKS proxy)
  TUN2SOCKS_BIN=$(find_tun2socks)
  sudo "$TUN2SOCKS_BIN" -device utun -proxy socks5://127.0.0.1:1080 >/dev/null 2>&1 &
  echo $! | sudo tee "$STATE_DIR/tun2socks.pid" >/dev/null

  # Give tun2socks time to create the interface
  sleep 2

  # Discover the new utun device
  after=$(ifconfig -l)
  tun_dev=$(comm -13 <(echo "$before" | tr ' ' '\n' | sort) \
                     <(echo "$after"  | tr ' ' '\n' | sort) \
            | grep '^utun' | head -1)

  if [ -z "$tun_dev" ]; then
    gum style --foreground 9 "Failed to create tun device — is tun2socks working?"
    stop_tunnel 2>/dev/null || true
    return 1
  fi

  echo "$tun_dev" > "$STATE_DIR/tun_dev"

  # Bring the interface up with a carrier-grade NAT address (never routed on the internet)
  sudo ifconfig "$tun_dev" 198.18.0.1 198.18.0.1 up

  # --- Add routes for internal networks ---
  local IFS_SAVE="$IFS"
  IFS=','
  for route in ${VPN_ROUTES}; do
    IFS="$IFS_SAVE"
    route=$(echo "$route" | xargs)          # trim whitespace
    [ -z "$route" ] && continue
    sudo route -q add -net "$route" -interface "$tun_dev" 2>/dev/null || true
    echo "$route" >> "$STATE_DIR/routes"
  done
  IFS="$IFS_SAVE"

  # --- Configure split DNS via /etc/resolver ---
  if [ -n "${VPN_DNS:-}" ] && [ -n "${VPN_DOMAINS:-}" ]; then
    sudo mkdir -p /etc/resolver
    local IFS_SAVE="$IFS"
    IFS=','
    for domain in ${VPN_DOMAINS}; do
      IFS="$IFS_SAVE"
      domain=$(echo "$domain" | xargs)
      [ -z "$domain" ] && continue
      if echo "nameserver ${VPN_DNS}" | sudo tee "/etc/resolver/${domain}" >/dev/null; then
        echo "$domain" >> "$STATE_DIR/domains"
      else
        gum style --foreground 9 "Failed to create /etc/resolver/${domain}"
      fi
    done
    IFS="$IFS_SAVE"
  fi

  gum style --foreground 10 "Network-level split tunneling active on ${tun_dev}"
}

# Tear down tun2socks, routes (auto-removed with interface), and DNS
stop_tunnel() {
  # Kill tun2socks (removes the utun device and its routes automatically)
  if [ -f "$STATE_DIR/tun2socks.pid" ]; then
    sudo kill "$(cat "$STATE_DIR/tun2socks.pid")" 2>/dev/null || true
    rm -f "$STATE_DIR/tun2socks.pid"
  fi

  # Remove /etc/resolver entries we created
  if [ -f "$STATE_DIR/domains" ]; then
    while IFS= read -r domain; do
      sudo rm -f "/etc/resolver/${domain}"
    done < "$STATE_DIR/domains"
  fi

  rm -rf "$STATE_DIR"
}

# ========================  Commands  =======================================

usage() {
  echo "Usage: split start | split stop"
  echo ""
  echo "  start   Connect to VPN and enable split tunneling"
  echo "  stop    Disconnect VPN and remove split tunneling"
  exit 1
}

cmd_stop() {
  load_env
  stop_tunnel 2>/dev/null || true
  disable_pac_proxy 2>/dev/null || true
  docker compose down
  gum style \
    --foreground 10 --border-foreground 10 --border double \
    --align center --width 50 --margin "1 2" --padding "1 2" \
    "STOPPED" "VPN container removed and split tunneling disabled."
  exit 0
}

cmd_start() {
  load_env

  # --- Check prerequisites ---
  if ! command -v gum >/dev/null 2>&1; then
    echo "Error: 'gum' is not installed. Please install it (e.g., 'brew install gum')." >&2
    exit 1
  fi

  # Pre-authenticate sudo early so the password prompt is clearly visible
  # and credentials are cached for later tun2socks/DNS setup.
  if has_tun2socks && [ -n "${VPN_ROUTES:-}" ]; then
    echo "sudo access is needed for split tunneling (tunnel interface + DNS)."
    sudo -v || { echo "sudo authentication failed." >&2; exit 1; }
  fi

  gum style \
    --foreground 212 --border-foreground 212 --border double \
    --align center --width 50 --margin "1 2" --padding "2 4" \
    "VPN Proxy Setup" "Enter your FortiGate credentials"

  # --- Interactive credential prompts (defaults from .env) ---
  FORTI_HOST=$(gum input --header "VPN Hostname" --placeholder "vpn.company.com" --value "${FORTI_HOST:-}")
  export FORTI_HOST

  FORTI_PORT=$(gum input --header "VPN Port" --placeholder "443" --value "${FORTI_PORT:-443}")
  export FORTI_PORT

  FORTI_USER=$(gum input --header "Username" --placeholder "john.doe" --value "${FORTI_USER:-}")
  export FORTI_USER

  FORTI_PASS=$(gum input --password --header "Password or Password+Token" --placeholder "YourPassword123..." --value "${FORTI_PASS:-}")
  export FORTI_PASS

  while true; do
    FORTI_OTP=$(gum input --header "2FA OTP" --placeholder "123456" --value "${FORTI_OTP:-}")
    if [[ "$FORTI_OTP" =~ ^[0-9]{6}$ ]]; then
      break
    fi
    gum style --foreground 9 "Error: OTP must be exactly 6 digits and cannot be empty."
  done
  export FORTI_OTP

  FORTI_TRUSTED_CERT=$(gum input --header "Trusted Certificate (Optional)" --placeholder "sha256 fingerprint..." --value "${FORTI_TRUSTED_CERT:-}")
  export FORTI_TRUSTED_CERT

  FORTI_REALM=$(gum input --header "Realm (Optional)" --placeholder "Staff" --value "${FORTI_REALM:-}")
  export FORTI_REALM

  echo ""

  # --- Start the container ---
  if ! gum spin --spinner dot --title "Starting VPN container..." -- docker compose up -d; then
    gum style \
      --foreground 9 --border-foreground 9 --border double \
      --align center --width 50 --margin "1 2" --padding "1 2" \
      "FAILURE" "Could not start the VPN container." \
      "Please check if docker compose is installed and configured."
    exit 1
  fi

  # Resolve container name
  CONTAINER_NAME=$(docker compose ps --format '{{.Name}}' forti-socks 2>/dev/null || echo "forti-socks")

  if [ "$(docker inspect -f '{{.State.Status}}' "$CONTAINER_NAME" 2>/dev/null || echo 'notfound')" = "notfound" ]; then
    gum style \
      --foreground 9 --border-foreground 9 --border double \
      --align center --width 50 --margin "1 2" --padding "1 2" \
      "FAILURE" "Container not found. Check docker compose configuration."
    exit 1
  fi

  # --- Wait for VPN connection or failure ---
  VPN_CONNECTED=false

  gum spin --spinner dot --title "Waiting for VPN connection..." -- bash -c "
    ERROR_PAT='Could not authenticate to gateway|Authentication failed|Invalid OTP|OTP required|Connection failed|check the password, client certificate|Invalid password|Certificate error|Gateway unreachable|VPN process terminated unexpectedly|VPN did not create ppp0'
    for i in {1..40}; do
      STATUS=\$(docker inspect -f '{{.State.Status}}' $CONTAINER_NAME 2>/dev/null || echo 'unknown')
      if [ \"\$STATUS\" = \"exited\" ]; then
        exit 1
      fi
      if docker exec $CONTAINER_NAME ip link show ppp0 >/dev/null 2>&1; then
        exit 0
      fi
      if docker logs $CONTAINER_NAME 2>&1 | grep -qiE \"\$ERROR_PAT\"; then
        exit 1
      fi
      sleep 1
    done
    exit 1
  " && VPN_CONNECTED=true || VPN_CONNECTED=false

  # --- Handle connection failure ---
  if [ "$VPN_CONNECTED" != true ]; then
    ERROR_PATTERNS="Could not authenticate to gateway|Authentication failed|Invalid OTP|OTP required|Connection failed|check the password, client certificate|Invalid password|Certificate error|Gateway unreachable|VPN process terminated unexpectedly|VPN did not create ppp0"
    LOGS=$(docker logs --tail 50 "$CONTAINER_NAME" 2>&1 || true)
    VPN_ERROR=$(echo "$LOGS" | grep -iE "$ERROR_PATTERNS" | tail -n 3 || true)

    if [ -z "$VPN_ERROR" ]; then
      VPN_ERROR=$(echo "$LOGS" | grep -iE "ERROR:|error:|fatal" | tail -n 3 || true)
    fi
    if [ -z "$VPN_ERROR" ]; then
      VPN_ERROR="Connection timed out or failed without a specific error."
    fi

    echo ""
    gum style \
      --foreground 9 --border-foreground 9 --border double \
      --align center --width 50 --margin "1 2" --padding "1 2" \
      "FAILURE" "VPN connection failed"
    echo ""
    gum style --foreground 9 --bold "Error details:"
    echo "$VPN_ERROR" | while IFS= read -r line; do
      gum style --foreground 9 "  $line"
    done
    echo ""
    gum style --foreground 8 "Full logs: docker compose logs"
    echo ""
    gum confirm "Press Enter to exit..." --default=true --affirmative="OK" --negative="" || true
    exit 1
  fi

  # --- Enable split tunneling ---
  echo ""

  if has_tun2socks && [ -n "${VPN_ROUTES:-}" ]; then
    # ---- Network-level split tunneling (all protocols) ----
    if start_tunnel; then
      gum style \
        --foreground 10 --border-foreground 10 --border double \
        --align center --width 60 --margin "1 2" --padding "1 2" \
        "SUCCESS" "" \
        "VPN connected — all protocols routed"
      echo ""
      gum style --foreground 10 --bold "What works now:"
      gum style --foreground 7 "  SSH, Git, HTTP, HTTPS and any TCP/UDP traffic"
      gum style --foreground 7 "  to the configured VPN routes."
      echo ""
      gum style --foreground 10 --bold "Routed networks:"
      local IFS=','
      for r in ${VPN_ROUTES}; do
        r=$(echo "$r" | xargs)
        [ -n "$r" ] && gum style --foreground 7 "  $r"
      done
      if [ -n "${VPN_DOMAINS:-}" ]; then
        echo ""
        gum style --foreground 10 --bold "Split DNS domains:"
        for d in ${VPN_DOMAINS}; do
          d=$(echo "$d" | xargs)
          [ -n "$d" ] && gum style --foreground 7 "  $d"
        done
      fi
      echo ""
      gum style --foreground 8 "To disconnect:  ./split.sh stop"
      gum style --foreground 8 "To view logs:   docker compose logs -f"
    else
      # tun2socks failed — fall back to PAC
      gum style --foreground 11 "tun2socks failed — falling back to browser-only PAC proxy."
      PAC_OK=false
      enable_pac_proxy && PAC_OK=true || true
      gum style \
        --foreground 11 --border-foreground 11 --border double \
        --align center --width 60 --margin "1 2" --padding "1 2" \
        "PARTIAL" "" \
        "VPN connected — tun2socks failed"
      echo ""
      if [ "$PAC_OK" = true ]; then
        gum style --foreground 11 "Browser traffic is routed via the PAC proxy."
      else
        gum style --foreground 11 "No PAC file found — no traffic is routed automatically."
        gum style --foreground 11 "Copy the example PAC file to enable browser routing:"
        gum style --foreground 7 "  mkdir -p ~/Proxy"
        gum style --foreground 7 "  cp proxy.pac.example ~/Proxy/packsolutions.pac"
        gum style --foreground 7 "  # Edit the file to match your internal domains, then restart."
      fi
      echo ""
      gum style --foreground 7 "For SSH, Git, or any CLI tool, set the SOCKS proxy manually:"
      echo ""
      gum style --foreground 7 "  ALL_PROXY=socks5h://127.0.0.1:1080 ssh user@host"
      gum style --foreground 7 "  ALL_PROXY=socks5h://127.0.0.1:1080 git clone ..."
      echo ""
      gum style --foreground 8 "To disconnect:  ./split.sh stop"
    fi
  else
    # ---- PAC fallback (browser-only) ----
    PAC_OK=false
    enable_pac_proxy && PAC_OK=true || true

    if [ "$PAC_OK" = true ]; then
      gum style \
        --foreground 10 --border-foreground 10 --border double \
        --align center --width 60 --margin "1 2" --padding "1 2" \
        "SUCCESS" "" \
        "VPN connected — browser proxy active"
      echo ""
      gum style --foreground 10 "Browser traffic matching your PAC rules is routed through the VPN."
      gum style --foreground 8 "PAC file: ${PAC_FILE}"
    else
      gum style \
        --foreground 11 --border-foreground 11 --border double \
        --align center --width 60 --margin "1 2" --padding "1 2" \
        "SUCCESS" "" \
        "VPN connected — SOCKS proxy available on :1080"
      echo ""
      gum style --foreground 11 "No PAC file found — no traffic is routed automatically."
      gum style --foreground 11 "To enable browser routing, create a PAC file:"
      gum style --foreground 7 "  mkdir -p ~/Proxy"
      gum style --foreground 7 "  cp proxy.pac.example ~/Proxy/packsolutions.pac"
      gum style --foreground 7 "  # Edit the file to match your internal domains, then restart."
    fi
    echo ""
    gum style --foreground 7 "For SSH, Git, or any CLI tool, set the SOCKS proxy manually:"
    echo ""
    gum style --foreground 7 "  ALL_PROXY=socks5h://127.0.0.1:1080 ssh user@host"
    gum style --foreground 7 "  ALL_PROXY=socks5h://127.0.0.1:1080 git clone ..."
    echo ""

    if ! has_tun2socks || [ -z "${VPN_ROUTES:-}" ]; then
      gum style --foreground 11 --bold "Want full split tunneling (SSH, Git, etc.)?"
      echo ""
      if ! has_tun2socks; then
        gum style --foreground 11 "  1. Install tun2socks:"
        gum style --foreground 7 "     go install github.com/xjasonlyu/tun2socks/v2@latest"
        echo ""
      fi
      gum style --foreground 11 "  2. Set these variables in .env:"
      echo ""
      gum style --foreground 7 "     # IP ranges to route through the VPN (ask your admin)"
      gum style --foreground 7 "     VPN_ROUTES=10.0.0.0/8"
      gum style --foreground 7 "     # DNS server inside the VPN"
      gum style --foreground 7 "     VPN_DNS=10.0.0.1"
      gum style --foreground 7 "     # Internal domains to resolve via VPN DNS"
      gum style --foreground 7 "     VPN_DOMAINS=packsolutions.local"
      echo ""
      gum style --foreground 11 "  Then restart:  ./split.sh stop && ./split.sh start"
      echo ""
    fi

    gum style --foreground 8 "To disconnect:  ./split.sh stop"
    gum style --foreground 8 "To view logs:   docker compose logs -f"
  fi

  exit 0
}

# --- Dispatch ---
CMD="${1:-}"

case "$CMD" in
  start) cmd_start ;;
  stop)  cmd_stop ;;
  *)     usage ;;
esac
