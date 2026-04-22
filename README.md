# Packxy

macOS split tunneling for FortiGate VPN. Connects via `openfortivpn` inside a Docker container, exposes a local SOCKS5 proxy, and routes only your internal traffic through the VPN — everything else stays direct.

## How it works

```
 macOS app                    Docker container
 ─────────         ┌──────────────────────────┐
   SSH  ───┐       │  openfortivpn ── ppp0    │
   Git  ───┤       │       ↕                  │
   curl ───┼──→ :1080 ── danted (SOCKS5)      │
 browser ──┘       └──────────────────────────┘
         tun2socks
       routes traffic
       to the tunnel
```

**Two routing modes** (selected automatically):

| Mode | Protocols | Requires |
|---|---|---|
| **tun2socks** (recommended) | All — SSH, Git, HTTP, HTTPS, etc. | `tun2socks` installed + `VPN_ROUTES` in `.env` |
| **PAC proxy** (fallback) | Browser only — HTTP / HTTPS | A PAC file on disk |

## Prerequisites

- [Docker Desktop](https://www.docker.com/products/docker-desktop/) (with Docker Compose)
- [gum](https://github.com/charmbracelet/gum) — interactive terminal prompts
  ```bash
  brew install gum
  ```
- [tun2socks](https://github.com/xjasonlyu/tun2socks) — for network-level split tunneling (recommended)
  ```bash
  go install github.com/xjasonlyu/tun2socks/v2@latest
  ```
  > Requires Go 1.21+. The binary is installed to `$GOPATH/bin` (or `~/go/bin` by default) — make sure it's in your `PATH`.
- FortiGate VPN credentials (host, username, password, OTP)

## Quick start

### 1. Configure

Copy the sample environment file and fill in your values:

```bash
cp .env.sample .env
```

Edit `.env` in two parts:

**a) VPN credentials** — fill in your FortiGate connection details:

```env
FORTI_HOST=vpn.example.com
FORTI_PORT=443
FORTI_USER=jdoe
FORTI_PASS=YourPassword123
FORTI_TRUSTED_CERT=abcdef1234...
```

**b) Split tunneling** — tell Packxy which traffic to route through the VPN.

You need three pieces of information from your network administrator:

| What you need | How to find it | Example |
|---|---|---|
| Internal IP ranges (CIDR) | Ask your admin, or connect to the VPN manually and run `ip route` | `10.0.0.0/8` |
| Internal DNS server | Ask your admin, or check `/etc/resolv.conf` while connected | `10.0.0.1` |
| Internal domain names | The domain suffix of your internal apps (e.g. `*.packsolutions.local`) | `packsolutions.local` |

Then set these in `.env`:

```env
VPN_ROUTES=10.0.0.0/8
VPN_DNS=10.0.0.1
VPN_DOMAINS=packsolutions.local
```

This tells Packxy:
- **`VPN_ROUTES`**: route all traffic to `10.0.0.0/8` through the VPN tunnel (everything else stays direct)
- **`VPN_DNS`**: resolve internal hostnames using the DNS server at `10.0.0.1` (inside the VPN)
- **`VPN_DOMAINS`**: only use that DNS server for `*.packsolutions.local` names (all other DNS stays local)

See [Configuration reference](#configuration-reference) for all options.

### 2. Build

```bash
docker compose build
```

### 3. Connect

```bash
./split.sh start
```

The script will show your saved values and prompt for confirmation. You will always be asked for a fresh **OTP code**.

### 4. Disconnect

```bash
./split.sh stop
```

This tears down the VPN container, removes tun2socks routes, and restores your network settings.

## Configuration reference

All settings go in the `.env` file. Values are pre-filled in the interactive prompts.

### VPN connection

| Variable | Required | Description |
|---|---|---|
| `FORTI_HOST` | yes | FortiGate VPN hostname (e.g. `vpn.example.com`) |
| `FORTI_PORT` | | VPN port (default: `443`) |
| `FORTI_USER` | yes | VPN username |
| `FORTI_PASS` | yes | VPN password |
| `FORTI_TRUSTED_CERT` | | Server certificate SHA-256 fingerprint (avoids certificate prompts) |
| `FORTI_REALM` | | VPN realm, if your server requires one |
| `FORTI_OTP` | | 6-digit 2FA code — **do not save in `.env`**, enter it fresh each time |
| `FORTI_NO_FTM_PUSH` | | Set to `1` to disable FortiToken push and force manual OTP entry |
| `FORTI_OTP_PROMPT` | | Custom OTP prompt string for prompt detection |

### Split tunneling (tun2socks)

These three variables enable network-level routing so **all** protocols (SSH, Git, HTTP, HTTPS, etc.) work through the VPN — not just browser traffic. All three must be set for split tunneling to activate.

| Variable | What it does | Example |
|---|---|---|
| `VPN_ROUTES` | IP ranges to send through the VPN. Traffic to these CIDRs goes through the tunnel; everything else stays direct. | `10.0.0.0/8` |
| `VPN_DNS` | DNS server inside the VPN, used to resolve internal hostnames. | `10.0.0.1` |
| `VPN_DOMAINS` | Domain suffixes to resolve via `VPN_DNS`. Only these domains use the VPN DNS; all other lookups use your normal DNS. | `packsolutions.local` |

Multiple values are comma-separated: `VPN_ROUTES=10.0.0.0/8,172.16.0.0/12`

### PAC proxy (browser-only fallback)

If tun2socks is not installed or `VPN_ROUTES` is not set, the script falls back to a PAC (Proxy Auto-Configuration) file. A PAC file tells your **browser** which domains to route through the SOCKS proxy and which to access directly.

> **Important:** The PAC file only affects browser traffic (HTTP/HTTPS). CLI tools like `ssh`, `git`, or `curl` are **not** affected — you need to set `ALL_PROXY=socks5h://127.0.0.1:1080` manually for those (or use the tun2socks mode instead).

**When do you need this?** Only if you are not using tun2socks. If tun2socks + `VPN_ROUTES` are configured, the PAC file is not used.

**Setup:**

```bash
mkdir -p ~/Proxy
cp proxy.pac.example ~/Proxy/packsolutions.pac
```

Then edit `~/Proxy/packsolutions.pac` and replace the example domains with your actual internal domains. See `proxy.pac.example` in this repo for the format.

The script automatically sets this file as the macOS system proxy on `./split.sh start` and removes it on `./split.sh stop`.

| Variable | Description | Default |
|---|---|---|
| `PAC_FILE` | Path to your PAC file | `~/Proxy/packsolutions.pac` |

## Testing the connection

After a successful `./split.sh start`, verify the tunnel is working:

```bash
# Test SOCKS proxy directly
curl --socks5-hostname 127.0.0.1:1080 https://internal-app.example.com

# Test DNS resolution through the tunnel (if VPN_DOMAINS is set)
nslookup internal-app.example.com

# With tun2socks active, regular commands just work
ssh user@internal-server.example.com
git clone git@internal-git.example.com:repo.git
```

## Useful commands

| Action | Command |
|---|---|
| Start VPN | `./split.sh start` |
| Stop VPN | `./split.sh stop` |
| Rebuild image | `docker compose build` |
| View live logs | `docker compose logs -f` |
| Container status | `docker compose ps` |

## Troubleshooting

### Authentication failed

- Double-check `FORTI_HOST`, `FORTI_USER`, `FORTI_PASS`, and `FORTI_TRUSTED_CERT`
- OTP codes expire quickly — enter the code as soon as it appears
- If using FortiToken push, try setting `FORTI_NO_FTM_PUSH=1` to switch to manual OTP
- Check the logs: `docker compose logs`

### VPN did not create ppp0

- The container needs `/dev/ppp` — make sure Docker Desktop has access to it
- The VPN may have authenticated but the PPP negotiation failed — check logs

### tun2socks not working

- Verify it's installed: `which tun2socks`
- The script needs `sudo` to create the tunnel interface — you'll be prompted for your password
- Check that `VPN_ROUTES` is set in `.env`

### Connection drops / container exits

- The container does **not** auto-restart — this is intentional to avoid account lockout from repeated failed logins
- Simply run `./split.sh start` again with a fresh OTP

## Project files

| File | Purpose |
|---|---|
| `split.sh` | Main CLI — start/stop VPN + split tunneling |
| `docker-compose.yml` | Docker Compose service definition |
| `Dockerfile` | Container image (Debian + openfortivpn + danted) |
| `entrypoint.sh` | Container entrypoint — connects VPN, starts SOCKS proxy |
| `danted.conf` | Dante SOCKS5 proxy configuration |
| `.env` | Your VPN credentials and routing config (git-ignored) |
| `.env.sample` | Template for `.env` |
| `proxy.pac.example` | Example PAC file for the browser-only fallback mode |

## Security notes

- The SOCKS proxy binds to `127.0.0.1` only — it is not exposed to your network
- Do not commit `.env` — it contains your VPN password
- OTP codes are single-use; do not store them in `.env`

## References

- [openfortivpn](https://github.com/adrienverge/openfortivpn)
- [tun2socks](https://github.com/xjasonlyu/tun2socks)
- [gum](https://github.com/charmbracelet/gum)
- [Dante SOCKS server](https://www.inet.no/dante/)
