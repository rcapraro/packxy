// openfortivpn process driver.
//
// Lifecycle:
//   1. writeConfig writes /tmp/packxy/openfortivpn.conf with the
//      user's credentials + the OTP (overwriting any previous file).
//   2. start() spawns `sudo -n openfortivpn -c <conf>
//      --pppd-call=packxy --persistent=0`, redirecting stdout/stderr
//      into /tmp/packxy/openfortivpn.log.
//   3. start() polls ifconfig(ppp0) until an IPv4 appears or the
//      process exits early. While polling it also scans the log for
//      auth-error markers so an obviously-doomed connection can be
//      aborted before the 40s ceiling.
//   4. The caller (ConnectionManager) wires up `terminationHandler`
//      on the returned Process to react to drops.
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

struct OpenfortivpnConnection {
    let process: Process
    let ip: String
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

    /// Spawns openfortivpn for the given config + OTP and waits up to
    /// 40 s for ppp0 to come up. Returns the running Process + the
    /// IPv4 assigned to ppp0 on success.
    static func start(config: Config, otp: String) async throws -> OpenfortivpnConnection {
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
        // The Process dup's the FD into the child at run() time, so
        // we can close our copy whether run() succeeded or threw —
        // either way, we don't want to hold a parent-side FD past
        // this function.
        defer { try? logHandle.close() }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        task.arguments = ["-n",
                          binPath,
                          "-c", configPath,
                          "--pppd-call=\(Installer.peerName)",
                          "--persistent=0"]
        if config.noFTMPush {
            task.arguments?.append("--no-ftm-push")
        }
        task.standardOutput = logHandle
        task.standardError = logHandle

        do {
            try task.run()
        } catch {
            throw OpenfortivpnDriverError.launchFailed(error.localizedDescription)
        }

        // Wait for ppp0 to come up. Poll every 500 ms, bail out
        // early on auth errors or process death.
        let deadline = Date().addingTimeInterval(40)
        while Date() < deadline {
            if !task.isRunning {
                // Process gave up before we saw an IP. Read the log
                // to surface a meaningful error.
                let tail = readLog().split(separator: "\n").suffix(5).joined(separator: "\n")
                throw OpenfortivpnDriverError.exitedEarly(stderr: tail)
            }
            if logContainsAuthError() {
                // Kill the doomed process so we don't pile auth
                // attempts against the FortiGate.
                stop()
                throw OpenfortivpnDriverError.authError
            }
            if let ip = NetworkConfig.interfaceIPv4("ppp0") {
                return OpenfortivpnConnection(process: task, ip: ip)
            }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        // Timed out. Kill the half-up process.
        stop()
        throw OpenfortivpnDriverError.timeout
    }

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
