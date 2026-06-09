// Menu-bar dropdown contents.
//
// Surfaces the connection state at a glance: indicator + label, IP
// when connected, list of routes / split-DNS domains, and an action
// row that flips between Connect / Reconnect / Disconnect depending
// on ConnectionManager.state.

import AppKit
import SwiftUI

struct MenuBarContent: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var connectionManager: ConnectionManager
    @Environment(\.openWindow) private var openWindow

    /// Cap on how many comma-separated items we surface in the menu
    /// before collapsing into "X + N more"; keeps the dropdown narrow
    /// even when the user routes 10 CIDR ranges through the VPN.
    private static let maxInlineItems = 2

    var body: some View {
        Group {
            if !appState.isInstalled {
                Text("⚠ Packxy is not installed")
                    .foregroundStyle(.orange)
                Text("Open Settings to install components.")
                    .foregroundStyle(.secondary)
                Divider()
            } else {
                statusSection
                Divider()
                actionSection
                Divider()
            }

            SettingsLink { Text("Settings…") }
                .keyboardShortcut(",")

            Divider()

            Button("Quit Packxy") { confirmQuit() }
                .keyboardShortcut("q")
        }
    }

    /// Confirm before quitting while a tunnel is up — a stray ⌘Q
    /// would otherwise drop the FortiGate session silently and the
    /// user would only notice when the next packet failed to route.
    /// In any other state we exit immediately (no surprise to lose).
    private func confirmQuit() {
        guard case .connected = connectionManager.state else {
            NSApplication.shared.terminate(nil)
            return
        }
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "Disconnect VPN and quit Packxy?"
        alert.informativeText = "The tunnel will be torn down before the app exits."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            Task {
                await connectionManager.stop()
                NSApplication.shared.terminate(nil)
            }
        }
    }

    // MARK: - Status

    @ViewBuilder
    private var statusSection: some View {
        let cm = connectionManager
        let s = cm.state
        // Single Text built by concatenation: macOS menus flatten
        // HStacks into multiple menu rows, and they also strip the
        // foreground color from Image views inside `Label` (template
        // treatment). Building one Text with `Text(Image(...))` +
        // `Text(...)` keeps both the colored dot and the label on a
        // single line, and the per-run `.foregroundStyle` survives
        // the menu's text rendering.
        (Text(Image(systemName: "circle.fill"))
            .foregroundStyle(indicatorColor(s.indicator))
         + Text("  \(stateSummary(s))"))
            // VoiceOver doesn't read the inline Image's color, so
            // the explicit label is what conveys "we're red /
            // disconnected" to a non-sighted user (and is the only
            // signal at all for colorblind users squinting at the
            // identical-shape dots).
            .accessibilityLabel("Status: \(stateSummary(s))")

        switch s {
        case .connected:
            if !cm.routes.isEmpty {
                Text("Routes: \(summarize(cm.routes))")
                    .foregroundStyle(.secondary)
            }
            if !cm.domains.isEmpty {
                Text("DNS: \(summarize(cm.domains))")
                    .foregroundStyle(.secondary)
            }
        default:
            EmptyView()
        }
    }

    /// First-line summary that flips with connection state.
    ///
    /// Connected pulls the IP onto the dot line so the user sees their
    /// tunnel address at a glance; dropped folds the relative-time
    /// into the same line to avoid a redundant "Last drop: …" sentence
    /// when the dot already says "Disconnected".
    private func stateSummary(_ s: ConnectionState) -> String {
        switch s {
        case .connected(let ip, _):
            return "\(s.label) · \(ip)"
        case .dropped(_, let at):
            return "\(s.label) · \(relativeTime(at))"
        default:
            return s.label
        }
    }

    private func indicatorColor(_ i: ConnectionState.Indicator) -> Color {
        switch i {
        case .ok:   return .green
        case .warn: return .yellow
        case .bad:  return .red
        }
    }

    private func relativeTime(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f.localizedString(for: date, relativeTo: Date())
    }

    /// Joins up to `maxInlineItems` entries; collapses the rest into
    /// "+ N more" so the menu doesn't wrap into a 3-line monster when
    /// the user has many routes / domains configured.
    private func summarize(_ items: [String]) -> String {
        if items.count <= Self.maxInlineItems {
            return items.joined(separator: ", ")
        }
        let head = items.prefix(Self.maxInlineItems).joined(separator: ", ")
        let rest = items.count - Self.maxInlineItems
        return "\(head) + \(rest) more"
    }

    // MARK: - Actions

    @ViewBuilder
    private var actionSection: some View {
        let s = connectionManager.state
        let configReady = appState.config.hasMinimumCredentials
        // macOS doesn't show `.help` tooltips on disabled buttons, so
        // a visible row is the only way to tell the user why
        // Connect… / Reconnect… is grayed out. Sits *above* the action
        // so the eye lands on the cause before the (inert) button.
        if needsConfigWarning(state: s, configReady: configReady) {
            Text("⚠ Set host / username / password in Settings.")
                .foregroundStyle(.orange)
        }
        switch s {
        case .disconnected:
            Button("Connect…") { showConnectionWindow() }
                .keyboardShortcut("k")
                // Disable when host/user/password aren't all set —
                // opening the OTP form would only lead to a guaranteed
                // failure at submission.
                .disabled(!configReady)
        case .dropped:
            Button("Reconnect…") { showConnectionWindow() }
                .keyboardShortcut("r")
                .disabled(!configReady)
        case .connecting, .reconnecting:
            Button("Show progress…") { showConnectionWindow() }
        case .connected:
            Button("Disconnect") {
                Task { await connectionManager.stop() }
            }
            .keyboardShortcut("d")
        case .authLocked:
            Button("Open status…") { showConnectionWindow() }
        }
    }

    /// True only when the user *could* try to (re)connect but is
    /// blocked by missing credentials — `.connecting` / `.connected`
    /// / `.authLocked` have no Connect button to gate, so the warning
    /// would be noise.
    private func needsConfigWarning(state: ConnectionState, configReady: Bool) -> Bool {
        guard !configReady else { return false }
        switch state {
        case .disconnected, .dropped: return true
        default: return false
        }
    }

    /// Brings Packxy to the foreground BEFORE opening the connection
    /// window. Without the explicit activate, SwiftUI's
    /// `openWindow(id:)` reliably *creates* the window but doesn't
    /// always pull the agent app forward — the user clicks
    /// "Reconnect…" and the window appears behind their browser, the
    /// menu closes, and from their POV "nothing happens".
    ///
    /// `activate(ignoringOtherApps: true)` is deprecated in macOS 14
    /// but its replacement `activate()` does NOT pull an LSUIElement
    /// agent app forward — the deprecation is API-only; the behavior
    /// is still what we need.
    private func showConnectionWindow() {
        NSApp.activate(ignoringOtherApps: true)
        openWindow(id: WindowID.connection)
    }
}
