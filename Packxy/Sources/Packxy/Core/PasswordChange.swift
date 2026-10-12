// Active Directory password change over Kerberos (RFC 3244), the
// protocol `kpasswd` speaks.
//
// Goes through Apple's GSS.framework rather than spawning `kpasswd`:
// Heimdal's kpasswd reads both passwords from /dev/tty, so driving it
// from an app would need a pseudo-terminal and prompt scraping. The KDC
// is found through DNS SRV records for the realm, which resolve over the
// split-DNS `/etc/resolver` entry — so this only works while connected.

import Foundation
import GSS

enum PasswordChangeError: LocalizedError {
    case invalidPrincipal(String)
    case rejected(String)

    var errorDescription: String? {
        switch self {
        case .invalidPrincipal(let principal): return "“\(principal)” is not a valid Kerberos principal."
        case .rejected(let reason):            return reason
        }
    }
}

enum PasswordChange {
    /// `user@REALM` for the configured account. The realm is the one the
    /// user already names (`jdoe@corp.local`), else the first split-DNS
    /// domain — upper-cased either way, the AD convention, as Heimdal
    /// compares realms case-sensitively. A down-level `CORP\jdoe` logon
    /// name is reduced to `jdoe`.
    static func defaultPrincipal(for config: Config) -> String {
        let user = config.user.split(separator: "\\").last.map(String.init) ?? ""
        let parts = user.split(separator: "@", maxSplits: 1)
        if parts.count == 2 {
            return "\(parts[0])@\(parts[1].uppercased())"
        }
        guard let domain = config.vpnDomains.first else { return user }
        return "\(user)@\(domain.uppercased())"
    }

    /// Blocks on network round-trips to the KDC, hence detached.
    static func change(principal: String, old: String, new: String) async throws {
        try await Task.detached {
            try changeBlocking(principal: principal, old: old, new: new)
        }.value
    }

    private static func changeBlocking(principal: String, old: String, new: String) throws {
        var error: Unmanaged<CFError>?
        guard let name = GSSCreateName(principal as CFString, &__gss_c_nt_user_name_oid_desc, &error) else {
            error?.release()
            throw PasswordChangeError.invalidPrincipal(principal)
        }
        defer {
            var minor: OM_uint32 = 0
            var released: gss_name_t? = name
            gss_release_name(&minor, &released)
        }

        // kGSSChangePassword{Old,New}Password are CFSTR macros, which
        // Swift doesn't import; these are their literal values.
        let attributes = [
            "kGSSChangePasswordOldPassword": old,
            "kGSSChangePasswordNewPassword": new,
        ] as CFDictionary
        let major = gss_aapl_change_password(name, &__gss_krb5_mechanism_oid_desc, attributes, &error)
        guard major != GSS_S_COMPLETE else { return }

        let reason = error.map { CFErrorCopyDescription($0.takeRetainedValue()) as String }
        throw PasswordChangeError.rejected(reason ?? "The password change failed (GSS status \(major)).")
    }
}
