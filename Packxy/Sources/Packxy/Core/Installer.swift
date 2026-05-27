// Packxy install/uninstall — sudoers drop-in + pppd peer file.
//
// macOS requires root to launch openfortivpn (it opens /dev/ppp), but
// we don't want to prompt for sudo on every reconnect. Solution: a
// sudoers drop-in at /etc/sudoers.d/packxy that grants the current user
// passwordless sudo for openfortivpn, pkill of openfortivpn, and
// /sbin/route. Plus a pppd peer file at /etc/ppp/peers/packxy carrying
// the split-tunnel-safe options (nodefaultroute, LCP echo).
//
// Both files live under /etc and need root to write. We bundle both
// writes into a single shell script and run it via
//   osascript -e 'do shell script "…" with administrator privileges'
// so the user sees exactly one native macOS admin prompt.
//
// The file contents are reproduced exactly from the Go implementation
// (forti.Install / forti.EnsurePeerFile) so an existing install drop-in
// keeps working unchanged.

import Foundation

enum InstallerError: LocalizedError {
    case openfortivpnNotFound
    case cancelled
    case scriptFailed(stderr: String)

    var errorDescription: String? {
        switch self {
        case .openfortivpnNotFound:
            return "openfortivpn binary not found in PATH. Install it with `brew install openfortivpn` and try again."
        case .cancelled:
            return "Installation was cancelled."
        case .scriptFailed(let stderr):
            return "Install script failed:\n\(stderr)"
        }
    }
}

enum Installer {
    static let sudoersPath = "/etc/sudoers.d/packxy"
    static let peerName = "packxy"
    static var peerPath: String { "/etc/ppp/peers/\(peerName)" }

    // Match forti.DefaultLCPEcho{Interval,Failure}: heartbeat every 10s,
    // declare dead after 6 missed echoes (~60s tolerance window).
    static let defaultLCPEchoInterval = 10
    static let defaultLCPEchoFailure = 6

    /// Reports whether both the sudoers drop-in and the pppd peer file
    /// are present **and** openfortivpn is reachable. All three must
    /// hold or `packxy start` would fail later.
    static func isInstalled() -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: sudoersPath) else { return false }
        guard fm.fileExists(atPath: peerPath) else { return false }
        return (try? findOpenfortivpn()) != nil
    }

    /// Returns the absolute path of the `openfortivpn` binary. We probe
    /// the two Homebrew prefixes explicitly first (the app's PATH may
    /// not include /opt/homebrew/bin when launched from Finder), then
    /// fall back to `which`.
    static func findOpenfortivpn() throws -> String {
        let candidates = [
            "/opt/homebrew/bin/openfortivpn",
            "/usr/local/bin/openfortivpn",
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        task.arguments = ["openfortivpn"]
        let outPipe = Pipe()
        task.standardOutput = outPipe
        task.standardError = Pipe()
        try task.run()
        task.waitUntilExit()
        if task.terminationStatus == 0,
           let data = try? outPipe.fileHandleForReading.readToEnd(),
           let s = String(data: data, encoding: .utf8) {
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        throw InstallerError.openfortivpnNotFound
    }

    /// Writes both the sudoers drop-in and the pppd peer file via a
    /// single admin-prompted shell script. Idempotent: existing files
    /// are overwritten.
    static func install() async throws {
        let binPath = try findOpenfortivpn()
        let username = NSUserName()

        // Defensive: macOS in practice restricts usernames to safe
        // characters, but the username is interpolated literally into
        // the sudoers file — a hostile or exotic username could break
        // visudo or, worst case, escape the user's NOPASSWD scope.
        // Restrict to the POSIX-portable identifier set.
        let allowedInUsername: Set<Character> = Set(
            "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-"
        )
        guard !username.isEmpty,
              username.allSatisfy({ allowedInUsername.contains($0) })
        else {
            throw InstallerError.scriptFailed(
                stderr: "Unsupported characters in username '\(username)' — sudoers cannot be configured safely."
            )
        }

        let sudoersBody = sudoersTemplate(username: username, openfortivpnBin: binPath)
        let peerBody = peerTemplate(interval: defaultLCPEchoInterval, failure: defaultLCPEchoFailure)

        // Stage the files in a user-writable temp dir, then move them
        // into /etc with proper ownership inside the admin-privileged
        // script. This way the only privileged commands are the
        // visudo/install lines — we don't expose the raw bodies to the
        // root shell via inline heredocs.
        let tmpSudoers = try writeTemp(sudoersBody, prefix: "packxy-sudoers")
        let tmpPeer = try writeTemp(peerBody, prefix: "packxy-peer")
        defer {
            try? FileManager.default.removeItem(atPath: tmpSudoers)
            try? FileManager.default.removeItem(atPath: tmpPeer)
        }

        let script = """
        set -e
        /usr/sbin/visudo -cf '\(tmpSudoers)'
        /usr/bin/install -m 0440 -o root -g wheel '\(tmpSudoers)' '\(sudoersPath)'
        /bin/mkdir -p /etc/ppp/peers
        /usr/bin/install -m 0644 -o root -g wheel '\(tmpPeer)' '\(peerPath)'
        """
        try await runAsAdmin(shellScript: script, prompt: "Packxy needs to install split-tunnel components.")
    }

    /// Removes both the sudoers drop-in and the pppd peer file.
    static func uninstall() async throws {
        let script = """
        set -e
        /bin/rm -f '\(sudoersPath)' '\(peerPath)'
        """
        try await runAsAdmin(shellScript: script, prompt: "Packxy needs to remove its components.")
    }

    // MARK: - Templates (copied verbatim from forti.go to keep the
    // on-disk artifacts byte-identical between Go and Swift installs)

    static func sudoersTemplate(username: String, openfortivpnBin: String) -> String {
        """
        # Generated by packxy. Grants \(username) the passwordless sudo
        # capabilities the app needs to keep the VPN running across drops:
        #
        #   openfortivpn  — start/stop the VPN process at any moment, especially
        #                   long after the original sudo cache has expired.
        #   pkill         — pre-stop openfortivpn on macOS sleep notifications and
        #                   on user-initiated teardown. Restricted to the
        #                   openfortivpn process so it can't be used to kill
        #                   anything else.
        #   route         — re-add VPN routes after each reconnect. When the old
        #                   ppp0 goes down the kernel flushes every route pointing
        #                   at it; the new ppp0 needs them put back. Also used to
        #                   undo macOS' SystemConfiguration default route hijack
        #                   and preserve split tunneling.
        #   tee/rm/mkdir  — manage /etc/resolver/<domain> files so the macOS
        #                   per-domain DNS resolver picks up internal hostnames.
        #                   The Swift app can't prompt for a sudo password (no
        #                   TTY), so these specific commands are granted without
        #                   password. Wildcards don't match `/`, so writes are
        #                   confined to /etc/resolver/ flat files only.
        #
        # Remove this file with `sudo rm \(sudoersPath)`.
        \(username) ALL=(root) NOPASSWD: \(openfortivpnBin), /usr/bin/pkill -TERM -x openfortivpn, /usr/bin/pkill -KILL -x openfortivpn, /sbin/route, /bin/mkdir -p /etc/resolver, /usr/bin/tee /etc/resolver/*, /bin/rm -f /etc/resolver/*
        """
    }

    static func peerTemplate(interval: Int, failure: Int) -> String {
        // 230400 — explicit baud rate. macOS BSD pppd refuses to start
        //          without one ("Baud rate for /dev/ttysNNN is 0").
        // nodefaultroute — pppd does NOT replace the macOS default route.
        // lcp-echo-*    — keepalive heartbeat, fast dead-link detection.
        """
        # Generated by packxy — split-tunnel-safe pppd options.
        230400
        nodefaultroute
        lcp-echo-interval \(interval)
        lcp-echo-failure \(failure)
        """
    }

    // MARK: - Helpers

    private static func writeTemp(_ body: String, prefix: String) throws -> String {
        let dir = NSTemporaryDirectory()
        let path = "\(dir)\(prefix).\(getpid()).\(Int(Date().timeIntervalSince1970))"
        try body.write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: path
        )
        return path
    }

    /// Runs `shellScript` as root via osascript's standard
    /// "administrator privileges" path. Surfaces user-cancel as
    /// `InstallerError.cancelled` so callers can no-op cleanly.
    private static func runAsAdmin(shellScript: String, prompt: String) async throws {
        let escapedScript = shellScript
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let escapedPrompt = prompt
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")

        let appleScript = """
        do shell script "\(escapedScript)" with prompt "\(escapedPrompt)" with administrator privileges
        """

        try await Task.detached(priority: .userInitiated) {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            task.arguments = ["-e", appleScript]

            // Drain stderr asynchronously so we don't deadlock if the
            // child writes more than the pipe buffer (~64 KB) before
            // we get around to reading. Calling `waitUntilExit()`
            // before reading is the classic Process anti-pattern —
            // the child blocks on write, the parent blocks on exit.
            let stderrPipe = Pipe()
            task.standardError = stderrPipe
            // No stdout pipe: osascript's stdout for a "do shell
            // script" is the script's stdout, which we don't need.
            // Setting nil routes it to /dev/null and skips the
            // deadlock window entirely.
            task.standardOutput = nil

            try task.run()

            let stderrReader = Task.detached { () -> Data in
                stderrPipe.fileHandleForReading.readDataToEndOfFile()
            }

            task.waitUntilExit()
            let stderrText = String(data: await stderrReader.value, encoding: .utf8) ?? ""

            if task.terminationStatus == 0 { return }

            // -128 is AppleScript's user-cancel code; the stderr text
            // typically contains "User canceled." Either way, treat as
            // a non-error cancellation so the UI can stay calm.
            if stderrText.contains("-128") || stderrText.lowercased().contains("user canceled") {
                throw InstallerError.cancelled
            }
            throw InstallerError.scriptFailed(stderr: stderrText.isEmpty ? "exit \(task.terminationStatus)" : stderrText)
        }.value
    }
}
