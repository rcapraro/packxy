// Native macOS notifications via UserNotifications.framework.
//
// Replaces the Go-side cgo wrapper around the deprecated
// NSUserNotification API. UNUserNotificationCenter:
//
//   • requires an authorization prompt the first time we post
//     anything — we ask at app launch, non-blocking, and silently
//     stop posting if the user refuses;
//   • picks up the bundle's AppIcon automatically for the banner
//     thumbnail (works because dist/Packxy.app is ad-hoc-signed
//     with a real bundle identifier);
//   • supports `removeAllDeliveredNotifications` which gives us the
//     "clear stale drop banner before showing the success one"
//     behaviour the Go cgo wrapper had.

import AppKit
import Foundation
import UserNotifications

final class Notifications: NSObject {
    static let shared = Notifications()

    private let center = UNUserNotificationCenter.current()

    private override init() {
        super.init()
        center.delegate = self
    }

    // MARK: - Authorization

    /// Asks the OS for permission to post banners. Non-blocking: if
    /// the user already answered (allow or deny), this is a no-op.
    /// If they deny later, all subsequent post() calls become silent
    /// no-ops at the OS level — we don't gate at the call site.
    func requestAuthorizationIfNeeded() {
        center.getNotificationSettings { [weak self] settings in
            guard settings.authorizationStatus == .notDetermined else { return }
            self?.center.requestAuthorization(options: [.alert]) { _, _ in
                // Silent regardless of result.
            }
        }
    }

    // MARK: - Posting

    /// Banner shown when openfortivpn exits unexpectedly. Title +
    /// body mirror the Go watcher's exact strings so an existing
    /// user notices no copy regression after the migration.
    func dropOccurred(reason: Reason) {
        post(id: "drop",
             title: "Packxy — VPN disconnected",
             body: reason.notificationBody)
    }

    /// Banner shown after a successful reconnect. Caller should
    /// `clearDelivered()` immediately before this so the prior
    /// "VPN disconnected" banner doesn't linger beside the new
    /// success one in Notification Center.
    func reconnectSucceeded() {
        post(id: "success",
             title: "Packxy",
             body: "✓ VPN reconnected")
    }

    /// Banner shown when reconnect failed multiple times in a row —
    /// the user must intervene to avoid burning more OTP attempts
    /// against the FortiGate (which would lock the account).
    func authLocked() {
        post(id: "auth-locked",
             title: "Packxy — too many OTP failures",
             body: "Stopped to avoid a FortiGate lockout. Disconnect and reconnect manually when ready.")
    }

    /// Drops every delivered Packxy banner. Called just before
    /// posting a success notif so the stale drop banner disappears.
    func clearDelivered() {
        center.removeAllDeliveredNotifications()
    }

    // MARK: - Private

    private func post(id: String, title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        // Intentionally no sound: drops happen on every WiFi flap;
        // the Mac's notification chime is overkill for that.

        let request = UNNotificationRequest(
            identifier: id,
            content: content,
            trigger: nil) // immediate

        center.add(request) { error in
            // Surfacing errors via NSLog so they end up in Console.app
            // (the system log) for diagnostics, without spamming UI.
            if let error = error {
                NSLog("packxy: notification post failed: %@", error.localizedDescription)
            }
        }
    }
}

// MARK: - UNUserNotificationCenterDelegate

extension Notifications: UNUserNotificationCenterDelegate {
    /// Show banners even when Packxy is the "frontmost" app. For a
    /// menu-bar agent app this rarely matters, but it covers the
    /// edge case of the Settings or Connect window being key when
    /// a drop fires.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list])
    }

    /// Clicking the banner pulls Packxy forward. The user can then
    /// reach the Reconnect / Connect entries from the menu bar.
    /// (Opening the Connection window programmatically from here
    /// would require routing through a SwiftUI-aware listener; the
    /// menu-bar entry point is good enough for Phase 5.)
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        DispatchQueue.main.async {
            NSApp.activate()
        }
        completionHandler()
    }
}
