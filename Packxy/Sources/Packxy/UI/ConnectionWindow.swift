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
    @EnvironmentObject var metrics: LinkMetricsStore
    @Environment(\.dismissWindow) private var dismissWindow
    /// `.key` when *this* view's NSWindow is the key window. Used to
    /// re-assert OTP focus after AppKit's become-key first-responder
    /// pass — see the `.onChange` at the bottom of `body`.
    @Environment(\.controlActiveState) private var controlActiveState

    @State private var otp: String = ""
    /// Guards the become-key focus re-assert to once per appearance —
    /// see the `.onChange(of: controlActiveState)` at the end of `body`.
    @State private var hasTakenInitialFocus = false
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
        .frame(minWidth: 440, minHeight: 355)
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
        // Opts this window into the .regular/.accessory policy flip and
        // guarantees it comes forward and becomes key when it opens —
        // see WindowActivation. Menu-bar agents (LSUIElement=YES) don't
        // get that for free: the window otherwise shows up behind
        // whatever app had focus and never accepts keyboard input.
        .packxyWindow(.connection)
        .onAppear {
            hasTakenInitialFocus = false
            otpFocused = true
        }
        // `.onAppear` runs *before* the window becomes key, and AppKit
        // installs the window's `initialFirstResponder` at become-key
        // time — clobbering the @FocusState set above. Re-assert once
        // the window is actually key. `controlActiveState` is
        // window-scoped, unlike NSWindow.didBecomeKeyNotification which
        // would also fire when the *Settings* window takes key and would
        // yank the cursor back here.
        //
        // Strictly one-shot per appearance. Re-asserting on *every*
        // transition to `.key` would hijack the caret each time the
        // user came back to the window: in `.dropped` they can click
        // into the (selectable) error text or log to copy a line, and
        // ⌘-Tabbing away and back would rip the selection out from
        // under them and drop the cursor in the OTP field.
        .onChange(of: controlActiveState) { _, state in
            guard state == .key, !hasTakenInitialFocus else { return }
            hasTakenInitialFocus = true
            switch connectionManager.state {
            case .disconnected, .dropped: otpFocused = true
            default: break
            }
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
                          detail: "VPN tunnel is up. Live throughput and the connect log are below — "
                                + "reopen this window any time from the menu bar.")
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
                MetricsBar(history: metrics.history)
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

// MARK: - MetricsBar

/// Live tunnel performance as three stat tiles: a tinted glyph and
/// caption, the figure large with its unit kept quiet beside it, and a
/// sparkline of the last minute underneath.
///
/// The labels say "Down"/"Up" rather than "Speed" on purpose — this is
/// passive throughput, the rate at which bytes are actually crossing
/// ppp0, so an idle tunnel legitimately reads 0 bytes/s. Calling it
/// speed would invite the user to read that zero as a broken link. The
/// sparkline is what tells "quiet" apart from "stalled", which no
/// single number can.
private struct MetricsBar: View {
    /// Oldest first. Empty until the first sample lands, about a second
    /// after connecting.
    let history: [LinkMetrics]

    /// Floors for the sparkline scales, so a nearly-idle tunnel draws a
    /// flat line instead of amplifying byte-level noise into a mountain
    /// range. A graph that always looks dramatic says nothing.
    private static let minimumRateScale: Double = 65_536   // 64 KB/s
    private static let minimumLatencyScale: Double = 50    // ms

    private var latest: LinkMetrics? { history.last }

    /// Down and Up share one scale, deliberately. Scaling each to its
    /// own maximum would draw an idle upstream as busy as a saturated
    /// downstream — the tiles sit side by side and will be read against
    /// each other, so a pixel has to mean the same in both.
    private var rateScale: Double {
        let peak = history.flatMap { [$0.downBytesPerSecond, $0.upBytesPerSecond] }.max() ?? 0
        return max(peak, Self.minimumRateScale)
    }

    private var latencyScale: Double {
        max(history.compactMap(\.latencyMilliseconds).max() ?? 0, Self.minimumLatencyScale)
    }

    var body: some View {
        HStack(spacing: 8) {
            tile(icon: "arrow.down", label: "Down", tint: .teal,
                 parts: LinkMetrics.rateParts(latest?.downBytesPerSecond),
                 series: history.map { $0.downBytesPerSecond }, scale: rateScale)

            tile(icon: "arrow.up", label: "Up", tint: .indigo,
                 parts: LinkMetrics.rateParts(latest?.upBytesPerSecond),
                 series: history.map { $0.upBytesPerSecond }, scale: rateScale)

            tile(icon: "timer", label: "Ping",
                 // The grade means the same thing here as the status
                 // dot's colour does in the menu bar.
                 tint: LinkMetrics.latencyIndicator(latest?.latencyMilliseconds)?.color ?? .secondary,
                 parts: LinkMetrics.latencyParts(latest?.latencyMilliseconds),
                 // Unanswered ticks stay in the series as nils so the
                 // gap shows and the axis keeps step with the two tiles
                 // beside it. Plotting them as zero would draw a dead
                 // probe as a perfect one; dropping them would slide the
                 // rest of the trace across a different span of time.
                 series: history.map(\.latencyMilliseconds), scale: latencyScale,
                 grade: LinkMetrics.latencyIndicator(latest?.latencyMilliseconds))
        }
    }

    private func tile(icon: String,
                      label: String,
                      tint: Color,
                      parts: (value: String, unit: String),
                      series: [Double?],
                      scale: Double,
                      grade: ConnectionState.Indicator? = nil) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            // Text concatenation rather than an HStack so the glyph
            // sits on the caption's baseline instead of being centred
            // against it.
            (Text(Image(systemName: icon)).foregroundStyle(tint)
             + Text("  \(label.uppercased())"))
                .font(.caption2)
                .fontWeight(.medium)
                .tracking(0.6)
                .foregroundStyle(.secondary)

            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(parts.value)
                    // Monospaced digits: proportional ones re-lay the
                    // row out on every sample, and at one sample a
                    // second that reads as the whole bar twitching.
                    .font(.system(size: 20, weight: .medium, design: .rounded).monospacedDigit())
                    // The placeholder stays quiet. At this size and
                    // weight a full-strength em dash is a heavy bar
                    // that out-shouts the tiles which do have a
                    // reading — the opposite of what it should do.
                    .foregroundStyle(parts.value == LinkMetrics.unavailable ? .secondary : .primary)
                if !parts.unit.isEmpty {
                    Text(parts.unit)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Sparkline(values: series, maximum: scale)
                .tint(tint)
                .frame(height: 18)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        // A translucent card, not the text-field surface LogView wears
        // below it — these are readouts, not fields you could type into.
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText(label: label, parts: parts, grade: grade))
    }

    /// The tint is the only thing carrying "this link is bad" to a
    /// sighted user, so the grade has to be said out loud here.
    private func accessibilityText(label: String,
                                   parts: (value: String, unit: String),
                                   grade: ConnectionState.Indicator?) -> String {
        guard parts.value != LinkMetrics.unavailable else { return "\(label): not measured yet" }
        let reading = parts.unit.isEmpty ? parts.value : "\(parts.value) \(parts.unit)"
        guard let grade else { return "\(label): \(reading)" }
        let verdict: String
        switch grade {
        case .ok:   verdict = "good"
        case .warn: verdict = "fair"
        case .bad:  verdict = "poor"
        }
        return "\(label): \(reading), \(verdict)"
    }
}

// MARK: - Sparkline

/// A sparkline over `values`, plotted by index and scaled against
/// `maximum`: a filled area under a stroked line, both taking the
/// ambient tint.
///
/// Hand-rolled rather than a `Chart`. A `Shape` is handed its rect
/// directly, so there's no `GeometryReader`, nothing to lay out, and a
/// 60-point polyline is a dozen lines of `Path` — against the axis,
/// legend and plot-style machinery a chart would need stripped off,
/// three tiles at a time, once a second.
private struct Sparkline: View {
    /// One entry per sample, `nil` where there's no measurement. Nils
    /// break the line rather than being dropped: compacting them would
    /// slide the remaining points across the full width, so this tile's
    /// horizontal axis would cover a different span of time than the
    /// ones beside it.
    let values: [Double?]
    let maximum: Double

    private var hasTrend: Bool { values.compactMap { $0 }.count >= 2 && maximum > 0 }

    var body: some View {
        ZStack {
            if hasTrend {
                // A baseline, so a flat series at the bottom of the band
                // reads as a graph sitting on its floor. Without it, an
                // idle tunnel's line is indistinguishable from a stray
                // horizontal rule under the number.
                Rectangle()
                    .fill(.tint.opacity(0.25))
                    .frame(height: 1)
                    .frame(maxHeight: .infinity, alignment: .bottom)
            }
            Line(values: values, maximum: maximum, closed: true)
                .fill(.tint.opacity(0.18))
            Line(values: values, maximum: maximum, closed: false)
                .stroke(.tint, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
        }
    }

    private struct Line: Shape {
        let values: [Double?]
        let maximum: Double
        /// Closed back down to the baseline, so the same points can be
        /// filled as an area.
        let closed: Bool

        /// Fraction of the band the plot may use, leaving headroom at
        /// the top. A series touching its own maximum would otherwise
        /// graze the figure above it, and the round line cap would clip.
        private static let plotHeightFraction: CGFloat = 0.88

        func path(in rect: CGRect) -> Path {
            var path = Path()
            guard values.count >= 2, maximum > 0 else { return path }

            // The x axis is samples, not seconds. A tick stretched by a
            // latency probe is one even step here; carrying timestamps
            // to correct an 18pt-tall graph isn't worth the arithmetic.
            let step = rect.width / CGFloat(values.count - 1)
            let plotHeight = rect.height * Self.plotHeightFraction

            // Each run of consecutive measurements is its own subpath,
            // so a stretch with no reading leaves a visible gap instead
            // of being bridged by a line that was never measured.
            var run: [CGPoint] = []
            func flushRun() {
                defer { run.removeAll(keepingCapacity: true) }
                // One point is a dot, not a trend.
                guard run.count >= 2, let first = run.first, let last = run.last else { return }
                path.addLines(run)
                guard closed else { return }
                path.addLine(to: CGPoint(x: last.x, y: rect.maxY))
                path.addLine(to: CGPoint(x: first.x, y: rect.maxY))
                path.closeSubpath()
            }

            for (index, value) in values.enumerated() {
                guard let value else {
                    flushRun()
                    continue
                }
                let fraction = min(max(value / maximum, 0), 1)
                run.append(CGPoint(x: rect.minX + CGFloat(index) * step,
                                   y: rect.maxY - plotHeight * CGFloat(fraction)))
            }
            flushRun()
            return path
        }
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
