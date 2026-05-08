# Packxy

macOS split tunneling for FortiGate VPN. Runs `openfortivpn` natively on the host, creating a `ppp0` interface, then routes only your internal IP ranges through the VPN — everything else stays direct.

## How it works

```
 macOS host
 ─────────
   apps                                ┌──────────────────┐
    │                                  │  FortiGate VPN   │
    ├─ default route (en0/Wi-Fi)       │   gateway        │
    │  ────→ Internet                  └──────────────────┘
    │                                            ▲
    └─ specific routes (VPN_ROUTES)              │ TLS
       ────→ ppp0 ────→ openfortivpn ────────────┘
                       (native subprocess)
```

Packxy ships as a single self-contained Go binary. `openfortivpn` runs natively on the host as a privileged subprocess; its `pppd` creates a real `ppp0` interface in the macOS kernel, reachable directly by the host's routing table. All protocols (SSH, Git, HTTP, HTTPS, etc.) work transparently.

The host's default route and `/etc/resolv.conf` are **not** modified: only the configured CIDRs go through the VPN, only the configured domains use the VPN DNS server (via `/etc/resolver/`).

### Split tunneling — four locks

Out of the box, `openfortivpn` and macOS would both try to put you in **full-tunnel** mode. Packxy applies four layered controls to keep traffic split:

**1. openfortivpn adds no routes, touches no DNS**
The generated `/tmp/packxy/openfortivpn.conf` sets:
```
set-routes = 0          # openfortivpn does not modify the routing table
set-dns = 0             # openfortivpn does not modify /etc/resolv.conf
pppd-use-peerdns = 0    # openfortivpn does not ask pppd to import peer DNS
```

**2. pppd does not replace the default route**
The pppd peer file at `/etc/ppp/peers/packxy` (written by `packxy install`) contains:
```
230400                  # explicit baud rate (BSD pppd requirement on a pty)
nodefaultroute          # pppd must not become the default route
lcp-echo-interval 10    # keepalive heartbeat (~60s dead-link window)
lcp-echo-failure 6
```

**3. macOS SystemConfiguration default-route injection is reverted**
Even with `nodefaultroute`, macOS' `SystemConfiguration` framework auto-installs a default route via `ppp0` when the interface comes up. Packxy works around this:

- before launching `openfortivpn`, `forti.Start` captures the current default route (gateway + interface);
- once `ppp0` is up, if the active default has switched to `ppp0`, packxy deletes it and re-adds the captured original.

The result is that the host's normal default route (typically `en0`/Wi-Fi) survives the VPN coming up.

**4. Only the explicit CIDRs and domains touch the VPN**
- For each entry in `VPN_ROUTES`, `internal/macnet` runs `sudo route add -net <CIDR> -interface ppp0`. These routes are more specific than the default route, so traffic to those CIDRs alone is sent through `ppp0`.
- For each entry in `VPN_DOMAINS`, packxy writes `/etc/resolver/<domain>` with `nameserver <VPN_DNS>`. macOS' resolver framework consults that file only for matching queries; every other DNS lookup goes through your usual resolver. `/etc/resolv.conf` is never modified.

### The watcher

After `packxy start` brings the tunnel up, it spawns a detached background process — the **watcher** — that owns the runtime lifecycle of the VPN. Its job is to react to drops without you having to rerun `packxy start`.

```
   packxy start                       packxy _watcher (background)
   ─────────────                      ────────────────────────────
   spawn openfortivpn  ─────────→     poll openfortivpn PID (3s)
   add routes / DNS                   subscribe IOKit power events
   spawn watcher ──────────┐
   exit                    └────────→  on drop / sleep:
                                         classify reason
                                         pop OTP dialog
                                         restart openfortivpn
                                         re-add routes if needed
```

**Sleep/wake via IOKit.** The watcher subscribes to macOS power notifications using `IORegisterForSystemPower` (CFRunLoop in a locked OS thread). Two events drive its behaviour:

- **`kIOMessageSystemWillSleep`** — delivered a few seconds before the kernel actually suspends. The watcher uses this window to `sudo -n pkill -TERM -x openfortivpn`, which releases the FortiGate session cleanly server-side. Without this, the link would stay half-dead for ~60 s after wake (the `lcp-echo-failure 6` window) before the next OTP prompt could appear.
- **`kIOMessageSystemHasPoweredOn`** — delivered the moment the system finishes resuming. The watcher's PID-poll loop sees `openfortivpn` already gone (thanks to the pre-sleep `pkill`) and immediately fires the OTP dialog with the wake-flavoured message. End-to-end latency is sub-second instead of the prior wall-clock-jump heuristic's ~10–90 s.

**OTP prompting and backoff.** When `openfortivpn` exits for any reason, the watcher classifies the cause from the openfortivpn log (`auth-expired` / `network-drop` / `wake`), pops a native macOS dialog with a contextual message, and restarts the VPN with the fresh code. Auth failures are paced **0 s / 30 s / 2 m / 5 m / 10 m**, capped at **4 attempts** to stay below FortiGate's typical lockout threshold. Dismissing the dialog tears down routes and resolvers cleanly.

**Why the watcher needs `pkill` privilege.** The sudo cache acquired by `packxy start` expires after ~5 minutes, but the watcher must be able to stop and restart `openfortivpn` hours into a session. The `packxy install` step writes a sudoers drop-in granting `openfortivpn` and `pkill -x openfortivpn` (TERM/KILL flavours) without password — narrow enough to be safe, broad enough for the watcher to operate autonomously.

## Prerequisites

- macOS (Apple Silicon or Intel)
- `openfortivpn` installed via Homebrew: `brew install openfortivpn`
- Go 1.22+ to build the binary (`make build`)
- Xcode Command Line Tools (`xcode-select --install`) — packxy uses cgo to call `IOKit/IORegisterForSystemPower` for sleep/wake notifications
- FortiGate VPN credentials (host, username, password, OTP)

## Quick start

### 1. Install

After installing the `openfortivpn` binary, build packxy and run a one-time install step:

```bash
make build
./packxy install
```

`packxy install` writes two files (sudo password required, **once**):

- `/etc/sudoers.d/packxy` — allows your user to run `openfortivpn` and `pkill -x openfortivpn` (TERM/KILL flavours only) without re-prompting for sudo. The watcher needs this to restart the VPN after a drop, and to pre-stop it on macOS sleep notifications, without your sudo cache having to stay fresh.
- `/etc/ppp/peers/packxy` — pppd options that preserve split tunneling (`nodefaultroute`) and configure the LCP echo keepalive.

To remove these files later: `./packxy uninstall`.

### 2. Configure

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
| Internal IP ranges (CIDR) | Ask your admin, or connect to the VPN manually and run `netstat -rn` | `10.0.0.0/8` |
| Internal DNS server | Ask your admin, or check `/etc/resolv.conf` while connected | `10.0.0.1` |
| Internal domain names | The domain suffix of your internal apps (e.g. `*.packsolutions.local`) | `packsolutions.local` |

Then set these in `.env`:

```env
VPN_ROUTES=10.0.0.0/8
VPN_DNS=10.0.0.1
VPN_DOMAINS=packsolutions.local
```

This tells Packxy:
- **`VPN_ROUTES`**: route all traffic to `10.0.0.0/8` through `ppp0` (everything else stays direct)
- **`VPN_DNS`**: resolve internal hostnames using the DNS server at `10.0.0.1` (via the VPN)
- **`VPN_DOMAINS`**: only use that DNS server for `*.packsolutions.local` names (all other DNS stays local)

See [Configuration reference](#configuration-reference) for all options.

### 3. Connect

```bash
./packxy start
```

Packxy will show your saved values and prompt for confirmation. You will always be asked for a fresh **OTP code**.

### 4. Disconnect

```bash
./packxy stop
```

This stops `openfortivpn`, removes the routes, and removes the `/etc/resolver/` entries.

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

### PPP keepalive

`pppd` LCP echo requests keep the tunnel alive against NAT/firewall idle timeouts and let `pppd` exit quickly when the link goes silent, so the watcher daemon can reconnect with a fresh OTP.

The defaults are baked into `/etc/ppp/peers/packxy` at install time:

- `lcp-echo-interval 10` (heartbeat every 10s)
- `lcp-echo-failure 6` (declare link dead after 6 missed echoes, ~60s tolerance)

To customize, edit `/etc/ppp/peers/packxy` directly, or rerun `packxy install` after changing the defaults in source.

### Split tunneling

`VPN_ROUTES` is **required** — without it Packxy refuses to start. `VPN_DNS` and `VPN_DOMAINS` are optional and enable split DNS for internal hostnames.

| Variable | Required | What it does | Example |
|---|---|---|---|
| `VPN_ROUTES` | yes | IP ranges to send through the VPN. Traffic to these CIDRs goes through `ppp0`; everything else stays direct. | `10.0.0.0/8` |
| `VPN_DNS` | | DNS server inside the VPN, used to resolve internal hostnames. | `10.0.0.1` |
| `VPN_DOMAINS` | | Domain suffixes to resolve via `VPN_DNS`. Only these domains use the VPN DNS; all other lookups use your normal DNS. | `packsolutions.local` |

Multiple values are comma-separated: `VPN_ROUTES=10.0.0.0/8,172.16.0.0/12`

## Testing the connection

After a successful `./packxy start`, verify the tunnel is working:

```bash
# A CIDR inside VPN_ROUTES should route via ppp0
route get 10.0.0.1

# Anything else should stay on your default interface (en0/Wi-Fi)
route get 8.8.8.8

# DNS resolution through the tunnel (if VPN_DOMAINS is set)
# Note: use dscacheutil, not nslookup — nslookup ignores /etc/resolver on macOS
dscacheutil -q host -a name internal-app.example.com

# Then any normal command "just works"
ssh user@internal-server.example.com
git clone git@internal-git.example.com:repo.git
curl http://internal-app.example.com
```

## Useful commands

| Action | Command |
|---|---|
| Install (one-time) | `./packxy install` |
| Uninstall | `./packxy uninstall` |
| Start VPN | `./packxy start` |
| Stop VPN | `./packxy stop` |
| Show state | `./packxy status` |
| Rebuild binary | `make build` |
| Inspect VPN logs | `cat /tmp/packxy/openfortivpn.log` |
| Inspect watcher logs | `cat /tmp/packxy/watcher.log` |

## Troubleshooting

### `openfortivpn not found in PATH`

Install it: `brew install openfortivpn`. Then run `packxy install` again so the sudoers drop-in points at the right binary path.

### Authentication failed

- Double-check `FORTI_HOST`, `FORTI_USER`, `FORTI_PASS`, and `FORTI_TRUSTED_CERT`
- OTP codes expire quickly — enter the code as soon as it appears
- If using FortiToken push, try setting `FORTI_NO_FTM_PUSH=1` to switch to manual OTP
- Check the logs: `cat /tmp/packxy/openfortivpn.log`

### VPN did not create ppp0

- macOS needs `/dev/ppp` — it's available by default since 10.7 (Lion).
- Run `ls -l /dev/ppp` to confirm; if missing, reboot.
- The VPN may have authenticated but the PPP negotiation failed — check the log.

### Connection drops on macOS sleep

The drop itself is unavoidable: when macOS sleeps, every userland process (including `openfortivpn`) is suspended, the FortiGate server times out the session, and the OTP — being single-use — is burned. The watcher reacts within milliseconds via IOKit notifications and pops a fresh-OTP dialog. See [The watcher](#the-watcher) for the full mechanism.

If you dismiss the OTP dialog, routes and resolvers are torn down cleanly — run `./packxy start` again when you want to reconnect. Watcher state and logs: `cat /tmp/packxy/watcher.log`. Inspect last drop with `./packxy status`.

### Routes/DNS not removed after stop

`packxy stop` uses your cached sudo credential (validated at start). After several hours that cache has expired, and route removal can fail silently. Run `sudo -v` then `packxy stop` again, or remove the entries manually:

```bash
sudo route -q delete -net 10.0.0.0/8
sudo rm /etc/resolver/packsolutions.local
```

## Project files

| File | Purpose |
|---|---|
| `cmd/packxy/main.go` | CLI entry — `install` / `start` / `stop` / `status` / `_watcher` |
| `internal/forti/` | Native openfortivpn driver, install/uninstall, default-route capture/restore |
| `internal/macnet/` | macOS networking helpers (routes, DNS, sudo, OTP dialog) |
| `internal/macnet/sleepwake.go` | IOKit cgo bridge — `IORegisterForSystemPower` → Go channel |
| `internal/ui/` | Terminal UI (huh prompts + lipgloss styling) |
| `internal/envcfg/` | `.env` loading |
| `internal/state/` | `/tmp/packxy` state (PIDs, routes, domains, last drop) |
| `Makefile` | `build`, `build-arm64`, `build-amd64`, `universal`, `clean` |
| `.env` | Your VPN credentials and routing config (git-ignored) |
| `.env.sample` | Template for `.env` |

## Security notes

- The sudoers drop-in (`/etc/sudoers.d/packxy`) grants exactly two passwordless commands: `/opt/homebrew/bin/openfortivpn` (any args, since openfortivpn itself is the only thing it can launch as root) and `/usr/bin/pkill` restricted to the `-x openfortivpn` target. Inspect with `cat /etc/sudoers.d/packxy`.
- Do not commit `.env` — it contains your VPN password.
- OTP codes are single-use; do not store them in `.env`.

## References

- [openfortivpn](https://github.com/adrienverge/openfortivpn)
- [Charm huh](https://github.com/charmbracelet/huh) and [lipgloss](https://github.com/charmbracelet/lipgloss) — terminal UI
