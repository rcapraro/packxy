// macOS network-side helpers used by ConnectionManager:
//
//   • addRoute / removeRoute      — route(8) entries via sudo -n
//   • writeResolver / removeResolver — /etc/resolver/<domain> files
//   • captureDefaultRoute / restoreDefaultIfHijacked — preserve the
//     host default route after openfortivpn brings ppp0 up
//
// All operations rely on the sudoers drop-in installed by
// Installer.install(): /sbin/route, /usr/bin/tee /etc/resolver/*,
// /bin/rm -f /etc/resolver/*, /bin/mkdir -p /etc/resolver. Without
// that drop-in `sudo -n` would prompt for a password (impossible
// from a GUI app) and every call here would fail.

import Foundation

enum NetworkConfigError: LocalizedError {
    case routeFailed(cidr: String, stderr: String)
    case resolverFailed(domain: String, stderr: String)
    case routeQueryFailed

    var errorDescription: String? {
        switch self {
        case .routeFailed(let cidr, let stderr):
            return "route add \(cidr) failed: \(stderr)"
        case .resolverFailed(let domain, let stderr):
            return "/etc/resolver/\(domain) write failed: \(stderr)"
        case .routeQueryFailed:
            return "Could not query the default route."
        }
    }
}

struct DefaultRoute: Equatable {
    var gateway: String
    var iface: String
}

enum NetworkConfig {

    // MARK: - Routes

    /// Adds `<cidr> via <dev>`. Idempotent at the kernel level: a
    /// duplicate add returns "File exists" which we swallow.
    @discardableResult
    static func addRoute(cidr: String, dev: String) throws -> Bool {
        let result = runSudo(["/sbin/route", "-q", "add", "-net", cidr, "-interface", dev])
        if result.code == 0 { return true }
        // "File exists" means the route is already in the table —
        // that's the goal, return success rather than alarm callers.
        if result.stderr.contains("File exists") || result.stdout.contains("File exists") {
            return true
        }
        throw NetworkConfigError.routeFailed(cidr: cidr, stderr: result.stderr.isEmpty ? result.stdout : result.stderr)
    }

    // MARK: - Split DNS

    /// Creates /etc/resolver/<domain> with body `nameserver <dns>`.
    static func writeResolver(domain: String, dns: String) throws {
        // First make sure /etc/resolver exists. Granted by sudoers.
        _ = runSudo(["/bin/mkdir", "-p", "/etc/resolver"])

        let body = "nameserver \(dns)\n"
        let path = "/etc/resolver/\(domain)"

        // tee writes stdin to the target. We feed body via stdin and
        // discard stdout (it echoes the body — useless here).
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        task.arguments = ["-n", "/usr/bin/tee", path]

        let stdin = Pipe()
        let stderr = Pipe()
        task.standardInput = stdin
        // Discard stdout (tee echoes the body, useless here) by
        // routing it to /dev/null — avoids the pipe-fill deadlock
        // window with waitUntilExit().
        task.standardOutput = nil
        task.standardError = stderr

        try task.run()
        stdin.fileHandleForWriting.write(body.data(using: .utf8) ?? Data())
        try? stdin.fileHandleForWriting.close()

        // Drain stderr asynchronously to avoid buffer-fill deadlock.
        var errData = Data()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            errData = stderr.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        task.waitUntilExit()
        group.wait()

        if task.terminationStatus != 0 {
            let err = String(data: errData, encoding: .utf8) ?? ""
            throw NetworkConfigError.resolverFailed(domain: domain, stderr: err.isEmpty ? "exit \(task.terminationStatus)" : err)
        }
    }

    /// Deletes /etc/resolver/<domain> if present. Missing file is a
    /// non-error.
    static func removeResolver(domain: String) {
        let path = "/etc/resolver/\(domain)"
        guard FileManager.default.fileExists(atPath: path) else { return }
        _ = runSudo(["/bin/rm", "-f", path])
    }

    // MARK: - Default-route preservation
    //
    // Background: macOS' SystemConfiguration / pppd installs a new
    // default route via ppp0 when the interface comes up — full-tunnel
    // mode — even with pppd's `nodefaultroute` option. The Go code
    // works around this by capturing the original default BEFORE
    // openfortivpn starts and restoring it AFTER ppp0 is up but
    // before announcing "connected". We mirror that exactly.

    /// Reads the current default route via `route -n get default`.
    /// Returns nil if there's no default route (probably offline) or
    /// the command fails.
    static func captureDefaultRoute() -> DefaultRoute? {
        let result = runSync(["/sbin/route", "-n", "get", "default"])
        guard result.code == 0 else { return nil }
        var gateway = ""
        var iface = ""
        for line in result.stdout.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("gateway:") {
                gateway = String(trimmed.dropFirst("gateway:".count)).trimmingCharacters(in: .whitespaces)
            } else if trimmed.hasPrefix("interface:") {
                iface = String(trimmed.dropFirst("interface:".count)).trimmingCharacters(in: .whitespaces)
            }
        }
        guard !iface.isEmpty else { return nil }
        return DefaultRoute(gateway: gateway, iface: iface)
    }

    /// If the current default route now points at `pppDev` while
    /// `orig` recorded a different interface, restore the original
    /// default. Idempotent: a no-op when nothing was hijacked.
    static func restoreDefaultIfHijacked(orig: DefaultRoute?, pppDev: String = "ppp0") {
        guard let orig = orig, orig.iface != pppDev else { return }
        guard let current = captureDefaultRoute(), current.iface == pppDev else {
            // Nothing was hijacked, nothing to restore.
            return
        }
        _ = runSudo(["/sbin/route", "-q", "delete", "default"])
        if !orig.gateway.isEmpty {
            _ = runSudo(["/sbin/route", "-q", "add", "-net", "default", orig.gateway, "-interface", orig.iface])
        } else {
            _ = runSudo(["/sbin/route", "-q", "add", "-net", "default", "-interface", orig.iface])
        }
    }

    // MARK: - Interface query

    /// Returns the first IPv4 assigned to `iface`, or nil if the
    /// interface is absent / has no inet entry. Wraps ifconfig
    /// because the BSD getifaddrs(3) plumbing in Swift is noisier
    /// than it's worth for one address lookup once a second.
    static func interfaceIPv4(_ iface: String) -> String? {
        let result = runSync(["/sbin/ifconfig", iface])
        guard result.code == 0 else { return nil }
        for line in result.stdout.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("inet ") else { continue }
            let fields = trimmed.split(separator: " ")
            if fields.count >= 2 {
                // "inet 10.212.134.220 --> 10.212.134.1 …" → fields[1]
                return String(fields[1])
            }
        }
        return nil
    }

    // MARK: - Process helpers

    fileprivate struct RunResult {
        var code: Int32
        var stdout: String
        var stderr: String
    }

    /// Runs `sudo -n <argv>` and captures stdout/stderr.
    fileprivate static func runSudo(_ argv: [String]) -> RunResult {
        runSync(["/usr/bin/sudo", "-n"] + argv)
    }

    fileprivate static func runSync(_ argv: [String]) -> RunResult {
        guard let first = argv.first else { return RunResult(code: -1, stdout: "", stderr: "empty argv") }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: first)
        task.arguments = Array(argv.dropFirst())
        let out = Pipe()
        let err = Pipe()
        task.standardOutput = out
        task.standardError = err
        do {
            try task.run()
        } catch {
            return RunResult(code: -1, stdout: "", stderr: error.localizedDescription)
        }

        // Drain both pipes concurrently BEFORE waitUntilExit. Reading
        // them after the child has exited is the classic Process
        // anti-pattern: if either stream fills its ~64KB buffer the
        // child blocks on write and waitUntilExit hangs forever.
        // Our commands (route, ifconfig, …) emit tiny output so the
        // theoretical case is unlikely, but the cost of doing this
        // right is one DispatchGroup.
        var outData = Data()
        var errData = Data()
        let group = DispatchGroup()
        let queue = DispatchQueue.global(qos: .userInitiated)
        group.enter()
        queue.async {
            outData = out.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        group.enter()
        queue.async {
            errData = err.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        task.waitUntilExit()
        group.wait()

        let outStr = String(data: outData, encoding: .utf8) ?? ""
        let errStr = String(data: errData, encoding: .utf8) ?? ""
        return RunResult(code: task.terminationStatus, stdout: outStr, stderr: errStr)
    }
}
