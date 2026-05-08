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

### The menu-bar tray

Once installed and started from the bundle, packxy adds a discreet status item to the macOS menu bar with a padlock template icon (locked when the tunnel is up, unlocked when down). Click it for a glanceable summary:

```
🟢  Connected
─────────────────
IP:     10.212.134.1
Routes: 10.0.0.0/8
DNS:    packsolutions.local
─────────────────
Last drop: wake (3m ago)   (only shown when one is recorded)
─────────────────
Disconnect & Quit  ⌘Q
```

The tray runs as `packxy _tray` — its own process with a continuous AppKit run loop (which the Setsid'd watcher can't host). It polls `/tmp/packxy/` every 2 s and updates the menu in place; clicking **Disconnect & Quit** spawns `packxy stop`. The tray is started automatically by `packxy start` and torn down by `packxy stop`. It is only enabled when packxy is invoked from the `.app` bundle (the bare CLI binary skips it silently).

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

Two equivalent paths: download the prebuilt `.app` bundle (recommended) or build from source.

**From a release archive:**

```bash
# Download packxy-vX.Y.Z-darwin-universal.app.tar.gz from the Releases page
tar -xzf packxy-*-darwin-universal.app.tar.gz
./packxy.app/Contents/MacOS/packxy install
```

**From source:**

```bash
make app                        # builds packxy.app at the project root
./packxy.app/Contents/MacOS/packxy install
```

`packxy install` writes (sudo password required, **once**):

- `/etc/sudoers.d/packxy` — allows your user to run `openfortivpn` and `pkill -x openfortivpn` (TERM/KILL flavours only) without re-prompting for sudo. The watcher needs this to restart the VPN after a drop, and to pre-stop it on macOS sleep notifications, without your sudo cache having to stay fresh.
- `/etc/ppp/peers/packxy` — pppd options that preserve split tunneling (`nodefaultroute`) and configure the LCP echo keepalive.
- `/usr/local/bin/packxy` — symlink to `Contents/MacOS/packxy` inside the `.app`, so you can call `packxy` from any terminal once you've moved the bundle wherever you want it (typical: `/Applications/packxy.app`).

To remove these files later: `./packxy uninstall` (or just `packxy uninstall` if the symlink is in place). The `.app` itself isn't touched — drop it in the Trash by hand.

### Why a `.app` bundle?

The watcher posts macOS notifications when the VPN drops or you need to enter a new OTP. If packxy ran as a bare CLI, those notifications would carry the AppleScript script-runner icon (Apple's CLI surface gives no way to override it). Bundled inside `packxy.app`, packxy uses `NSUserNotification` directly via cgo + AppKit, and the notifications display the bundle's icon (a violet-to-cyan padlock) and identifier instead. The bundle is ad-hoc-signed at build time, so macOS treats it as a real, locally-trusted app.

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
packxy start
```

`packxy start` reads `.env`, displays whatever it found in a "From .env:" reminder card (so you don't retype it), and only prompts for fields that are missing — plus the **OTP code**, which is always asked for fresh (single-use). On success it brings up `ppp0`, adds the routes, writes the resolvers, arms the watcher, and (from the `.app` bundle) shows the menu-bar tray.

### 4. Disconnect

```bash
packxy stop
```

This kills the menu-bar tray, the watcher, and `openfortivpn`, and removes the `/etc/resolver/` entries. Routes pointing at `ppp0` are flushed automatically by the kernel when the interface goes down.

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
| Install (one-time) | `packxy install` |
| Uninstall | `packxy uninstall` |
| Start VPN | `packxy start` |
| Stop VPN | `packxy stop` |
| Show state | `packxy status` |
| Build CLI binary | `make build` |
| Build `.app` bundle | `make app` (or `make app-universal` for both arches) |
| Regenerate icon | `make icon` (after editing `cmd/genicon`) |
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

### `/etc/resolver/<domain>` left after stop

Removing the resolver entries needs sudo privilege that isn't in the
sudoers drop-in (only `openfortivpn`, `pkill -x openfortivpn`, and
`route` are passwordless). `packxy stop` falls back to the cached sudo
credential, which expires ~5 min after `packxy start`. If you stop the
session hours later the resolver files may stay behind. Either run
`sudo -v` first, or remove them by hand:

```bash
sudo rm /etc/resolver/packsolutions.local
```

Routes via `ppp0` are flushed automatically by the kernel when the
interface goes down — no manual cleanup needed there.

## Project files

| File | Purpose |
|---|---|
| `cmd/packxy/main.go` | CLI entry — user-facing `install` / `start` / `stop` / `status` plus the internal `_watcher` / `_otpdialog` / `_tray` re-exec subcommands |
| `cmd/genicon/main.go` | Build-time tool: paints `assets/icon.png` (1024×1024 padlock) |
| `internal/forti/` | Native openfortivpn driver, install/uninstall, default-route capture/restore |
| `internal/macnet/macnet.go` | Plain-Go shell helpers: routes, DNS resolvers, `IfaceIPv4`, sudo validation |
| `internal/macnet/dialog.go` | `Notify` + `PromptOTP` (cgo path inside .app, osascript fallback) |
| `internal/macnet/dialog_native.go` | NSAlert via cgo + AppKit (used by `packxy _otpdialog`) |
| `internal/macnet/notification.go` | NSUserNotification cgo bridge for bundle-iconed notifications |
| `internal/macnet/sleepwake.go` | IOKit cgo bridge — `IORegisterForSystemPower` → Go channel |
| `internal/macnet/tray.go` + `tray_objc.m` | NSStatusItem menu-bar indicator (Go bindings + Objective-C impl) |
| `internal/ui/` | Terminal UI (huh prompts, lipgloss styling, `HumanizeAge` formatter) |
| `internal/envcfg/` | `.env` loading |
| `internal/state/` | `/tmp/packxy` state (PID files, routes, domains, last drop) |
| `resources/Info.plist` | `.app` bundle metadata template (CFBundleIdentifier, LSUIElement) |
| `assets/icon.png` | Source artwork for `AppIcon.icns` (regenerate with `make icon`) |
| `Makefile` | `build`, `app`, `app-universal`, `icon`, `clean` |
| `.env` | Your VPN credentials and routing config (git-ignored) |
| `.env.sample` | Template for `.env` |

## Security notes

- The sudoers drop-in (`/etc/sudoers.d/packxy`) grants exactly three passwordless commands: `openfortivpn` (any args, since openfortivpn itself is the only thing the rule can launch as root), `pkill` narrowly scoped to the `-x openfortivpn` target, and `route` (needed to restore the host's default route after pppd hijacks it, and to re-add VPN routes after each reconnect). Inspect with `cat /etc/sudoers.d/packxy`.
- The `.app` bundle is ad-hoc-signed (`codesign --sign -`), enough for local trust on the machine that built or downloaded it. There is no Developer ID / notarization — first-run Gatekeeper warnings on a fresh download are expected. Right-click → Open, or run `xattr -dr com.apple.quarantine packxy.app`, to clear them.
- Do not commit `.env` — it contains your VPN password.
- OTP codes are single-use; do not store them in `.env`.

## References

- [openfortivpn](https://github.com/adrienverge/openfortivpn)
- [Charm huh](https://github.com/charmbracelet/huh) and [lipgloss](https://github.com/charmbracelet/lipgloss) — terminal UI
