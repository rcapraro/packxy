// Why the VPN dropped.
//
// Ported 1:1 from the Go side's `state.Reason` so the user-facing
// strings (drop notification body, OTP-dialog title/detail) stay
// identical between the two implementations during the migration —
// users notice nothing changed except the language under the hood.

import Foundation

enum Reason: String, Codable, Sendable {
    case authExpired    = "auth-expired"
    case networkDrop    = "network-drop"
    case startupFailure = "startup-failure"
    case wake           = "wake"
    case unknown        = "unknown"

    /// Bold heading shown on the OTP redemand dialog (NSAlert
    /// messageText equivalent). The `Packxy — ` prefix mirrors the
    /// drop notification title so the two surfaces feel like the same
    /// product; the clause names the situation in user terms.
    var dialogTitle: String {
        switch self {
        case .authExpired:    return "Packxy — 2FA token expired"
        case .networkDrop:    return "Packxy — VPN connection dropped"
        case .wake:           return "Packxy — Mac woke from sleep"
        case .startupFailure: return "Packxy — VPN failed to start"
        case .unknown:        return "Packxy — VPN disconnected"
        }
    }

    /// Smaller-text body shown beneath the title: an optional
    /// explanation followed by the call to action. Different drops
    /// carry slightly different verbs ("retry" after a startup
    /// failure, "reconnect" otherwise).
    var dialogDetail: String {
        let action: String
        switch self {
        case .startupFailure: action = "Enter a fresh 2FA code to retry."
        default:              action = "Enter a fresh 2FA code to reconnect."
        }
        // Wake is the only case where the title alone doesn't tell
        // the full story — spell out the consequence first.
        if self == .wake {
            return "The VPN tunnel was dropped.\n\n\(action)"
        }
        return action
    }

    /// Short body for the macOS notification posted on drop.
    var notificationBody: String {
        switch self {
        case .authExpired:    return "2FA token expired."
        case .networkDrop:    return "VPN connection dropped."
        case .wake:           return "Mac woke from sleep — the VPN tunnel was dropped."
        case .startupFailure: return "VPN failed to start."
        case .unknown:        return "VPN disconnected."
        }
    }
}
