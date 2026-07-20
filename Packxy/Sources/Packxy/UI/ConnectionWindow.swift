// Connect / OTP-redemand window.
//
// One window that switches its contents based on
// ConnectionManager.state:
//
//   • .disconnected            → "Connect" form with the OTP field.
//   • .dropped(reason, _)      → "Reconnect" form titled with the
//                                reason's dialogTitle/Detail so the
//                                narrative matches the drop notif.
//   • .connecting/.reconnecting → progress spinner + live activity
//                                log so the user can see what's
//                                actually happening (sudo, ppp0,
//                                routes, resolvers).
//   • .connected               → success confirmation + the log
//                                from the attempt; window stays
//                                open until the user clicks Close.
//   • .authLocked              → call-to-action to bail out.
//
// The window auto-focuses the OTP field on appear and on state
// changes, so re-prompts (e.g. after a rejected OTP) put the cursor
// right back in the field — no extra click needed. State transitions
// are wrapped in `withAnimation` for a smooth cross-fade between
// forms / spinner / confirmation.

import AppKit
import SwiftUI

struct ConnectionWindow: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var connectionManager: ConnectionManager
    @Environment(\.dismissWindow) private var dismissWindow

    @State private var otp: String = ""
    @FocusState private var otpFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            content
                // `.id(stateID)` forces SwiftUI to treat each state's
                // content as a distinct view, which is what makes the
                // `.transition` below actually fire on swap — without
                // it, the @ViewBuilder switch can be folded into the
                // same identity and `.move(edge: .top)` is silently
                // dropped.
                .id(stateID)
                .transition(.opacity.combined(with: .move(edge: .top)))
                // Animation scoped to `content` only: header and
                // footer change shape between states (e.g. 2-button
                // footer → 1-button footer → 2-button footer) and
                // animating those translates buttons sideways, which
                // reads as a jitter. Cross-fading only the form /
                // spinner / confirmation gives a clean transition.
                .animation(.easeInOut(duration: 0.18), value: stateID)
                // Let `content` claim all the vertical slack between
                // header and footer so the inner LogView can grow
                // when the user resizes the window taller.
                // `.topLeading` keeps states without a log
                // (`.authLocked`, an empty form) anchored to the top
                // instead of drifting to the vertical centre.
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            footer
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        // Only the lower bound: the driver-error row carries its own
        // bounded ScrollView now, so we don't need a global maxHeight
        // to keep the footer on-screen — and dropping it lets the
        // user grow the window if they really want to inspect a long
        // error without the inner scroll. minHeight is generous
        // enough to give the connect/reconnect log view reasonable
        // default room without forcing an immediate resize.
        .frame(minWidth: 440, minHeight: 280)
        // Re-focus the OTP field whenever the state flips back to an
        // input form — covers the "OTP rejected, try again" path
        // where the user expects the cursor to land where they were
        // typing.
        .onChange(of: connectionManager.state) { _, new in
            switch new {
            case .disconnected, .dropped: otpFocused = true
            default: break
            }
        }
        // Menu-bar agents (LSUIElement=YES) don't activate when one of
        // their windows opens — without this, the Connect window shows
        // up behind whatever app had focus when the user clicked the
        // menu-bar item, and the OTP field never gets keyboard input.
        .onAppear {
            NSApp.activate(ignoringOtherApps: true)
            otpFocused = true
        }
    }

    /// String key derived from ConnectionState — used to drive
    /// `.animation` cleanly without pulling associated Date values
    /// into the equality check (which would re-fire the animation
    /// every time `.dropped(_, at:)` happens to carry a new timestamp).
    private var stateID: String {
        switch connectionManager.state {
        case .disconnected: return "disconnected"
        case .connecting:   return "connecting"
        case .reconnecting: return "reconnecting"
        case .connected:    return "connected"
        case .dropped:      return "dropped"
        case .authLocked:   return "authLocked"
        }
    }

    // MARK: - Header

    @ViewBuilder
    private var header: some View {
        switch connectionManager.state {
        case .disconnected:
            sectionHeader(title: "Connect to VPN",
                          detail: "Enter the 2FA code generated by your authenticator.")
        case .connecting:
            sectionHeader(title: "Connecting…", detail: "Establishing the tunnel.")
        case .reconnecting:
            sectionHeader(title: "Reconnecting…", detail: "Re-establishing the tunnel.")
        case .connected:
            sectionHeader(title: "Connected",
                          detail: "VPN tunnel is up. Connection details live in the menu bar.")
        case .dropped(let reason, _):
            sectionHeader(title: reason.dialogTitle, detail: reason.dialogDetail)
        case .authLocked:
            sectionHeader(title: "Packxy — too many failed attempts",
                          detail: "Disconnect and reconnect from a fresh state.")
        }
    }

    private func sectionHeader(title: String, detail: String) -> some View {
        // Icon on the left, title/detail stack on the right — mirrors
        // the standard NSAlert layout so the window feels like a
        // native system prompt. The AppIcon is loaded via NSImage
        // applicationIconName which always resolves from the running
        // bundle's icon, with the shield SF symbol as a defensive
        // fallback for hosts where the icon hasn't been generated yet.
        HStack(alignment: .top, spacing: 12) {
            appIcon
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.title3).fontWeight(.semibold)
                Text(detail).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var appIcon: some View {
        // 36pt sits comfortably between the body text height and the
        // title size; the 44pt NSAlert default was visually dominant
        // in this compact window.
        if let ns = NSImage(named: NSImage.applicationIconName) {
            Image(nsImage: ns)
                .resizable()
                .frame(width: 36, height: 36)
                .accessibilityHidden(true)
        } else {
            Image(systemName: "shield.lefthalf.filled")
                .font(.system(size: 26, weight: .medium))
                .foregroundStyle(.tint)
                .frame(width: 36, height: 36)
                .accessibilityHidden(true)
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch connectionManager.state {
        case .disconnected, .dropped:
            otpForm
        case .connecting, .reconnecting:
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(connectionManager.state.label)
                        .foregroundStyle(.secondary)
                }
                LogView(entries: connectionManager.log)
                    .frame(minHeight: 100, maxHeight: .infinity)
            }
        case .connected:
            // The menu bar carries the live status (IP / routes /
            // DNS / "Disconnect"). Here we show the full attempt log
            // above the close prompt so the user can confirm what
            // got wired up before clicking Close.
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.title2)
                    Text("You can close this window.")
                        .foregroundStyle(.secondary)
                }
                LogView(entries: connectionManager.log)
                    .frame(minHeight: 100, maxHeight: .infinity)
            }
        case .authLocked:
            Text("Packxy stopped trying to reconnect after multiple OTP failures, to avoid a FortiGate lockout.")
                .foregroundStyle(.secondary)
        }
    }

    private var otpForm: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("2FA code", text: $otp, prompt: Text("123456"))
                .textFieldStyle(.roundedBorder)
                .font(.system(.title2, design: .monospaced))
                // 6 monospaced title2 digits + roundedBorder padding
                // ≈ 160pt; 200pt gives a comfortable margin without
                // sprawling across the full window width when the
                // user resizes it.
                .frame(maxWidth: 200, alignment: .leading)
                .focused($otpFocused)
                .onSubmit { Task { await submit() } }
                // Strip non-digit characters as the user types, and
                // cap to 6 chars. Authenticator apps copy 6-digit
                // tokens; this keeps stray paste-noise out without
                // making the user think their input was ignored.
                .onChange(of: otp) { _, new in
                    let cleaned = String(new.filter(\.isNumber).prefix(6))
                    if cleaned != otp { otp = cleaned }
                }
            Text(otpHint)
                .font(.callout)
                .foregroundStyle(otpHintColor)
                // Single line keeps the layout from jiggling as the
                // hint switches between its three messages.
                .lineLimit(1)
            // Surface the underlying openfortivpn / sudo failure
            // distinctly from a self-validation error — the warning
            // triangle signals "this is a system error from the
            // driver" rather than something the user typed wrong.
            // No longer gated on `.dropped`: a failed `start()` can
            // land us back in `.disconnected` with `lastError` set,
            // and silently swallowing it leaves the user staring at a
            // blank form wondering why nothing happened.
            if let driverError = connectionManager.lastError {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                    // ScrollView caps the visual footprint of long
                    // openfortivpn / sudo stack-traces — without it
                    // the parent's maxHeight silently chops the
                    // overflow off, hiding the tail of the error.
                    ScrollView {
                        Text(driverError)
                            .font(.callout)
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 120)
                }
            }
            // Surface the prior-attempt log below `lastError` when
            // present — the timestamped chronology often explains the
            // one-liner above (e.g. "OTP rejected" preceded by sudo
            // password-prompt failures, or "timeout" preceded by
            // peer-resets). Hidden when empty so an initial
            // `.disconnected` keeps its tight layout.
            if !connectionManager.log.isEmpty {
                LogView(entries: connectionManager.log)
                    .frame(minHeight: 100, maxHeight: .infinity)
            }
        }
    }

    /// Live hint that updates as the user types: "Enter a 6-digit
    /// code." → "4/6 digits." → "Ready to submit (Return)."
    private var otpHint: String {
        if otp.isEmpty { return "Enter the 6-digit code from your authenticator." }
        if otp.count < 6 { return "\(otp.count)/6 digits…" }
        return "Press Return to submit."
    }

    private var otpHintColor: Color {
        isOTPValid ? .green : .secondary
    }

    // MARK: - Footer (actions)

    @ViewBuilder
    private var footer: some View {
        switch connectionManager.state {
        case .disconnected:
            HStack {
                Spacer()
                Button("Close") { dismissWindow() }
                    .keyboardShortcut(.cancelAction)
                Button("Connect") { Task { await submit() } }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isOTPValid)
            }
        case .dropped:
            HStack {
                // Cancel = give up on reconnecting AND tear down any
                // remaining /etc/resolver entries pointing at the
                // (now unreachable) internal DNS server. Without this
                // the user's split-DNS domains keep resolving through
                // a dead tunnel until they manually `packxy stop` or
                // re-run the app.
                Button("Cancel") {
                    Task {
                        await connectionManager.stop()
                        dismissWindow()
                    }
                }
                .keyboardShortcut(.cancelAction)
                .help("Tear down the tunnel and return to the disconnected state.")
                Spacer()
                Button("Reconnect") { Task { await submit() } }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isOTPValid)
            }
        case .connecting, .reconnecting:
            HStack {
                Spacer()
                Button("Close") { dismissWindow() }
            }
        case .connected:
            HStack {
                Spacer()
                Button("Close") { dismissWindow() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        case .authLocked:
            HStack {
                Spacer()
                Button("Close") { dismissWindow() }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    // MARK: - Helpers

    private var isOTPValid: Bool {
        otp.count == 6 && otp.allSatisfy(\.isNumber)
    }

    private func submit() async {
        // The Connect button is `.disabled(!isOTPValid)`, so the only
        // way `submit()` fires with an invalid OTP is via Enter on
        // the TextField at <6 digits. The hint already tells the
        // user where they're at — silently no-op rather than spawn a
        // redundant red label.
        guard isOTPValid else { return }
        if case .dropped = connectionManager.state {
            await connectionManager.reconnect(config: appState.config, otp: otp)
        } else {
            await connectionManager.start(config: appState.config, otp: otp)
        }
        otp = ""
        // No auto-dismiss on success: the user wants to read the
        // activity log and click Close themselves. The `.connected`
        // content + footer already render that affordance.
    }
}

// MARK: - LogView

/// Scrolling, timestamped, monospaced view of the connect/reconnect
/// activity log. Auto-scrolls to the newest line as entries arrive,
/// using `entries.last?.id` (an `Equatable` UUID) as the trigger so
/// SwiftUI doesn't re-fire on every `[LogEntry]` array publication.
/// Backed by a textBackground-coloured panel with a subtle stroke so
/// it reads as "log surface" against the rest of the window chrome.
private struct LogView: View {
    let entries: [LogEntry]

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(entries) { entry in
                        HStack(alignment: .top, spacing: 6) {
                            Text(Self.timestampFormatter.string(from: entry.timestamp))
                                .foregroundStyle(.secondary)
                            Text(entry.message)
                                .foregroundStyle(color(for: entry.kind))
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .id(entry.id)
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color(nsColor: .textBackgroundColor))
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .onChange(of: entries.last?.id) { _, newID in
                guard let newID else { return }
                withAnimation(.easeOut(duration: 0.12)) {
                    proxy.scrollTo(newID, anchor: .bottom)
                }
            }
            .onAppear {
                if let last = entries.last?.id {
                    proxy.scrollTo(last, anchor: .bottom)
                }
            }
        }
    }

    private func color(for kind: LogEntry.Kind) -> Color {
        switch kind {
        case .info:   return .primary
        case .driver: return .secondary
        case .warn:   return .orange
        case .error:  return .red
        }
    }

    private static let timestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()
}
