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

        let originalDefault = NetworkConfig.captureDefaultRoute()

        do {
            appendLog("Spawning openfortivpn…")
            let connection = try await OpenfortivpnDriver.start(config: config, otp: otp)
            wireTerminationHandler(connection.process)
            consumeDriverOutput(connection.driverOutput)
            openfortivpn = connection.process

            appendLog("ppp0 up at \(connection.ip).")

            // Undo SystemConfiguration's pppd-installed default route
            // BEFORE we add the configured routes — otherwise the
            // user's traffic to non-VPN destinations would briefly
            // tunnel through ppp0.
            NetworkConfig.restoreDefaultIfHijacked(orig: originalDefault)

            applyRoutesAndDNS(config: config)

            appendLog("Connected — \(routes.count) route(s), \(domains.count) resolver(s).")
            transition(to: .connected(ip: connection.ip, since: Date()))
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
        // Best-effort teardown of anything left over from the dead
        // process. Routes via the dead ppp0 are flushed automatically
        // by the kernel when the interface goes down, so we only
        // need to drop our memory of them.
        routes.removeAll()
        // Resolvers DO persist across openfortivpn drops (they're
        // /etc/resolver files unrelated to ppp0), so keep them in
        // place. We'll re-write them after the new tunnel to make
        // sure VPN_DNS still points at the right server.

        let originalDefault = NetworkConfig.captureDefaultRoute()

        do {
            appendLog("Spawning openfortivpn…")
            let connection = try await OpenfortivpnDriver.start(config: config, otp: otp)
            wireTerminationHandler(connection.process)
            consumeDriverOutput(connection.driverOutput)
            openfortivpn = connection.process

            appendLog("ppp0 up at \(connection.ip).")

            NetworkConfig.restoreDefaultIfHijacked(orig: originalDefault)

            applyRoutesAndDNS(config: config)

            appendLog("Reconnected — \(routes.count) route(s), \(domains.count) resolver(s).")
            transition(to: .connected(ip: connection.ip, since: Date()))
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
        appendLog("Tearing down tunnel…")
        OpenfortivpnDriver.stop()
        openfortivpn = nil

        for domain in domains {
            NetworkConfig.removeResolver(domain: domain)
            appendLog("Removed /etc/resolver/\(domain).")
        }
        domains.removeAll()
        routes.removeAll()
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

    /// Adds every configured route + resolver file. Idempotent because
    /// route(8) "File exists" is swallowed and resolver writes are
    /// overwrites.
    private func applyRoutesAndDNS(config: Config) {
        routes.removeAll()
        for cidr in config.vpnRoutes {
            do {
                try NetworkConfig.addRoute(cidr: cidr, dev: "ppp0")
                routes.append(cidr)
                appendLog("Added route \(cidr) via ppp0.")
            } catch {
                // Surface in logs but don't abort — partial route
                // installation is better than no VPN, and the user
                // sees what made it through in the menu bar.
                NSLog("packxy: addRoute %@ failed: %@", cidr, error.localizedDescription)
                appendLog("route add \(cidr) failed: \(error.localizedDescription)", kind: .warn)
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

        let reason: Reason
        if nextDropIsWake {
            nextDropIsWake = false
            reason = .wake
        } else {
            reason = OpenfortivpnDriver.classifyExitReason()
        }
        // Routes via the dead ppp0 are auto-flushed by the kernel.
        routes.removeAll()
        appendLog("openfortivpn exited (\(reason.rawValue)).", kind: .warn)
        transition(to: .dropped(reason: reason, at: Date()))
    }

    /// Spawns a child task that drains the driver's stdout/stderr
    /// AsyncStream until openfortivpn exits (EOF). Captures self
    /// weakly so a deinit during a long connect doesn't strand the
    /// task. The stream itself is bounded (500-line ring buffer in
    /// the driver) so a runaway producer can't OOM us if appendLog
    /// ever lags.
    private func consumeDriverOutput(_ stream: AsyncStream<String>) {
        Task { @MainActor [weak self] in
            for await line in stream {
                self?.appendLog(line, kind: .driver)
            }
        }
    }

    /// Appends an entry to the activity log and trims to the ring
    /// capacity. Centralised so every milestone / driver line / error
    /// goes through the same trim path.
    private func appendLog(_ message: String, kind: LogEntry.Kind = .info) {
        let entry = LogEntry(
            id: UUID(),
            timestamp: Date(),
            kind: kind,
            message: message
        )
        log.append(entry)
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
