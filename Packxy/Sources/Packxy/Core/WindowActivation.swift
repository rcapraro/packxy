// Foreground / activation policy for a menu-bar agent.
//
// Packxy ships LSUIElement=YES, i.e. NSApplicationActivationPolicy
// .accessory: no Dock tile, no main menu. That makes it the weakest
// possible claimant under macOS 14's *cooperative* activation model —
// NSApplication.h is blunt about it: "You shouldn't assume the app will
// be active immediately after sending this message. The framework also
// does not guarantee that the app will be activated at all."
//
// The symptom: `openWindow(id:)` creates the NSWindow but it lands
// behind whatever app had focus and never becomes key, so the OTP field
// swallows no keystrokes. Fixing that needs two halves, and every
// previous attempt (see git 90715e5) only had the first:
//
//   1. Policy — flip to .regular while any Packxy UI window is on
//      screen. A .regular app participates in normal activation and
//      window ordering. Cost: a Dock tile + ⌘-Tab entry appear while a
//      window is up, and vanish when the last one closes.
//   2. Ordering — makeKeyAndOrderFront on the *real* NSWindow, after it
//      exists. Activating before `openWindow(id:)` has produced a window
//      is a no-op: there is nothing to bring forward. Nothing in the app
//      did this before, which is why "activate harder" never stuck.
//
// Windows register themselves via `.packxyWindow(_:)` rather than being
// fished out of `NSApp.windows` by identifier. SwiftUI's NSWindow
// identifiers are undocumented and differ per scene type (`Window(id:)`
// → the scene id; `Settings` → an internal
// "com_apple_SwiftUI_Settings_window"), and `NSApp.windows` is also full
// of NSStatusBarWindow / NSMenu / popover windows that must never count
// toward the .regular/.accessory decision.

import AppKit
import SwiftUI

@MainActor
enum WindowActivation {

    /// The Packxy scenes that count as "real UI windows" — the ones
    /// whose presence on screen justifies a Dock tile.
    enum Scene: Hashable {
        case connection
        case settings
    }

    // MARK: - Presenting

    /// Wraps a window-opening action (`openWindow(id:)` / `openSettings()`).
    ///
    /// Order matters: policy first, so the app is already a .regular
    /// citizen by the time the window is created; then the activation
    /// request; then the open. The decisive `makeKeyAndOrderFront`
    /// happens against a real NSWindow — either the one already cached
    /// (re-open of a live scene) or the one `WindowRegistrar` hands us
    /// moments later, on first open.
    static func present(_ scene: Scene, open: () -> Void) {
        // A window is on its way in, so any revert armed by an earlier
        // close is now wrong. Without this cancel, closing a window and
        // immediately re-opening it (well under the debounce) lets the
        // stale revert fire mid-open, find no window yet — because
        // `openWindow(id:)` creates it asynchronously — and drop us
        // back to .accessory exactly while the new window is being
        // built. That is precisely the bug this file exists to fix.
        cancelPendingRevert()
        setPolicy(.regular)
        // Armed here as well as in `register`, so the safety net below
        // has an observer to work with even if no window ever appears.
        startObservingClosesIfNeeded()
        forceActivate()
        open()
        if let window = windows[scene]?.value {
            bringForward(window)
        }
        // Safety net for the case where `open()` silently does nothing
        // — SwiftUI's `openWindow(id:)` no-ops when the scene graph
        // isn't installed yet. No window means `register` never runs,
        // so nothing else would ever bring us back down: the user is
        // left with a Dock tile and a ⌘-Tab entry for a menu-bar agent
        // that has no window to show. A successful open cancels this.
        scheduleRevert(after: .seconds(2))
    }

    /// Called by `WindowRegistrar` the moment AppKit installs the
    /// NSWindow backing a Packxy scene. Deterministic: no polling, no
    /// identifier matching, no sleep.
    static func register(_ window: NSWindow, for scene: Scene) {
        windows[scene] = WeakWindow(value: window)
        // A real window exists now, so cancel both the close debounce
        // and `present`'s no-window safety net.
        cancelPendingRevert()
        startObservingClosesIfNeeded()
        setPolicy(.regular)
        bringForward(window)
    }

    /// Called from a scene root's `.onAppear`. Covers a re-open where
    /// the NSView never left its NSWindow, so `viewDidMoveToWindow`
    /// doesn't fire a second time — notably `SettingsLink`, which is
    /// opaque by design and can't be routed through `present(_:open:)`.
    static func reveal(_ scene: Scene) {
        guard let window = windows[scene]?.value else { return }
        cancelPendingRevert()
        setPolicy(.regular)
        bringForward(window)
    }

    /// Foreground the app *without* touching the activation policy, for
    /// paths that show no window of ours — today the notification
    /// click. Flipping to .regular here would strand the app with a
    /// Dock tile and nothing to close to get rid of it, since the
    /// revert is driven by a tracked window closing.
    ///
    /// Cooperative `activate()`, not the forceful variant: with no
    /// window and no menu bar to show for it, forcing our way to the
    /// front just takes key status away from whatever the user was
    /// typing in and gives them nothing in return.
    static func activateWithoutWindow() {
        NSApp.activate()
    }

    /// Foreground the app to put a modal NSAlert in front of the user.
    /// Forceful, because an alert genuinely does need the focus — but
    /// still policy-neutral, since an NSAlert is not a tracked window
    /// and must not raise a Dock tile.
    static func activateForModal() {
        forceActivate()
    }

    // MARK: - Internals

    private static var windows: [Scene: WeakWindow] = [:]
    /// The in-flight `.accessory` revert, held as a Task (not a Bool)
    /// so any path that raises a window can cancel it.
    private static var revertTask: Task<Void, Never>?
    private static var observingCloses = false

    private struct WeakWindow {
        weak var value: NSWindow?
    }

    private static func bringForward(_ window: NSWindow, attempt: Int = 0) {
        // One main-runloop hop. At `viewDidMoveToWindow` / `.onAppear`
        // time the NSWindow exists but SwiftUI hasn't finished its own
        // ordering + sizing pass, and ordering front inside that pass
        // gets undone. `Task { @MainActor }` enqueues on the main
        // actor's executor — the next runloop turn — so no `Task.sleep`
        // is needed: we already hold the window, we're only waiting for
        // SwiftUI to stop touching it.
        Task { @MainActor in
            forceActivate()
            window.makeKeyAndOrderFront(nil)
            // Cooperative activation explicitly does not guarantee the
            // app becomes active. When macOS declines, at least put the
            // window in front of the other app's windows rather than
            // leaving it buried — `orderFrontRegardless` bypasses the
            // "only the front app may order windows in" rule.
            if !NSApp.isActive {
                window.orderFrontRegardless()
            }
            // Bounded retry: on a cold launch the WindowServer can still
            // be settling and the makeKey request is dropped. Two extra
            // runloop turns, never a sleep, never unbounded.
            if !window.isKeyWindow && attempt < 2 {
                bringForward(window, attempt: attempt + 1)
            }
        }
    }

    private static func forceActivate() {
        // `activate(ignoringOtherApps:)` carries API_TO_BE_DEPRECATED
        // (no compiler warning today) and is still the only call that
        // reliably foregrounds an agent app. macOS 14's `activate()`
        // honours cooperative-activation yields and silently does
        // nothing when no other app has yielded to us. Reserved for
        // paths that put a window (or an alert) on screen — stealing
        // focus with nothing to show for it is just rude.
        NSApp.activate(ignoringOtherApps: true)
    }

    private static func setPolicy(_ policy: NSApplication.ActivationPolicy) {
        guard NSApp.activationPolicy() != policy else { return }
        NSApp.setActivationPolicy(policy)
    }

    // MARK: - Reverting to .accessory

    private static func startObservingClosesIfNeeded() {
        guard !observingCloses else { return }
        observingCloses = true
        // `willCloseNotification` is the only signal that fires for every
        // close path (red button, ⌘W, `dismissWindow()`) on both scene
        // types. Deliberately NOT `didResignActiveNotification`, which
        // fires on every ⌘-Tab away and would yank the Dock tile out
        // from under a still-open window — reintroducing the original
        // bug on each app switch. Also not SwiftUI `.onDisappear`, which
        // is unreliable across a `Window` scene's close/reopen.
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: nil, queue: .main
        ) { _ in
            Task { @MainActor in scheduleRevert(after: .milliseconds(300)) }
        }
    }

    /// Arms a check that drops us back to `.accessory` once nothing of
    /// ours is on screen. Always re-arms: the previous pending check is
    /// cancelled rather than the new request being dropped, so the last
    /// close always gets evaluated.
    ///
    /// The delay exists for two reasons:
    ///  1. `willClose` posts *before* the window is ordered out, so
    ///     `isVisible` is still true at that instant.
    ///  2. It debounces close-then-reopen (Connection → Settings),
    ///     which would otherwise bounce the Dock tile out and back in.
    private static func scheduleRevert(after delay: Duration) {
        revertTask?.cancel()
        revertTask = Task { @MainActor in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            revertTask = nil
            guard liveWindows.isEmpty else { return }
            setPolicy(.accessory)
        }
    }

    /// Called by every path that raises a window, so a revert armed by
    /// an earlier close can't fire into the middle of a re-open.
    private static func cancelPendingRevert() {
        revertTask?.cancel()
        revertTask = nil
    }

    /// Windows we own that are still on screen. A closed SwiftUI
    /// `Window` scene keeps its NSWindow alive (SwiftUI re-shows the
    /// same instance on the next `openWindow`), so identity alone isn't
    /// enough — `isVisible` is the real signal. `isMiniaturized` counts
    /// as live on purpose: reverting to .accessory would drop the Dock
    /// tile the minimised window lives in, stranding it.
    private static var liveWindows: [NSWindow] {
        windows.values.compactMap(\.value).filter { $0.isVisible || $0.isMiniaturized }
    }
}

// MARK: - Scene attachment

/// Hands the backing NSWindow to `WindowActivation` the moment AppKit
/// installs it. This is the only deterministic hook available:
/// `openWindow(id:)` creates the NSWindow asynchronously, so anything
/// running at the call site runs before the window exists.
private struct WindowRegistrar: NSViewRepresentable {
    let scene: WindowActivation.Scene

    func makeNSView(context: Context) -> NSView {
        let view = TrackingView()
        view.scene = scene
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class TrackingView: NSView {
        var scene: WindowActivation.Scene?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            // Also fires with a nil window when the view is torn down.
            guard let window, let scene else { return }
            WindowActivation.register(window, for: scene)
        }
    }
}

extension View {
    /// Marks this view as the root of a real Packxy UI window: opts it
    /// into the .regular/.accessory policy flip and guarantees it comes
    /// forward and becomes key when it opens.
    func packxyWindow(_ scene: WindowActivation.Scene) -> some View {
        background(WindowRegistrar(scene: scene))
            // Covers a re-open where the NSView never left its NSWindow,
            // so `viewDidMoveToWindow` doesn't fire again.
            .onAppear { WindowActivation.reveal(scene) }
    }
}
