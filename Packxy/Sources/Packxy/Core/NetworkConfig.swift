// macOS network-side helpers used by ConnectionManager:
//
//   • addRoute / removeRoute      — route(8) entries via sudo -n
//   • writeResolver / removeResolver — /etc/resolver/<domain> files
//   • captureDefaultRoute / restoreDefaultIfHijacked — preserve the
//     host default route after openfortivpn brings ppp0 up
//   • CIDR math + resolveIPv4     — the post-connect reachability
//     check that catches "resolves fine, routes nowhere"
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
    /// duplicate add returns "File exists", which is a success for the
    /// caller's purposes but is reported distinctly.
    ///
    /// Returns **true only when this call created the route**. That
    /// distinction is load-bearing: `route delete` on BSD matches on
    /// destination+netmask and ignores the interface, so deleting a
    /// prefix we merely found in the table would rip out somebody
    /// else's route (the host LAN, a VM bridge) at teardown. Callers
    /// must only ever delete what they got `true` for.
    @discardableResult
    static func addRoute(cidr: String, dev: String) throws -> Bool {
        let result = runSudo(["/sbin/route", "-q", "add", "-net", cidr, "-interface", dev])
        if result.code == 0 { return true }
        if result.stderr.contains("File exists") || result.stdout.contains("File exists") {
            return false
        }
        throw NetworkConfigError.routeFailed(cidr: cidr, stderr: result.stderr.isEmpty ? result.stdout : result.stderr)
    }

    /// Deletes `<cidr> via <dev>`. Only call this for CIDRs `addRoute`
    /// returned `true` for — see the warning there.
    ///
    /// The kernel already flushes every route pointing at ppp0 when the
    /// interface goes down, so the usual outcome is "not in table",
    /// which is reported as success. We delete anyway because `stop()`
    /// reports `.disconnected` even when the pkill didn't land, and a
    /// stale route to a dead interface black-holes traffic silently.
    ///
    /// Returns nil on success, or a human-readable reason on failure —
    /// a `sudo -n` refusal from a stale sudoers drop-in lands here, and
    /// swallowing it would hide exactly the black-hole this guards.
    @discardableResult
    static func removeRoute(cidr: String, dev: String) -> String? {
        let result = runSudo(["/sbin/route", "-q", "delete", "-net", cidr, "-interface", dev])
        if result.code == 0 { return nil }
        let output = result.stderr.isEmpty ? result.stdout : result.stderr
        // Already gone (the kernel flushed it with the interface) is
        // the expected path, not a failure.
        if output.contains("not in table") || output.contains("No such process") {
            return nil
        }
        return output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "exit \(result.code)"
            : output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - CIDR math
    //
    // Used by the post-connect reachability check. Everything here is
    // pure: no sudo, no subprocess, safe to call off the main actor.

    /// Dotted-quad → host-order UInt32. nil on anything malformed.
    static func parseIPv4(_ s: String) -> UInt32? {
        let octets = s.split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4 else { return nil }
        var value: UInt32 = 0
        for octet in octets {
            guard let n = UInt32(octet), n <= 255 else { return nil }
            value = (value << 8) | n
        }
        return value
    }

    /// Dotted netmask (`255.255.255.0`) → prefix length (`24`).
    /// openfortivpn logs masks, not prefixes, so `parseGatewayFacts`
    /// needs this to build CIDRs. Rejects non-contiguous masks.
    static func maskToPrefix(_ mask: String) -> Int? {
        guard let bits = parseIPv4(mask) else { return nil }
        // trailingZeroBitCount is the host-bit count (and is 32 for a
        // 0.0.0.0 mask, which is exactly the /0 answer we want).
        let prefix = 32 - bits.trailingZeroBitCount
        // Contiguity check: rebuilding the mask from the prefix must
        // reproduce the input, else it was something like 255.0.255.0.
        let rebuilt: UInt32 = prefix == 0 ? 0 : ~UInt32(0) << (32 - prefix)
        guard rebuilt == bits else { return nil }
        return prefix
    }

    /// Whether `ip` falls inside `cidr` ("a.b.c.d/N").
    static func cidrContains(_ cidr: String, ip: String) -> Bool {
        let parts = cidr.split(separator: "/")
        guard parts.count == 2,
              let prefix = Int(parts[1]), (0...32).contains(prefix),
              let base = parseIPv4(String(parts[0])),
              let addr = parseIPv4(ip)
        else { return false }
        if prefix == 0 { return true }
        let mask: UInt32 = ~UInt32(0) << (32 - prefix)
        return (base & mask) == (addr & mask)
    }

    /// The first entry of `cidrs` that covers `ip`, or nil. Naming the
    /// matching CIDR lets the activity log say *why* a host is
    /// reachable, not just that it is.
    static func coveringCIDR(_ ip: String, cidrs: [String]) -> String? {
        cidrs.first { cidrContains($0, ip: ip) }
    }

    /// Whether any of `cidrs` covers `ip`.
    static func routesCover(_ ip: String, cidrs: [String]) -> Bool {
        coveringCIDR(ip, cidrs: cidrs) != nil
    }

    /// Whether `ip` is in RFC1918 space (10/8, 172.16/12, 192.168/16).
    /// Corporate networks live here; a test host that resolves outside
    /// it is a DNS problem, not a routing one.
    static func isPrivateIPv4(_ ip: String) -> Bool {
        cidrContains("10.0.0.0/8", ip: ip)
            || cidrContains("172.16.0.0/12", ip: ip)
            || cidrContains("192.168.0.0/16", ip: ip)
    }

    /// The /24 containing `ip` — the CIDR we suggest when a host
    /// resolves outside every configured route.
    ///
    /// Returns nil for anything that isn't RFC1918. A public address
    /// here means the lookup was answered by the public resolver (a
    /// missing /etc/resolver file, a CNAME out of the internal zone,
    /// split-horizon DNS), and telling the user to route a public /24
    /// into the tunnel would turn a DNS misconfiguration into a
    /// permanent traffic-hijacking one.
    static func suggestedCIDR(for ip: String) -> String? {
        let octets = ip.split(separator: ".")
        guard octets.count == 4, isPrivateIPv4(ip) else { return nil }
        return "\(octets[0]).\(octets[1]).\(octets[2]).0/24"
    }

    /// Smallest prefix length we're willing to install from a
    /// gateway-pushed split route.
    ///
    /// A FortiGate can express "everything" as 0.0.0.0/0.0.0.0, and
    /// some push the 0.0.0.0/1 + 128.0.0.0/1 half-internet pair. Either
    /// one installed against ppp0 is a full tunnel — precisely what
    /// Packxy's four locks exist to prevent — so anything broader than
    /// a /8 is refused and reported instead of silently applied.
    static let minimumGatewayPrefix = 8

    /// Whether a gateway-pushed CIDR is narrow enough to install.
    static func isAcceptableGatewayRoute(_ cidr: String) -> Bool {
        let parts = cidr.split(separator: "/")
        guard parts.count == 2, let prefix = Int(parts[1]) else { return false }
        return prefix >= minimumGatewayPrefix
    }

    // MARK: - Name resolution

    /// Resolves `host` to its IPv4 addresses through the system
    /// resolver — which means it honours the /etc/resolver/<domain>
    /// files Packxy just wrote, unlike a hand-rolled DNS query.
    ///
    /// BLOCKING: getaddrinfo(3) can sit on the network for seconds.
    /// Never call this from the main actor.
    static func resolveIPv4(_ host: String) -> [String] {
        var hints = addrinfo(
            ai_flags: 0,
            ai_family: AF_INET,
            ai_socktype: SOCK_STREAM,
            ai_protocol: 0,
            ai_addrlen: 0,
            ai_canonname: nil,
            ai_addr: nil,
            ai_next: nil
        )
        var head: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &head) == 0, let list = head else {
            return []
        }
        defer { freeaddrinfo(list) }

        var found: [String] = []
        var node: UnsafeMutablePointer<addrinfo>? = list
        while let current = node {
            if current.pointee.ai_family == AF_INET, let sa = current.pointee.ai_addr {
                var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                var addr = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                    $0.pointee.sin_addr
                }
                if inet_ntop(AF_INET, &addr, &buf, socklen_t(INET_ADDRSTRLEN)) != nil {
                    let ip = String(cString: buf)
                    if !found.contains(ip) { found.append(ip) }
                }
            }
            node = current.pointee.ai_next
        }
        return found
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
