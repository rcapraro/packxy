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

Teardown only removes what Packxy created. A CIDR that was already in
the routing table counts as covered but is never deleted: BSD
`route delete` matches on the destination and ignores the interface, so
tearing down a merely-present prefix would rip out the host's own LAN
route. The purge runs on reconnect and on an unexpected openfortivpn
exit too, not just on **Disconnect**.

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
6. **Save** (⌘S) in the bar at the bottom of the pane.

Optional: **General → Launch Packxy at login** registers the app via
`SMAppService`; macOS will prompt once in System Settings → Login Items
to confirm.

### The Settings window

A sidebar of four panes, with the running version pinned at the bottom
of it so you always know which build you're configuring:

- **General** — *Startup*: the **Launch Packxy at login** toggle. If
  macOS wants confirmation, an *Approval needed* section appears with
  an **Open Login Items** button; the toggle reverts if registration
  fails, so it never claims more than launchd actually has.
- **Installation** — *Status*: installed / missing, plus the resolved
  paths of `/etc/sudoers.d/packxy`, `/etc/ppp/peers/packxy`, the
  `openfortivpn` binary (red if Homebrew hasn't got it) and
  `~/.config/packxy.conf`, each with a reveal-in-Finder button.
  *Actions*: **Install…**, or **Reinstall…** / **Uninstall…** once
  installed.
- **Connection** — *Gateway*: host, port. *Credentials*: username and
  password, the latter with a show/hide eye so you can check what's
  stored. *Advanced*: trusted cert (sha256 fingerprint), FortiGate
  realm, a **Disable FTM push** toggle, and an OTP-prompt override for
  gateways whose prompt wording openfortivpn doesn't match.
- **Split tunneling** — *Routes*: the `VPN_ROUTES` list, add/remove,
  with a CIDR-shape check on input. *Split DNS*: the internal resolver
  address and the domains it answers for, each written to
  `/etc/resolver/<domain>`. *Reachability check*: the `VPN_TEST_HOSTS`
  hostnames re-resolved after every connect.

Connection and Split tunneling edit the config file, so they share a
save bar: an orange **Unsaved** dot whenever the in-memory config
differs from disk, **Revert** (⌘Z) and **Save** (⌘S). General and
Installation act immediately and carry no bar.

## Use

- Packxy opens the connect window by itself at launch, so the OTP
  prompt is the first thing you see. It stays quiet when a session is
  already up, and when macOS started Packxy as a login item — then you
  get the menu-bar icon only.
- Otherwise: click the menu-bar shield → **Connect…** (⌘K) → enter the
  6-digit 2FA code from your authenticator → **Connect**. The window
  then shows the live activity log, and stays open until you close it.
- The menu bar shows the live state (`🟢 Connected · 10.x.x.x` /
  `🔴 Disconnected · 5m ago` / etc.) plus the active routes & split
  DNS domains. When the components aren't installed, or host / username
  / password aren't all set, it says so there and greys out
  **Connect…** rather than letting you walk into a certain failure.
- On drop (auth expired, network blip, wake from sleep), Packxy posts
  a notification and reopens the OTP prompt with a reason-tailored
  title.
- **Disconnect** (⌘D) from the menu bar tears down `ppp0`, removes the
  configured resolvers, and returns to a clean state.
- While a Packxy window is open the app takes a Dock tile and a ⌘-Tab
  entry so it can come forward and accept keystrokes like any normal
  app; it drops back to menu-bar-only once the last window closes.
  Quitting with a live tunnel — ⌘Q, the Dock menu or **Quit Packxy** —
  asks to confirm, then tears down routes and resolvers before the
  process exits. Logout and restart skip the prompt and tear down
  silently, so Packxy can't stall a shutdown behind a dialog.

### The connect window

One window whose contents follow the connection state, with the OTP
field focused on open and on every re-prompt so the cursor is always
where you're about to type:

- **Disconnected** — the 2FA field (non-digits stripped, capped at six)
  under a hint that counts you in (`4/6 digits…` → `Press Return to
  submit.`), with **Close** and **Connect**.
- **Connecting / reconnecting** — a spinner and the live activity log
  below it.
- **Connected** — a green check, "You can close this window", and the
  log of the attempt. Nothing dismisses it but you; the live status
  lives in the menu bar from here on.
- **After a drop** — the same form, retitled with the reason (auth
  expired, network drop, wake from sleep) so it matches the
  notification you just got. **Cancel** tears the tunnel down rather
  than leaving resolvers pointed at an unreachable DNS server;
  **Reconnect** retries with a fresh code. A failed attempt keeps the
  openfortivpn error in a red row above the log.
- **After four rejected codes** — a dead end explaining that Packxy
  stopped on purpose, to stay clear of the FortiGate's five-attempt
  account lockout.

### Activity log

The connect window carries a timestamped log of the attempt. Packxy's
own milestones interleave in real time with openfortivpn's output —
driver lines are stamped when they're read from the pipe, so the
chronology holds even when a line reaches the UI late. `WARN:` renders
orange and `ERROR:` red, except for the `Removing wrong route to vpn
server` warning that appears on every healthy macOS connect, which is
deliberately left grey (see *Troubleshooting*).

```
15:04:01  Connecting to vpn.example.com…
15:04:01  Packxy 3.2.2 · openfortivpn 1.24.1
15:04:01  Spawning openfortivpn…
15:04:01  argv: /usr/bin/sudo -n /opt/homebrew/bin/openfortivpn -c …
15:04:06  ppp0 up at 10.211.0.42.
15:04:06  Gateway pushed DNS 10.0.0.1, 10.0.0.2.
15:04:06  Gateway pushed no split routes (full-tunnel gateway) — using configured VPN_ROUTES only.
15:04:06  Added route 10.0.0.0/8 via ppp0.
15:04:06  Added route 172.16.0.0/12 via ppp0.
15:04:06  Wrote /etc/resolver/internal.example.com → 10.0.0.1.
15:04:06  Connected — 2 route(s), 1 resolver(s).
15:04:07  Reachability check: resolving 1 host(s)…
15:04:08  Reachability: db.internal.example.com → 10.4.0.9 covered by 10.0.0.0/8.
```

The build line is logged on every attempt because replacing
`Packxy.app` does not restart a running instance — it answers "am I
looking at the binary I just built?". The `argv:` line carries no
secrets: the password lives in the 0600
`/tmp/packxy/openfortivpn.conf`, never on the command line. For the
raw, unfiltered stream see `/tmp/packxy/openfortivpn.log`.

### Reachability check

`VPN_TEST_HOSTS` (Settings → Split tunneling → *Reachability check*) is
a list of hostnames Packxy resolves after every connect. It exists for
the one failure a split tunnel cannot report on its own: the name
resolves fine, the address it returns falls outside every installed
route, so the packets leave through the host's default route and die
there with nothing in any log.

The check is **purely diagnostic** — it never adds a route, never
touches DNS, and never fails a connect. An empty list skips it.

It runs after the tunnel is up, on a background thread, so it never
delays the connect: `getaddrinfo(3)` can block for seconds. It waits
~2 s and retries up to three times, because mDNSResponder adopts a
freshly written `/etc/resolver/<domain>` asynchronously — the first
lookup can still be answered from the public resolver's cache, which
under split-horizon DNS hands back the internet-facing address and
would produce a confidently wrong warning. Only a finding that survives
the last attempt is reported, so a verdict can take a few seconds to
land in the log.

Addresses are matched against every route actually installed — the
configured `VPN_ROUTES` plus any gateway-pushed split routes Packxy
adopted — and only IPv4 is resolved. Each host lands on one of four
verdicts:

```
Reachability: db.internal.example.com → 10.4.0.9 covered by 10.0.0.0/8.
db.internal.example.com → 192.168.0.240 is not covered by VPN_ROUTES (10.0.0.0/8, 172.16.0.0/12). Add 192.168.0.0/24 in Settings → Split tunneling.
db.internal.example.com → 203.0.113.7 is a public address, so this lookup was not answered by the VPN DNS. Check /etc/resolver/<domain> and VPN_DOMAINS rather than adding a route.
db.internal.example.com did not resolve — check VPN_DNS and the /etc/resolver domains.
```

The first is the pass, and names the CIDR that covers the host. The
second is a routing gap: the suggestion is the `/24` around the
address, so copy it into *Routes*. The third is deliberately **not** a
route suggestion — a public answer means the lookup never reached the
VPN DNS, and routing a public `/24` into the tunnel would turn a DNS
misconfiguration into permanent traffic hijacking. The fourth means no
answer at all, which points at `VPN_DNS` or the `VPN_DOMAINS` resolver
files rather than at routing.

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
# Optional: hostnames checked after each connect — see Reachability check.
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
                              WindowActivation, AppDelegate,
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
- **A hostname resolves but the host is unreachable** — the address it
  answers with isn't inside any installed route, so the packets leave
  via the host's default route and are dropped. Add the host to
  *Split tunneling → Reachability check* and reconnect: the log will
  name the CIDR to add (see *Reachability check* above). Corporate
  networks frequently span more than one RFC1918 block — e.g.
  `10.0.0.0/8` *and* `192.168.0.0/24`.
- **Packxy has a Dock icon all of a sudden** — expected. The app is an
  `LSUIElement` agent, the weakest claimant under macOS' cooperative
  activation model, and a window opened from that state lands behind
  whatever had focus and never gets keystrokes. Packxy therefore
  becomes a regular app for as long as a window is on screen, and
  reverts to menu-bar-only when the last one closes.
- **OTP rejected repeatedly** — Packxy stops after 4 failed attempts
  to avoid the FortiGate 5-attempt account lockout. Disconnect and
  reconnect manually when ready.
- **Menu-bar item gone after rebuild** — `pkill -f "Packxy.app"` and
  `open dist/Packxy.app` to relaunch.

## License

(unspecified)
