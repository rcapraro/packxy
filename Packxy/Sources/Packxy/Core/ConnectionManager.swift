// Connection state machine + orchestration.
//
// Replaces the Go watcher (cmd/packxy/main.go's runWatcher and
// reconnectLoop) plus the package-level orchestration in runStart.
// Owns the openfortivpn Process, the list of currently-configured
// routes / resolver domains, the wake flag, and surfaces a single
// `@Published var state: ConnectionState` to the UI.
//
// Threading: `@MainActor` because the UI binds directly to `state`
// and the route/resolver mutations are cheap enough to run on main.
// Heavy work (process spawn, ifconfig polling) is async and awaited
// off-main via the underlying Process API.

import AppKit
import Foundation
import SwiftUI

/// One line in the connect/reconnect activity log surfaced to the
/// ConnectionWindow. Carries a kind so the UI can colourise driver
/// chatter, warnings, and errors differently from Packxy's own
/// step-by-step events.
struct LogEntry: Identifiable, Equatable, Sendable {
    enum Kind: Sendable { case info, driver, warn, error }
    let id: UUID
    let timestamp: Date
    let kind: Kind
    let message: String
}

@MainActor
final class ConnectionManager: ObservableObject {

    // MARK: - Published state

    @Published private(set) var state: ConnectionState = .disconnected
    @Published private(set) var routes: [String] = []
    @Published private(set) var domains: [String] = []
    /// Last failure message surfaced by OpenfortivpnDriver, kept
    /// around so the ConnectionWindow can show what actually went
    /// wrong on `.dropped(.startupFailure)` (instead of a generic
    /// "VPN failed to start"). Cleared on connect / disconnect /
    /// any non-failure transition.
    @Published private(set) var lastError: String?

    /// Time-ordered activity log for the current connect / reconnect
    /// attempt — Packxy's own step-by-step events interleaved with
    /// openfortivpn's stdout/stderr lines. Cleared at the top of
    /// every `start()` / `reconnect()` so each attempt has a clean
    /// slate; persists through `.connected` so the user can review
    /// what happened before closing the window. Ring-buffered at 500
    /// entries so a stuck reconnect loop or chatty driver can't grow
    /// unbounded.
    @Published private(set) var log: [LogEntry] = []
    private static let logCapacity = 500

    // MARK: - Internal state

    private var openfortivpn: Process?
    /// Set when a sleep / wake event happened recently so the next
    /// drop reports `.wake` rather than `.networkDrop`.
    private var nextDropIsWake = false
    /// Long-running task that drains PowerObserver.events().
    private var powerTask: Task<Void, Never>?

    /// The subset of `routes` this process actually created — i.e. the
    /// ones `NetworkConfig.addRoute` reported as newly added rather
    /// than already present. Only these may be deleted at teardown:
    /// BSD `route delete` matches on destination+netmask and ignores
    /// the interface, so deleting a prefix we merely found in the table
    /// would tear out the host's own LAN or bridge route.
    private var installedRoutes: [String] = []

    /// Bumped on every connect / reconnect / teardown. The post-connect
    /// reachability check captures the value it was launched with and
    /// discards its results if it no longer matches, so a slow
    /// getaddrinfo from a dead connection can't spill warnings into a
    /// later attempt's freshly cleared log.
    private var connectionEpoch = 0
    /// The in-flight reachability check, cancelled whenever the
    /// connection it belongs to goes away.
    private var reachabilityTask: Task<Void, Never>?

    // MARK: - Lifecycle

    init() {
        powerTask = Task { @MainActor [weak self] in
            for await event in PowerObserver.events() {
                await self?.handlePowerEvent(event)
            }
        }
    }

    deinit {
        powerTask?.cancel()
        reachabilityTask?.cancel()
    }

    // MARK: - Public actions

    /// Initial connect. Reads everything from `config`, prompts the
    /// caller for `otp` separately because OTPs are 30s tokens not
    /// safe to persist.
    func start(config: Config, otp: String) async {
        guard case .disconnected = state else {
            // Already in flight or up — let the caller deal with it
            // explicitly via stop() first.
            return
        }
        invalidateReachabilityCheck()
        lastError = nil
        log.removeAll()
        appendLog("Connecting to \(config.host)…")

        // Re-validate install state — the user may have
        // `brew uninstall openfortivpn`-ed between the app launch and
        // now, or removed the sudoers drop-in manually. Surface a
        // pointed error rather than letting OpenfortivpnDriver throw
        // a generic launch failure.
        guard Installer.isInstalled() else {
            lastError = "Packxy components are missing. Open Settings → Installation → Reinstall (and make sure openfortivpn is still installed via Homebrew)."
            appendLog(lastError!, kind: .error)
            transition(to: .dropped(reason: .startupFailure, at: Date()))
            return
        }

        transition(to: .connecting)
        appendBuildLine()

        let originalDefault = NetworkConfig.captureDefaultRoute()

        do {
            appendLog("Spawning openfortivpn…")
            let session = try OpenfortivpnDriver.spawn(config: config, otp: otp)
            appendLog("argv: \(session.argv.joined(separator: " "))")
            // Attach the consumer BEFORE awaiting the interface, so
            // openfortivpn's own lines interleave with our milestones
            // in real time instead of flushing in one lump at the end.
            consumeDriverOutput(session.driverOutput)

            let up = try await OpenfortivpnDriver.waitForInterface(session)

            // Only now that the tunnel is up do we adopt the process:
            // wiring the termination handler earlier would race the
            // throw paths below into a duplicate `.dropped`.
            wireTerminationHandler(session.process)
            openfortivpn = session.process

            appendLog("ppp0 up at \(up.ip).")

            // Undo SystemConfiguration's pppd-installed default route
            // BEFORE we add the configured routes — otherwise the
            // user's traffic to non-VPN destinations would briefly
            // tunnel through ppp0.
            NetworkConfig.restoreDefaultIfHijacked(orig: originalDefault)

            applyRoutesAndDNS(config: config, facts: up.facts)

            appendLog("Connected — \(routes.count) route(s), \(domains.count) resolver(s).")
            transition(to: .connected(ip: up.ip, since: Date()))
            runReachabilityCheck(config: config)
        } catch let e as OpenfortivpnDriverError {
            // Spawn failed before ppp0 came up. Stash a humane message
            // for the ConnectionWindow so the user knows whether the
            // OTP was wrong, the binary's missing, sudoers is stale,
            // or the tunnel just timed out.
            openfortivpn = nil
            NSLog("packxy: start failed: %@", e.errorDescription ?? "(no description)")
            lastError = e.errorDescription
            appendLog(e.errorDescription ?? "openfortivpn failed.", kind: .error)
            let reason: Reason
            if case .authError = e { reason = .authExpired } else { reason = .startupFailure }
            transition(to: .dropped(reason: reason, at: Date()))
        } catch {
            openfortivpn = nil
            NSLog("packxy: start failed: %@", error.localizedDescription)
            lastError = error.localizedDescription
            appendLog(error.localizedDescription, kind: .error)
            transition(to: .dropped(reason: .startupFailure, at: Date()))
        }
    }

    /// Reconnect after a drop. Same as start() but updates state
    /// transitions for the UI (.reconnecting vs .connecting).
    func reconnect(config: Config, otp: String) async {
        invalidateReachabilityCheck()
        lastError = nil
        log.removeAll()
        appendLog("Reconnecting to \(config.host)…")

        // Same paranoid re-check as start(): components may have
        // moved between drop and reconnect (very unlikely but
        // bookkeeping is cheap).
        guard Installer.isInstalled() else {
            lastError = "Packxy components are missing. Open Settings → Installation → Reinstall."
            appendLog(lastError!, kind: .error)
            transition(to: .dropped(reason: .startupFailure, at: Date()))
            return
        }

        transition(to: .reconnecting)
        appendBuildLine()
        // Best-effort teardown of anything left over from the dead
        // process. The kernel flushes ppp0's routes when the interface
        // goes down, but openfortivpn can die with pppd (and ppp0)
        // still up — and the next attempt only re-adds what's in the
        // *current* VPN_ROUTES, so a CIDR the user has since removed
        // would linger forever pointing at a stale interface.
        purgeInstalledRoutes()
        // Resolvers DO persist across openfortivpn drops (they're
        // /etc/resolver files unrelated to ppp0), so keep them in
        // place. We'll re-write them after the new tunnel to make
        // sure VPN_DNS still points at the right server.

        let originalDefault = NetworkConfig.captureDefaultRoute()

        do {
            appendLog("Spawning openfortivpn…")
            let session = try OpenfortivpnDriver.spawn(config: config, otp: otp)
            appendLog("argv: \(session.argv.joined(separator: " "))")
            consumeDriverOutput(session.driverOutput)

            let up = try await OpenfortivpnDriver.waitForInterface(session)

            wireTerminationHandler(session.process)
            openfortivpn = session.process

            appendLog("ppp0 up at \(up.ip).")

            NetworkConfig.restoreDefaultIfHijacked(orig: originalDefault)

            applyRoutesAndDNS(config: config, facts: up.facts)

            appendLog("Reconnected — \(routes.count) route(s), \(domains.count) resolver(s).")
            transition(to: .connected(ip: up.ip, since: Date()))
            runReachabilityCheck(config: config)
        } catch let e as OpenfortivpnDriverError {
            NSLog("packxy: reconnect failed: %@", e.errorDescription ?? "(no description)")
            lastError = e.errorDescription
            appendLog(e.errorDescription ?? "openfortivpn failed.", kind: .error)
            let reason: Reason
            if case .authError = e { reason = .authExpired } else { reason = .startupFailure }
            transition(to: .dropped(reason: reason, at: Date()))
        } catch {
            NSLog("packxy: reconnect failed: %@", error.localizedDescription)
            lastError = error.localizedDescription
            appendLog(error.localizedDescription, kind: .error)
            transition(to: .dropped(reason: .startupFailure, at: Date()))
        }
    }

    /// User-initiated teardown.
    func stop() async {
        invalidateReachabilityCheck()
        appendLog("Tearing down tunnel…")
        OpenfortivpnDriver.stop()
        openfortivpn = nil

        for domain in domains {
            NetworkConfig.removeResolver(domain: domain)
            appendLog("Removed /etc/resolver/\(domain).")
        }
        domains.removeAll()
        purgeInstalledRoutes()
        lastError = nil

        appendLog("Disconnected.")
        transition(to: .disconnected)
    }

    // MARK: - Internals

    /// Single funnel for every `state` mutation. Surfaces the new
    /// state to the UI (via @Published) AND fires the matching
    /// notification side-effects so the menu bar + Notification
    /// Center stay in lockstep.
    ///
    /// Notification rules:
    ///   • → .dropped         : post drop banner.
    ///   • from .dropped or
    ///     .reconnecting → .connected
    ///                         : clear stale drop banner + post
    ///                           "✓ VPN reconnected".
    ///   • → .authLocked      : post the lockout warning.
    ///   • → .connecting / .reconnecting / .connected (initial) /
    ///     .disconnected      : silent — no banner.
    ///
    /// Initial connects don't fire a success notification because
    /// the user is staring at the Connect window and gets the
    /// confirmation there; banners are reserved for changes the user
    /// might not be actively watching.
    private func transition(to newState: ConnectionState) {
        let previous = state
        state = newState

        switch newState {
        case .dropped(let reason, _):
            Notifications.shared.dropOccurred(reason: reason)
        case .connected:
            let wasInDropFlow: Bool = {
                switch previous {
                case .dropped, .reconnecting: return true
                default: return false
                }
            }()
            if wasInDropFlow {
                Notifications.shared.clearDelivered()
                Notifications.shared.reconnectSucceeded()
            }
        case .authLocked:
            Notifications.shared.authLocked()
        default:
            break
        }
    }

    /// Adds every configured route + resolver file, plus any split
    /// routes the gateway pushed. Idempotent: a route that already
    /// exists is left alone and resolver writes are overwrites.
    ///
    /// `facts` is what the FortiGate announced. We report it verbatim
    /// because `set-routes = 0` / `set-dns = 0` mean openfortivpn
    /// silently discards it — and a mismatch between what the gateway
    /// says and what the user configured is the single most common
    /// cause of "it resolves but I can't reach it".
    private func applyRoutesAndDNS(config: Config, facts: GatewayFacts) {
        if !facts.dnsServers.isEmpty {
            appendLog("Gateway pushed DNS \(facts.dnsServers.joined(separator: ", ")).")
            if !config.vpnDNS.isEmpty, !facts.dnsServers.contains(config.vpnDNS) {
                appendLog("Configured VPN_DNS \(config.vpnDNS) is not among the gateway's nameservers.",
                          kind: .warn)
            }
        }

        routes.removeAll()
        installedRoutes.removeAll()
        for cidr in config.vpnRoutes {
            addRoute(cidr, label: "route")
        }

        // Adopt gateway-pushed split routes. A FortiGate configured for
        // split tunnelling sends <split-tunnel-info>; a full-tunnel one
        // sends nothing, which is precisely why VPN_ROUTES has to be
        // maintained by hand — so say that out loud rather than
        // staying silent. This reading is only trustworthy because
        // start() passes --pppd-ipparam=openfortivpn; without it
        // openfortivpn never prints the routes at all.
        if facts.splitRoutes.isEmpty {
            appendLog("Gateway pushed no split routes (full-tunnel gateway) — using configured VPN_ROUTES only.")
        } else {
            for cidr in facts.splitRoutes where !routes.contains(cidr) {
                guard NetworkConfig.isAcceptableGatewayRoute(cidr) else {
                    // A pushed 0.0.0.0/0 (or the 0.0.0.0/1 +
                    // 128.0.0.0/1 half-internet pair) installed against
                    // ppp0 is a full tunnel — the exact outcome the
                    // four locks exist to prevent. Refuse and say so.
                    appendLog("Ignoring gateway route \(cidr): broader than a /\(NetworkConfig.minimumGatewayPrefix), "
                              + "installing it would full-tunnel all traffic. Add a narrower CIDR to VPN_ROUTES if you need it.",
                              kind: .warn)
                    continue
                }
                addRoute(cidr, label: "gateway route")
            }
        }

        domains.removeAll()
        if config.hasSplitDNS {
            for domain in config.vpnDomains {
                do {
                    try NetworkConfig.writeResolver(domain: domain, dns: config.vpnDNS)
                    domains.append(domain)
                    appendLog("Wrote /etc/resolver/\(domain) → \(config.vpnDNS).")
                } catch {
                    NSLog("packxy: writeResolver %@ failed: %@", domain, error.localizedDescription)
                    appendLog("/etc/resolver/\(domain) write failed: \(error.localizedDescription)", kind: .warn)
                }
            }
        }
    }

    /// Installs one CIDR against ppp0 and records it. A CIDR that was
    /// already in the table counts as covered (so it shows in the menu
    /// bar) but is deliberately NOT recorded in `installedRoutes` —
    /// we must not delete a route we didn't create.
    ///
    /// Failures are logged and swallowed: partial route installation
    /// beats no VPN, and the user sees what made it through.
    private func addRoute(_ cidr: String, label: String) {
        do {
            let created = try NetworkConfig.addRoute(cidr: cidr, dev: "ppp0")
            routes.append(cidr)
            if created {
                installedRoutes.append(cidr)
                appendLog("Added \(label) \(cidr) via ppp0.")
            } else {
                appendLog("\(label.capitalized) \(cidr) already present — left as is.")
            }
        } catch {
            NSLog("packxy: addRoute %@ (%@) failed: %@", cidr, label, error.localizedDescription)
            appendLog("route add \(cidr) (\(label)) failed: \(error.localizedDescription)", kind: .warn)
        }
    }

    /// Deletes every route this process created and clears the route
    /// bookkeeping. Safe to call repeatedly.
    private func purgeInstalledRoutes() {
        for cidr in installedRoutes {
            if let reason = NetworkConfig.removeRoute(cidr: cidr, dev: "ppp0") {
                NSLog("packxy: removeRoute %@ failed: %@", cidr, reason)
                appendLog("route delete \(cidr) failed: \(reason)", kind: .warn)
            }
        }
        installedRoutes.removeAll()
        routes.removeAll()
    }

    /// Invalidates any in-flight reachability check so its results are
    /// dropped rather than logged against a different connection.
    private func invalidateReachabilityCheck() {
        connectionEpoch &+= 1
        reachabilityTask?.cancel()
        reachabilityTask = nil
    }

    /// Resolves every `VPN_TEST_HOSTS` entry and warns about any
    /// address no installed route covers — the failure this whole
    /// feature exists for: DNS answers correctly, the packets then
    /// leave via the host default route and die there.
    ///
    /// Runs detached and after the `.connected` transition so it never
    /// delays the connect: getaddrinfo(3) blocks, sometimes for
    /// seconds, and must stay off the main actor.
    ///
    /// It retries, because mDNSResponder adopts a freshly written
    /// /etc/resolver/<domain> asynchronously and may still be serving
    /// a pre-connect cache entry. Resolving immediately would measure
    /// the *public* resolver's answer — split-horizon DNS hands back
    /// the internet-facing address, or a stale NXDOMAIN — and produce
    /// a confidently wrong warning. Only a finding that survives to
    /// the last attempt is reported.
    private func runReachabilityCheck(config: Config) {
        let hosts = config.vpnTestHosts
        guard !hosts.isEmpty else { return }
        let cidrs = routes
        let epoch = connectionEpoch

        // Announce synchronously, before the 2 s wait. Otherwise the
        // log visibly stops at the last driver line and the user can't
        // tell whether a check is pending, passed, or never ran.
        appendLog("Reachability check: resolving \(hosts.count) host(s)…")

        reachabilityTask = Task.detached(priority: .utility) { [weak self] in
            let attempts = 3
            var collected: [Uncovered] = []
            var missing: [String] = []
            var reachable: [Covered] = []

            for attempt in 1...attempts {
                // Give mDNSResponder time to notice the resolver files
                // before the first lookup, and again between retries.
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                if Task.isCancelled { return }

                collected = []
                missing = []
                reachable = []
                for host in hosts {
                    let addresses = NetworkConfig.resolveIPv4(host)
                    if addresses.isEmpty {
                        missing.append(host)
                        continue
                    }
                    for ip in addresses {
                        if let cidr = NetworkConfig.coveringCIDR(ip, cidrs: cidrs) {
                            reachable.append(Covered(host: host, ip: ip, cidr: cidr))
                        } else {
                            collected.append(Uncovered(host: host, ip: ip,
                                                       suggestion: NetworkConfig.suggestedCIDR(for: ip)))
                        }
                    }
                }
                // Clean run — report the successes and stop early.
                if collected.isEmpty && missing.isEmpty { break }
                if attempt == attempts { break }
            }

            if Task.isCancelled { return }
            // Freeze before crossing the actor hop — mutable locals
            // can't be captured by a concurrently-executing closure.
            let findings = collected
            let unresolved = missing
            let ok = reachable
            await self?.reportReachability(covered: ok, unresolved: unresolved,
                                           findings: findings, cidrs: cidrs, epoch: epoch)
        }
    }

    /// One uncovered `host → ip` pair found by the reachability check.
    /// `suggestion` is nil when the address isn't RFC1918 — see
    /// `NetworkConfig.suggestedCIDR`.
    private struct Uncovered: Sendable {
        let host: String
        let ip: String
        let suggestion: String?
    }

    /// A `host → ip` that an installed route does cover, and which one.
    private struct Covered: Sendable {
        let host: String
        let ip: String
        let cidr: String
    }

    /// MainActor half of `runReachabilityCheck` — the only part that
    /// touches `log`. Drops everything if the connection it was
    /// launched for is gone.
    private func reportReachability(covered ok: [Covered], unresolved: [String],
                                    findings: [Uncovered],
                                    cidrs: [String], epoch: Int) {
        guard epoch == connectionEpoch else { return }
        let covered = cidrs.isEmpty ? "none" : cidrs.joined(separator: ", ")
        for entry in ok {
            appendLog("Reachability: \(entry.host) → \(entry.ip) covered by \(entry.cidr).")
        }
        for host in unresolved {
            appendLog("\(host) did not resolve — check VPN_DNS and the /etc/resolver domains.",
                      kind: .warn)
        }
        for finding in findings {
            if let suggestion = finding.suggestion {
                appendLog(
                    "\(finding.host) → \(finding.ip) is not covered by VPN_ROUTES (\(covered)). "
                    + "Add \(suggestion) in Settings → Split tunneling.",
                    kind: .warn)
            } else {
                // Public address: the lookup was answered outside the
                // internal zone. Routing that prefix into the tunnel
                // would hijack unrelated traffic, so point at the
                // actual cause instead of suggesting a CIDR.
                appendLog(
                    "\(finding.host) → \(finding.ip) is a public address, so this lookup was not answered "
                    + "by the VPN DNS. Check /etc/resolver/<domain> and VPN_DOMAINS rather than adding a route.",
                    kind: .warn)
            }
        }
    }

    /// Attaches a termination handler that flips state to `.dropped`
    /// when openfortivpn exits unexpectedly. Called from a background
    /// queue, so we hop back to MainActor for the state mutation.
    private func wireTerminationHandler(_ process: Process) {
        process.terminationHandler = { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleProcessExit(process)
            }
        }
    }

    /// Decides which `Reason` to attach when openfortivpn dies.
    private func handleProcessExit(_ deadProcess: Process) {
        // If the user called stop() explicitly we've already moved
        // through `.disconnected`; don't drag the state back to
        // `.dropped`.
        if case .disconnected = state { return }

        // Ignore stale terminationHandler callbacks (e.g. a previous
        // openfortivpn dying after we already launched a new one).
        if let live = openfortivpn, live !== deadProcess { return }
        openfortivpn = nil
        invalidateReachabilityCheck()

        let reason: Reason
        if nextDropIsWake {
            nextDropIsWake = false
            reason = .wake
        } else {
            reason = OpenfortivpnDriver.classifyExitReason()
        }
        // Normally the kernel has already flushed these along with
        // ppp0; purge explicitly for the case where pppd outlived
        // openfortivpn and the interface is still up.
        purgeInstalledRoutes()
        appendLog("openfortivpn exited (\(reason.rawValue)).", kind: .warn)
        transition(to: .dropped(reason: reason, at: Date()))
    }

    /// Spawns a child task that drains the driver's stdout/stderr
    /// AsyncStream until openfortivpn exits (EOF). Captures self
    /// weakly so a deinit during a long connect doesn't strand the
    /// task. The stream itself is bounded (500-line ring buffer in
    /// the driver) so a runaway producer can't OOM us if appendLog
    /// ever lags.
    private func consumeDriverOutput(_ stream: AsyncStream<DriverLine>) {
        Task { @MainActor [weak self] in
            for await line in stream {
                self?.appendLog(line.text,
                                kind: Self.kind(forDriverLine: line.text),
                                timestamp: line.timestamp)
            }
        }
    }

    /// openfortivpn warnings that are expected on every healthy macOS
    /// connect and must stay grey. Painting these orange would put a
    /// warning on every single successful connection, which trains the
    /// user to ignore the colour entirely.
    ///
    /// `Removing wrong route to vpn server` comes from
    /// `ipv4_drop_wrong_route` (openfortivpn src/ipv4.c), called
    /// unconditionally from `on_ppp_if_up` — *"Drop invalid route by
    /// pppd (or tun) in all cases"*. It deletes the /32 to the gateway
    /// that pppd pointed at ppp0, which would otherwise route the
    /// tunnel's own TLS traffic into the tunnel. Desirable, not a fault.
    private static let benignDriverWarnings = [
        "Removing wrong route to vpn server",
    ]

    /// Maps an openfortivpn output line to a log severity. Without
    /// this every line renders `.driver` grey, so the one line that
    /// explains a failed connect is the least visible thing on screen.
    private static func kind(forDriverLine text: String) -> LogEntry.Kind {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("ERROR:") { return .error }
        if trimmed.hasPrefix("WARN:") {
            return benignDriverWarnings.contains(where: trimmed.contains) ? .driver : .warn
        }
        return .driver
    }

    /// One line naming the running build, logged at every connect.
    /// Replacing Packxy.app does not restart a live instance, so
    /// "am I testing the binary I just built?" needs to be answerable
    /// from the log itself.
    private func appendBuildLine() {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        appendLog("Packxy \(version) · openfortivpn \(OpenfortivpnDriver.versionString())")
    }

    /// Appends an entry to the activity log and trims to the ring
    /// capacity. Centralised so every milestone / driver line / error
    /// goes through the same trim path.
    ///
    /// `timestamp` defaults to now but driver lines pass the moment
    /// they were read from the pipe, which can be earlier than the
    /// moment they reach here. The insert therefore walks back over
    /// any later entries so the log stays chronological; the strict
    /// `>` keeps insertion order for equal timestamps, and the scan is
    /// normally zero iterations because entries arrive in order.
    private func appendLog(_ message: String,
                           kind: LogEntry.Kind = .info,
                           timestamp: Date = Date()) {
        let entry = LogEntry(
            id: UUID(),
            timestamp: timestamp,
            kind: kind,
            message: message
        )
        var index = log.count
        while index > 0, log[index - 1].timestamp > timestamp {
            index -= 1
        }
        log.insert(entry, at: index)
        if log.count > Self.logCapacity {
            log.removeFirst(log.count - Self.logCapacity)
        }
    }

    /// Reacts to sleep / wake events. Pre-emptively kills openfortivpn
    /// on sleep so the FortiGate session is released cleanly and the
    /// PID-poll loop doesn't have to wait through the LCP echo
    /// timeout after wake.
    private func handlePowerEvent(_ event: PowerEvent) async {
        switch event {
        case .willSleep:
            nextDropIsWake = true
            if case .connected = state {
                OpenfortivpnDriver.stop()
                // terminationHandler fires asynchronously and will
                // flip state to .dropped(reason: .wake).
            }
        case .didWake:
            // The proactive pkill on sleep usually means the
            // terminationHandler has already fired. Still set the
            // wake flag in case the system didn't sleep deeply
            // enough for the pre-stop to actually run.
            nextDropIsWake = true
        }
    }
}
