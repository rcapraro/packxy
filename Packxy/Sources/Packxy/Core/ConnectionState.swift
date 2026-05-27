// High-level connection state surfaced to the UI.
//
// Single source of truth that the menu bar icon, the connection
// window, the status card and the notification logic all read from.
// Mirrors the multi-state model the Go watcher carried implicitly
// (in-memory PID flags + last-drop reason) but consolidated into one
// enum so SwiftUI can drive views off `@Published var state`.

import Foundation

enum ConnectionState: Equatable, Sendable {
    /// No tunnel; user must click Connect to start one.
    case disconnected

    /// Spawning openfortivpn / waiting for ppp0 to come up.
    case connecting

    /// ppp0 has an IP and routes/DNS are wired. The Date captures the
    /// start time so the UI can show a "connected for 1h 23m" badge.
    case connected(ip: String, since: Date)

    /// openfortivpn died or the watcher caught a wake event. Carries
    /// the reason so the UI can show a tailored OTP redemand prompt.
    case dropped(reason: Reason, at: Date)

    /// In the middle of a reconnect cycle (typically just after the
    /// user entered an OTP in the redemand sheet).
    case reconnecting

    /// Too many auth failures in a row — we've stopped trying to
    /// avoid burning OTP attempts and triggering a FortiGate lockout.
    /// Requires the user to manually re-enter the connect flow.
    case authLocked

    var label: String {
        switch self {
        case .disconnected: return "Disconnected"
        case .connecting:   return "Connecting…"
        case .connected:    return "Connected"
        case .dropped:      return "Disconnected"
        case .reconnecting: return "Reconnecting…"
        case .authLocked:   return "Auth locked"
        }
    }

    /// Coarse traffic-light bucket used by the menu-bar icon and the
    /// status line.
    var indicator: Indicator {
        switch self {
        case .connected:                return .ok
        case .connecting, .reconnecting: return .warn
        case .disconnected, .dropped, .authLocked: return .bad
        }
    }

    enum Indicator { case ok, warn, bad }
}
