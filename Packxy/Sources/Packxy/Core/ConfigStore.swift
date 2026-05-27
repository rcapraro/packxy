// Packxy configuration: read/write ~/.config/packxy.conf.
//
// The on-disk format is the same KEY=VALUE / KEY="quoted value" /
// `# comment` flavour used by godotenv in the Go implementation —
// preserved so a user can edit ~/.config/packxy.conf by hand without
// caring that the loader changed languages.
//
// The parser is intentionally tolerant (skips blank lines, leading
// `export`, comments) and the writer emits a stable layout grouped by
// section so a diff against the previous version is readable.

import Foundation

struct Config: Equatable {
    var host: String = ""
    var port: String = ""
    var user: String = ""
    var password: String = ""
    var trustedCert: String = ""
    var realm: String = ""
    var noFTMPush: Bool = false
    var otpPrompt: String = ""
    var vpnRoutes: [String] = []
    var vpnDNS: String = ""
    var vpnDomains: [String] = []

    var hasSplitTunneling: Bool { !vpnRoutes.isEmpty }
    var hasSplitDNS: Bool { !vpnDNS.isEmpty && !vpnDomains.isEmpty }

    /// Whether the credentials needed to authenticate are present.
    /// OTP is excluded — it's prompted at every connect by design.
    /// Used to gate the menu-bar Connect action so we don't open a
    /// dialog that's certain to fail at submission.
    var hasMinimumCredentials: Bool {
        !host.isEmpty && !user.isEmpty && !password.isEmpty
    }
}

enum ConfigStoreError: Error {
    case homeDirectoryUnavailable
}

enum ConfigStore {
    /// Canonical location, mirroring `envcfg.DefaultPath` on the Go side.
    static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/packxy.conf")
    }

    /// Reads the config from `defaultURL`. Missing file is not an error —
    /// it just yields an empty `Config`; the Installer / Settings UI will
    /// guide the user to fill it in.
    static func load(from url: URL = defaultURL) -> Config {
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else {
            return Config()
        }
        return parse(text)
    }

    /// Writes the config atomically with 0600 perms (the file holds the
    /// VPN password).
    static func save(_ config: Config, to url: URL = defaultURL) throws {
        let parent = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
        let body = serialize(config)
        try body.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: url.path
        )
    }

    // MARK: - Parser

    /// Parses a godotenv-style buffer into a Config. Tolerant: unknown
    /// keys are ignored, malformed lines skipped silently.
    static func parse(_ text: String) -> Config {
        var c = Config()
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            var line = String(rawLine).trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("export ") {
                line = String(line.dropFirst("export ".count))
            }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<eq]).trimmingCharacters(in: .whitespaces)
            var value = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            value = unquote(value)
            switch key {
            case "FORTI_HOST":        c.host = value
            case "FORTI_PORT":        c.port = value
            case "FORTI_USER":        c.user = value
            case "FORTI_PASS":        c.password = value
            case "FORTI_TRUSTED_CERT": c.trustedCert = value
            case "FORTI_REALM":       c.realm = value
            case "FORTI_NO_FTM_PUSH": c.noFTMPush = (value == "1")
            case "FORTI_OTP_PROMPT":  c.otpPrompt = value
            case "VPN_ROUTES":        c.vpnRoutes = splitCSV(value)
            case "VPN_DNS":           c.vpnDNS = value
            case "VPN_DOMAINS":       c.vpnDomains = splitCSV(value)
            // FORTI_OTP is intentionally not persisted: it's a single-use
            // 30 s token that has no business living in a file.
            default: break
            }
        }
        return c
    }

    private static func unquote(_ s: String) -> String {
        guard s.count >= 2,
              let first = s.first,
              let last = s.last
        else { return s }
        if (first == "\"" && last == "\"") || (first == "'" && last == "'") {
            return String(s.dropFirst().dropLast())
        }
        return s
    }

    private static func splitCSV(_ s: String) -> [String] {
        s.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    // MARK: - Serializer

    /// Emits a sectioned KEY=VALUE buffer. Values with spaces or commas
    /// are wrapped in double quotes; everything else is left bare for
    /// readability when the user edits by hand.
    static func serialize(_ c: Config) -> String {
        var b = ""
        b += "# Packxy — FortiGate VPN split tunneling cfg.\n"
        b += "# Edited by the Packxy app (and editable by hand).\n"
        b += "# Permissions are 0600 because this file holds the VPN password.\n"

        b += "\n# --- VPN connection (required) ---\n"
        b += kv("FORTI_HOST", c.host)
        b += kv("FORTI_PORT", c.port)
        b += kv("FORTI_USER", c.user)
        b += kv("FORTI_PASS", c.password)
        b += kv("FORTI_TRUSTED_CERT", c.trustedCert)

        b += "\n# --- VPN connection (optional) ---\n"
        b += kv("FORTI_REALM", c.realm)
        b += kv("FORTI_NO_FTM_PUSH", c.noFTMPush ? "1" : "")
        b += kv("FORTI_OTP_PROMPT", c.otpPrompt)

        b += "\n# --- Split tunneling ---\n"
        b += "# Comma-separated CIDR ranges to route through the VPN.\n"
        b += kv("VPN_ROUTES", c.vpnRoutes.joined(separator: ","))
        b += "# Internal DNS server IP, plus the comma-separated domains it serves.\n"
        b += kv("VPN_DNS", c.vpnDNS)
        b += kv("VPN_DOMAINS", c.vpnDomains.joined(separator: ","))

        return b
    }

    private static func kv(_ key: String, _ value: String) -> String {
        // Quote when the value contains whitespace, '#', or '=' so the
        // parser round-trips cleanly. Empty values stay bare.
        if value.isEmpty {
            return "\(key)=\n"
        }
        let needsQuotes = value.contains(where: { " \t#=,\"".contains($0) })
        if needsQuotes {
            let escaped = value.replacingOccurrences(of: "\\", with: "\\\\")
                               .replacingOccurrences(of: "\"", with: "\\\"")
            return "\(key)=\"\(escaped)\"\n"
        }
        return "\(key)=\(value)\n"
    }
}
