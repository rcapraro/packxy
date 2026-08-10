# Packxy

macOS split tunneling for FortiGate VPN, packaged as a native menu-bar
app. Runs `openfortivpn` natively on the host, creating a `ppp0`
interface, then routes only your internal IP ranges through the VPN —
everything else stays direct.

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
                       (subprocess spawned by Packxy.app)
```

Packxy is a Swift / SwiftUI menu-bar app (macOS 14+). It owns the
`openfortivpn` lifecycle, the split-tunnel routes / `/etc/resolver`
files, and the reconnect-on-drop flow. All protocols (SSH, Git, HTTP,
HTTPS, etc.) work transparently because `ppp0` is a real macOS kernel
interface.

The host's default route and `/etc/resolv.conf` are **not** modified:
only the configured CIDRs go through the VPN, only the configured
domains use the VPN DNS server (via `/etc/resolver/`).

Because `set-routes = 0` / `set-dns = 0` make `openfortivpn` discard
what the gateway announces, Packxy recovers it from the log and reports
it in the activity log: the pushed nameservers, and any pushed split
routes — which it also installs, on top of `VPN_ROUTES`. (This needs
`--pppd-ipparam=openfortivpn`, which Packxy passes: openfortivpn only
prints the pushed routes when that option is set.) Routes broader than
a `/8` are refused, since a pushed `0.0.0.0/0` against `ppp0` would be
a full tunnel. FortiGates configured for full tunnel push no split
routes at all; Packxy says so explicitly, because in that case
`VPN_ROUTES` is the *only* thing deciding what reaches the corporate
network.

### Split tunneling — four locks

Out of the box, `openfortivpn` and macOS would both try to put you in
**full-tunnel** mode. Packxy applies four layered controls to keep
traffic split:

**1. openfortivpn adds no routes, touches no DNS.**
The generated `/tmp/packxy/openfortivpn.conf` sets:
```
set-routes = 0          # openfortivpn does not modify the routing table
set-dns = 0             # openfortivpn does not modify /etc/resolv.conf
pppd-use-peerdns = 0    # openfortivpn does not ask pppd to import peer DNS
```

**2. pppd does not replace the default route.**
The pppd peer file at `/etc/ppp/peers/packxy` (written by the app's
Install button) contains:
```
230400                  # explicit baud rate (BSD pppd requirement on a pty)
nodefaultroute          # pppd must not become the default route
lcp-echo-interval 10    # keepalive ping every 10s
lcp-echo-failure 6      # declare link dead after 6 missed echoes (~60s)
```

**3. The default route is restored after pppd hijacks it.**
macOS' SystemConfiguration installs a default route via `ppp0` when
the interface comes up — even with `nodefaultroute`. Packxy captures
the original default route before launching openfortivpn and re-adds
it once `ppp0` is up, undoing the hijack.

**4. Explicit routes for VPN_ROUTES only.**
Packxy adds `route add -net <cidr> -interface ppp0` for each CIDR in
the configured `VPN_ROUTES`. Everything else continues to use the
host's normal default route.

## Install

1. Build the app (`make build` — see below) or grab a release.
2. Open `dist/Packxy.app` and grant macOS notification permission when
   prompted.
3. Click the Packxy menu-bar icon → **Settings…** → **Installation** →
   **Install…**. macOS asks for your admin password and writes:
   - `/etc/sudoers.d/packxy` — grants the current user passwordless
     sudo for `openfortivpn`, `pkill -x openfortivpn`, `route`, and
     `tee/rm/mkdir` on `/etc/resolver/*`.
   - `/etc/ppp/peers/packxy` — pppd peer file with the split-tunnel
     options.
4. Switch to the **Connection** pane and fill in: host, port,
   username, password (stored 0600 in `~/.config/packxy.conf`),
   optional realm / trusted cert.
5. Switch to **Split tunneling** and add at least one CIDR under
   *Routes*; optionally set the internal DNS server and the domains
   it serves, plus one or more hostnames under *Reachability check*.
6. Save.

Optional: **General → Launch Packxy at login** registers the app via
`SMAppService`; macOS will prompt once in System Settings → Login Items
to confirm.

![Packxy Settings window](assets/settings.jpeg)

## Use

- Click the menu-bar shield → **Connect…** → enter the 6-digit 2FA
  code from your authenticator → **Connect**.

  ![Connect to VPN dialog](assets/connection.png)
- The menu bar shows the live state (`🟢 Connected · 10.x.x.x` /
  `🔴 Disconnected · 5m ago` / etc.) plus the active routes & split
  DNS domains.
- On drop (auth expired, network blip, wake from sleep), Packxy posts
  a notification and reopens the OTP prompt with a reason-tailored
  title.
- **Disconnect** from the menu bar tears down `ppp0`, removes the
  configured resolvers, and returns to a clean state.

## Config file

`~/.config/packxy.conf` (mode 0600) — godotenv-style KEY=VALUE. The
app reads and writes it; you can also edit it by hand:

```sh
FORTI_HOST=vpn.example.com
FORTI_PORT=443
FORTI_USER=jdoe
FORTI_PASS=…
# Optional: sha256 fingerprint of the gateway certificate.
FORTI_TRUSTED_CERT=
# Optional: FortiGate authentication realm.
FORTI_REALM=
# Optional: "1" to pass --no-ftm-push.
FORTI_NO_FTM_PUSH=
# Optional: substring openfortivpn matches for the OTP prompt.
FORTI_OTP_PROMPT=
VPN_ROUTES=10.0.0.0/8,172.16.0.0/12
VPN_DNS=10.0.0.1
VPN_DOMAINS=internal.example.com,corp.local
# Optional: hostnames re-resolved after each connect (see below).
VPN_TEST_HOSTS=db.internal.example.com
```

Inline `#` comments are **not** stripped — a `#` must start its own
line, or the rest of it becomes part of the value. The block above is
safe to copy verbatim.

`FORTI_OTP` is **never** persisted — it's a 30-second single-use token
that has no business living in a file.

## Build

Requires macOS 14+, Xcode Command Line Tools (Swift 5.9+ shipped with
CLT 15.3 or later), and `openfortivpn` from Homebrew:

```sh
brew install openfortivpn
make build                          # → dist/Packxy.app (ad-hoc signed)
cp -R dist/Packxy.app /Applications/ # install into /Applications
make run                            # build + open the app
make clean                          # remove dist/, build/, Packxy/.build/
```

The Makefile uses `swift build` (SPM) to compile the executable and a
sips/iconutil pipeline to wrap it into a proper `.app` bundle with an
icon and `LSUIElement=YES` (menu-bar agent, no Dock tile). No full
Xcode required.

## Layout

```
Packxy/
  Package.swift               SPM manifest
  Info.plist                  bundle metadata template
  Sources/Packxy/
    PackxyApp.swift           @main App + scenes
    Core/                     ConfigStore, ConnectionManager,
                              OpenfortivpnDriver, NetworkConfig,
                              PowerObserver, Notifications, …
    UI/                       SettingsView, ConnectionWindow,
                              MenuBarContent, EditableList
assets/icon.png               source for AppIcon.icns
Makefile
README.md
```

## Uninstall

Settings → Installation → **Uninstall…** removes the sudoers drop-in
and the pppd peer file. Then drag `Packxy.app` to the Trash. The
config file at `~/.config/packxy.conf` is left in place — delete it by
hand if you want a clean slate.

## Troubleshooting

- **`WARN: Removing wrong route to vpn server…` on every connect** —
  expected, and load-bearing. It is openfortivpn deleting the `/32`
  route to the VPN gateway that pppd pointed at `ppp0`; left in place
  it would route the tunnel's own TLS traffic into the tunnel. Packxy
  keeps this one grey rather than orange for that reason. Likewise
  `publish_entry SCDSet() failed: Success!` is harmless pppd noise.
- **The log doesn't reflect a change you just built** — replacing
  `Packxy.app` does **not** restart a running instance. Quit Packxy
  from the menu bar and reopen it. Every connect logs a
  `Packxy <version> · openfortivpn <version>` line followed by the full
  `argv:`, so you can confirm which binary and which flags are live.
- **"VPN failed to start"** — check
  `cat /tmp/packxy/openfortivpn.log` for the openfortivpn output.
  If sudo refuses, reinstall the sudoers drop-in
  (Settings → Installation → Reinstall…). The drop-in template
  changed when split-DNS support was added; older installs need a
  refresh.
- **A hostname resolves but the host is unreachable** — the name is
  answered by the VPN DNS, but the address it returns isn't inside any
  `VPN_ROUTES` CIDR, so the packets leave via the host's default route
  and are dropped. Add the host to *Split tunneling → Reachability
  check*: after each connect Packxy resolves it and logs
  `<host> → <ip> is not covered by VPN_ROUTES (…). Add <cidr> …`.
  Widen `VPN_ROUTES` accordingly. Corporate networks frequently span
  more than one RFC1918 block (e.g. `10.0.0.0/8` *and* `192.168.0.0/24`).
- **OTP rejected repeatedly** — Packxy stops after 4 failed attempts
  to avoid the FortiGate 5-attempt account lockout. Disconnect and
  reconnect manually when ready.
- **Menu-bar item gone after rebuild** — `pkill -f "Packxy.app"` and
  `open dist/Packxy.app` to relaunch.

## License

(unspecified)
