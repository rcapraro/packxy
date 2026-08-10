// openfortivpn process driver.
//
// Lifecycle:
//   1. writeConfig writes /tmp/packxy/openfortivpn.conf with the
//      user's credentials + the OTP (overwriting any previous file).
//   2. start() spawns `sudo -n openfortivpn -c <conf>
//      --pppd-call=packxy --persistent=0`, capturing stdout/stderr
//      through a Pipe that tees each chunk to
//      /tmp/packxy/openfortivpn.log AND yields complete lines on an
//      AsyncStream the caller can subscribe to for live progress.
//   3. start() polls ifconfig(ppp0) until an IPv4 appears or the
//      process exits early. While polling it also scans the log for
//      auth-error markers so an obviously-doomed connection can be
//      aborted before the 40s ceiling.
//   4. The caller (ConnectionManager) wires up `terminationHandler`
//      on the returned Process to react to drops, and drains
//      `driverOutput` to surface openfortivpn's chatter to the UI.
//
// Stop is decoupled: callers SIGTERM via `pkill openfortivpn` because
// the process may outlive the Process handle (e.g. if the app
// crashes; openfortivpn was spawned through sudo so its parent is
// detached) and the sudoers drop-in is what keeps `pkill -TERM
// openfortivpn` working password-free.

import Foundation

enum OpenfortivpnDriverError: LocalizedError {
    case stateDirCreateFailed(String)
    case launchFailed(String)
    case authError
    case exitedEarly(stderr: String)
    case timeout

    var errorDescription: String? {
        switch self {
        case .stateDirCreateFailed(let s): return "Could not create state dir: \(s)"
        case .launchFailed(let s):         return "Failed to launch openfortivpn: \(s)"
        case .authError:                   return "openfortivpn rejected the credentials / OTP."
        case .exitedEarly(let s):          return "openfortivpn exited before ppp0 came up: \(s)"
        case .timeout:                     return "Timed out waiting for ppp0 to come up."
        }
    }
}

/// What the FortiGate told openfortivpn during config exchange,
/// recovered from the log because `set-routes = 0` / `set-dns = 0`
/// stop openfortivpn from acting on any of it itself.
///
/// Both source lines are emitted at INFO level, so no `-v` is needed:
///   • `Registering route <dest>/<mask> via <gw>` — from
///     add_text_route(), reached while parsing the gateway XML and so
///     independent of `set-routes`, but **gated on `pppd_ipparam`
///     starting with "openfortivpn"**, which is why start() passes
///     `--pppd-ipparam=openfortivpn`. Without that flag the line never
///     appears and its absence says nothing about the gateway.
///     With it, absence does mean the gateway sent no
///     <split-tunnel-info> — i.e. it is full-tunnel.
///   • `Got addresses: [<ppp ip>], ns [<dns>, <dns>]`.
struct GatewayFacts: Equatable {
    var dnsServers: [String] = []
    /// CIDR form ("192.168.0.0/24"), converted from the dest+netmask
    /// pair openfortivpn prints.
    var splitRoutes: [String] = []
}

/// One line of openfortivpn output, stamped when it was **read from
/// the pipe** rather than when the UI got around to logging it. The
/// difference is visible: the caller can be busy for a second or more
/// between lines arriving and being appended, and pppd embeds its own
/// clock in the text, so a drain-time stamp visibly disagrees with it.
struct DriverLine: Sendable {
    let timestamp: Date
    let text: String
}

/// A launched openfortivpn whose tunnel is not up yet.
///
/// `spawn` returns this the instant the process is running, so the
/// caller can attach a `driverOutput` consumer **before** awaiting
/// `waitForInterface`. Attaching afterwards means every line of the
/// connect sits unread in the stream's buffer and flushes in one lump
/// at the end, out of order with the caller's own progress messages.
struct OpenfortivpnSession {
    let process: Process
    /// The full argv, for the activity log. Carries no secrets — the
    /// password lives in the 0600 config file, not on the command line.
    let argv: [String]
    /// Lines streamed from the child's merged stdout+stderr for the
    /// lifetime of the process. The stream finishes when the pipe sees
    /// EOF — i.e. when openfortivpn exits. Buffered to the most recent
    /// ~500 lines so a slow consumer (or no consumer at all) can't grow
    /// unbounded.
    let driverOutput: AsyncStream<DriverLine>
    /// Retained so the failure paths in `waitForInterface` can end the
    /// stream without waiting for the pipe to EOF.
    fileprivate let continuation: AsyncStream<DriverLine>.Continuation
}

/// Mutable scratch box for the line-splitting buffer captured by
/// the pipe's readabilityHandler. A `var Data` declared in the
/// enclosing scope would also work via box-capture, but a class
/// makes the cross-invocation state visible at a glance.
private final class DriverLineBuffer {
    var data = Data()
}

enum OpenfortivpnDriver {
    /// Where the openfortivpn config + log live. Mirrors the Go
    /// implementation's `state.Dir`.
    static let stateDir = "/tmp/packxy"

    static var configPath: String { "\(stateDir)/openfortivpn.conf" }
    static var logPath: String    { "\(stateDir)/openfortivpn.log" }

    /// Regex catching auth-class failures in the openfortivpn log.
    /// Ported verbatim from `forti.authErrorRE` so we classify drops
    /// the same way the Go watcher did.
    private static let authErrorRE: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: "Could not authenticate to gateway|check the password, client certificate|Authentication failed|Invalid (password|OTP)|OTP required|Permission denied",
            options: [.caseInsensitive]
        )
    }()

    /// Launches openfortivpn for the given config + OTP and returns as
    /// soon as the process is running — it does **not** wait for the
    /// tunnel. Pair with `waitForInterface`, attaching a consumer to
    /// `session.driverOutput` in between so the connect streams live.
    static func spawn(config: Config, otp: String) throws -> OpenfortivpnSession {
        try ensureStateDir()
        try writeConfig(config: config, otp: otp)

        // Resolve openfortivpn's absolute path. sudo matches sudoers
        // entries by absolute path, and sudo's `secure_path` doesn't
        // include /opt/homebrew/bin by default on Apple Silicon — so
        // calling `sudo -n openfortivpn …` with a bare command name
        // would fail with "command not found" even though the sudoers
        // drop-in does grant it. Pass the absolute path to make the
        // resolution match the sudoers rule exactly.
        let binPath: String
        do {
            binPath = try Installer.findOpenfortivpn()
        } catch {
            throw OpenfortivpnDriverError.launchFailed("openfortivpn not found — `brew install openfortivpn`")
        }

        // Truncate the log so log-classification only sees output
        // from this run.
        FileManager.default.createFile(atPath: logPath, contents: nil, attributes: nil)

        guard let logHandle = FileHandle(forWritingAtPath: logPath) else {
            // Realistically only happens if /tmp/packxy/ has been
            // chmod'd to non-writable after `ensureStateDir()`. Throw
            // a typed error instead of crashing.
            throw OpenfortivpnDriverError.stateDirCreateFailed(
                "could not open \(logPath) for writing"
            )
        }

        // Capture stdout+stderr through a single Pipe (both stdio
        // streams of the child dup to the same write end) so we can:
        //   1. tee each chunk to /tmp/packxy/openfortivpn.log,
        //      preserving the post-mortem log file and keeping
        //      logContainsAuthError() / classifyExitReason() working.
        //   2. split chunks into complete \n-terminated lines and
        //      surface them via an AsyncStream the caller drains for
        //      live progress in the connect window.
        // logHandle's lifetime now extends past this function — the
        // readabilityHandler owns it and closes it on EOF.
        let outPipe = Pipe()
        let (driverOutput, continuation) = AsyncStream<DriverLine>.makeStream(
            bufferingPolicy: .bufferingNewest(500)
        )
        let buffer = DriverLineBuffer()
        outPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            // Stamp once per wakeup: every line in this chunk was read
            // from the pipe at the same moment.
            let readAt = Date()
            if chunk.isEmpty {
                // EOF — flush a trailing partial line if any, then
                // tear down. Both finish() and onTermination are
                // idempotent so the throw paths below can also call
                // finish() without worrying about double-close.
                if !buffer.data.isEmpty,
                   let tail = String(data: buffer.data, encoding: .utf8),
                   !tail.isEmpty {
                    continuation.yield(DriverLine(timestamp: readAt, text: tail))
                }
                buffer.data.removeAll()
                try? logHandle.close()
                handle.readabilityHandler = nil
                continuation.finish()
                return
            }
            try? logHandle.write(contentsOf: chunk)
            buffer.data.append(chunk)
            while let nl = buffer.data.firstIndex(of: 0x0A) {
                let lineData = buffer.data[buffer.data.startIndex..<nl]
                buffer.data.removeSubrange(buffer.data.startIndex...nl)
                if let line = String(data: Data(lineData), encoding: .utf8) {
                    continuation.yield(DriverLine(timestamp: readAt, text: line))
                }
            }
        }
        continuation.onTermination = { _ in
            outPipe.fileHandleForReading.readabilityHandler = nil
            try? logHandle.close()
        }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        // --pppd-ipparam=openfortivpn is what unlocks the gateway's
        // split-route announcement. openfortivpn's add_text_route()
        // (src/ipv4.c) returns early unless pppd_ipparam is non-NULL
        // and starts with the literal "openfortivpn", so without this
        // flag the `Registering route <dest>/<mask> via <gw>` lines are
        // never printed and parseGatewayFacts can never see them —
        // regardless of what the FortiGate actually pushes.
        task.arguments = ["-n",
                          binPath,
                          "-c", configPath,
                          "--pppd-call=\(Installer.peerName)",
                          "--pppd-ipparam=openfortivpn",
                          "--persistent=0"]
        if config.noFTMPush {
            task.arguments?.append("--no-ftm-push")
        }
        task.standardOutput = outPipe
        task.standardError = outPipe

        do {
            try task.run()
        } catch {
            continuation.finish()
            throw OpenfortivpnDriverError.launchFailed(error.localizedDescription)
        }

        return OpenfortivpnSession(
            process: task,
            argv: [task.executableURL?.path ?? "sudo"] + (task.arguments ?? []),
            driverOutput: driverOutput,
            continuation: continuation
        )
    }

    /// Waits up to 40 s for ppp0 to come up on an already-spawned
    /// session, then reads what the gateway announced.
    ///
    /// Bails out early on auth errors or process death. The caller
    /// should already be draining `session.driverOutput` by the time
    /// this is awaited.
    static func waitForInterface(
        _ session: OpenfortivpnSession
    ) async throws -> (ip: String, facts: GatewayFacts) {
        let task = session.process
        let deadline = Date().addingTimeInterval(40)
        while Date() < deadline {
            if !task.isRunning {
                // Process gave up before we saw an IP. Read the log
                // to surface a meaningful error.
                let tail = readLog().split(separator: "\n").suffix(5).joined(separator: "\n")
                session.continuation.finish()
                throw OpenfortivpnDriverError.exitedEarly(stderr: tail)
            }
            if logContainsAuthError() {
                // Kill the doomed process so we don't pile auth
                // attempts against the FortiGate. stop() will EOF the
                // pipe and the readabilityHandler finishes the stream;
                // don't double-finish here.
                stop()
                throw OpenfortivpnDriverError.authError
            }
            if let ip = NetworkConfig.interfaceIPv4("ppp0") {
                return (ip: ip, facts: await awaitGatewayFacts())
            }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        // Timed out. Kill the half-up process. Same finish() reasoning
        // as the authError path.
        stop()
        throw OpenfortivpnDriverError.timeout
    }

    /// `openfortivpn --version`, cached. Logged at connect so a stale
    /// running app (an `.app` bundle replaced under a live process)
    /// is visible from the log rather than needing `ps`.
    static func versionString() -> String {
        if let cached = cachedVersion { return cached }
        guard let binPath = try? Installer.findOpenfortivpn() else {
            cachedVersion = "not found"
            return "not found"
        }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: binPath)
        task.arguments = ["--version"]
        let out = Pipe()
        task.standardOutput = out
        task.standardError = Pipe()
        var version = "unknown"
        if (try? task.run()) != nil {
            let data = out.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()
            let text = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !text.isEmpty { version = text }
        }
        cachedVersion = version
        return version
    }

    private nonisolated(unsafe) static var cachedVersion: String?

    /// SIGTERMs the running openfortivpn (any of them — we identify
    /// by process name, not PID, because the actual PID lives under
    /// sudo's fork). Granted password-free by the sudoers drop-in.
    static func stop() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        task.arguments = ["-n", "/usr/bin/pkill", "-TERM", "-x", "openfortivpn"]
        // Best-effort: ignore exit code (1 means "no process found",
        // which is fine for an idempotent stop).
        try? task.run()
        task.waitUntilExit()
    }

    /// Reads the openfortivpn log and decides why the process died.
    /// Auth-class signatures (burned OTP, bad password) map to
    /// `.authExpired`; everything else is `.networkDrop` (LCP echo
    /// timeout, peer reset, link drop, …).
    static func classifyExitReason() -> Reason {
        logContainsAuthError() ? .authExpired : .networkDrop
    }

    // MARK: - Gateway facts

    private static let splitRouteRE: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: #"Registering route ([0-9.]+)/([0-9.]+) via ([0-9.]+)"#)
    }()

    private static let dnsRE: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: #"Got addresses: \[[^\]]*\], ns \[([^\]]*)\]"#)
    }()

    /// Marker openfortivpn prints once the tunnel is fully negotiated,
    /// i.e. after every fact-bearing line has been emitted.
    private static let tunnelUpMarker = "Tunnel is up and running"

    /// Reads gateway facts from the log, waiting briefly for the log
    /// to catch up.
    ///
    /// We detect "ppp0 is up" by polling ifconfig, which can observe
    /// the kernel's address assignment before openfortivpn's own
    /// `Got addresses: …` line has been drained from the pipe by the
    /// readabilityHandler and written to disk. Parsing at that instant
    /// makes the diagnostic non-deterministic: sometimes the DNS facts
    /// are there, sometimes not. Poll for up to a second instead, and
    /// stop as soon as the log looks complete.
    private static func awaitGatewayFacts() async -> GatewayFacts {
        let deadline = Date().addingTimeInterval(1.0)
        var facts = GatewayFacts()
        while true {
            let log = readLog()
            facts = parseGatewayFacts(from: log)
            // Either signal is enough: the nameservers landed, or
            // openfortivpn has moved past the point where it would
            // print any more facts.
            if !facts.dnsServers.isEmpty || log.contains(tunnelUpMarker) { break }
            if Date() >= deadline { break }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return facts
    }

    /// Extracts the gateway-pushed routes + nameservers from an
    /// openfortivpn log. Pure — no I/O — so it's cheap to call and
    /// easy to reason about.
    static func parseGatewayFacts(from log: String) -> GatewayFacts {
        var facts = GatewayFacts()
        let whole = NSRange(log.startIndex..<log.endIndex, in: log)

        splitRouteRE.enumerateMatches(in: log, range: whole) { match, _, _ in
            guard let match,
                  let destRange = Range(match.range(at: 1), in: log),
                  let maskRange = Range(match.range(at: 2), in: log),
                  let prefix = NetworkConfig.maskToPrefix(String(log[maskRange]))
            else { return }
            let cidr = "\(log[destRange])/\(prefix)"
            if !facts.splitRoutes.contains(cidr) {
                facts.splitRoutes.append(cidr)
            }
        }

        // Last match wins: on a reconnect within the same log the most
        // recent negotiation is the one that's live.
        if let match = dnsRE.matches(in: log, range: whole).last,
           let range = Range(match.range(at: 1), in: log) {
            facts.dnsServers = log[range]
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        }
        return facts
    }

    // MARK: - Private

    private static func ensureStateDir() throws {
        do {
            try FileManager.default.createDirectory(
                atPath: stateDir, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o755])
        } catch {
            throw OpenfortivpnDriverError.stateDirCreateFailed(error.localizedDescription)
        }
    }

    /// Writes /tmp/packxy/openfortivpn.conf. Mirrors
    /// `forti.writeOpenfortivpnConfig` field-by-field so an existing
    /// openfortivpn user sees identical behaviour. Permissions 0600.
    private static func writeConfig(config: Config, otp: String) throws {
        let port = config.port.isEmpty ? "443" : config.port
        var b = ""
        b += "# Generated by Packxy — split tunneling preserved.\n"
        b += "# openfortivpn does NOT add routes or modify DNS; Packxy\n"
        b += "# handles routes via route(8) and /etc/resolver itself.\n"
        b += "set-routes = 0\n"
        b += "set-dns = 0\n"
        b += "pppd-use-peerdns = 0\n"
        b += "host = \(config.host)\n"
        b += "port = \(port)\n"
        b += "username = \(config.user)\n"
        b += "password = \(config.password)\n"
        if !config.trustedCert.isEmpty {
            b += "trusted-cert = \(config.trustedCert)\n"
        }
        if !config.realm.isEmpty {
            b += "realm = \(config.realm)\n"
        }
        if !otp.isEmpty {
            b += "otp = \(otp)\n"
        }
        if !config.otpPrompt.isEmpty {
            b += "otp-prompt = \(config.otpPrompt)\n"
        }
        try b.write(toFile: configPath, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: configPath)
    }

    private static func readLog() -> String {
        (try? String(contentsOfFile: logPath, encoding: .utf8)) ?? ""
    }

    private static func logContainsAuthError() -> Bool {
        let log = readLog()
        let range = NSRange(log.startIndex..<log.endIndex, in: log)
        return authErrorRE.firstMatch(in: log, options: [], range: range) != nil
    }
}
