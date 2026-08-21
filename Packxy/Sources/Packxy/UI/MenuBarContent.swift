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
    @EnvironmentObject var metrics: LinkMetricsStore
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

            // The disconnect-before-quit confirmation lives in
            // AppDelegate.applicationShouldTerminate, not here: once the
            // app flips to .regular the main menu's Quit item makes ⌘Q a
            // live quit path, and a check on this button alone would be
            // bypassed by it (and by the Dock menu, and by logout).
            Button("Quit Packxy") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
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
            .foregroundStyle(s.indicator.color)
         + Text("  \(stateSummary(s))"))
            // VoiceOver doesn't read the inline Image's color, so
            // the explicit label is what conveys "we're red /
            // disconnected" to a non-sighted user (and is the only
            // signal at all for colorblind users squinting at the
            // identical-shape dots).
            .accessibilityLabel("Status: \(stateSummary(s))")

        switch s {
        case .connected:
            // Rendered unconditionally — with "—" placeholders until the
            // first sample lands about a second after connecting. Making
            // the row conditional would have it appear a beat later and
            // shove Routes / DNS / Disconnect down a slot, under a
            // cursor that's already moving toward one of them.
            //
            // Same concatenation constraint as the dot line above: an
            // HStack here would be flattened into three separate rows.
            let latest = metrics.latest
            let down = LinkMetrics.rateText(latest?.downBytesPerSecond)
            let up = LinkMetrics.rateText(latest?.upBytesPerSecond)
            let ping = LinkMetrics.latencyText(latest?.latencyMilliseconds)
            let pingTint = LinkMetrics.latencyIndicator(latest?.latencyMilliseconds)?.color
            // Literal arrow characters rather than SF Symbols. As
            // `Image(systemName:)` runs these rendered flat black —
            // near-invisible in a dark menu — because the outer
            // `.foregroundStyle` below does not reach an inline Image,
            // and only the ping run carried one of its own. A per-run
            // colour on each Image would likely have fixed it (that is
            // what the dot line above does), but a text run takes its
            // colour with no ambiguity at all, and in a menu that is
            // worth more than the nicer glyph. The tints match the
            // window's tiles so the two surfaces read as one readout.
            (Text("↓").foregroundStyle(.teal)
             + Text(" \(down)   ")
             + Text("↑").foregroundStyle(.indigo)
             + Text(" \(up)")
             + Text("  ·  ")
             + Text(ping).foregroundStyle(pingTint ?? .secondary))
                .foregroundStyle(.secondary)
                // Spelled out rather than left to VoiceOver, which
                // would read the arrows as bare "down arrow" / "up
                // arrow" glyphs stranded next to a number.
                .accessibilityLabel("Down \(down), up \(up), ping \(ping)")

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
            // The window is the only place the activity log and the
            // throughput graphs live, and closing it while connected
            // used to strand them — the menu carries a one-line summary
            // and nothing else. Above Disconnect, so the benign action
            // is the one under the cursor first.
            Button("Open status…") { showConnectionWindow() }
                .keyboardShortcut("o")
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

    /// Brings Packxy forward and opens the connection window. The heavy
    /// lifting — activation policy, the activation request, and making
    /// the real NSWindow key once it exists — lives in
    /// `WindowActivation`, the single choke point for every
    /// window-showing path. Without it the user clicks "Reconnect…",
    /// the window appears behind their browser, the menu closes, and
    /// from their POV "nothing happens".
    private func showConnectionWindow() {
        WindowActivation.present(.connection) {
            openWindow(id: WindowID.connection)
        }
    }
}
