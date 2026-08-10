// Minimal NSApplicationDelegate.
//
// SwiftUI covers nearly everything Packxy needs, but two things have no
// scene-level equivalent, and both become necessary once the app starts
// flipping between .accessory and .regular (see WindowActivation):
//
//   • Launch provenance — we don't auto-open the connection window when
//     macOS starts us as a login item: the menu-bar icon is enough, and
//     a window that grabs the screen while the user is still logging in
//     is hostile.
//   • Quit teardown — in .regular mode the main menu's Quit item makes
//     ⌘Q live, and it terminates directly, bypassing the menu-bar
//     item's confirmation. `applicationShouldTerminate` is the one
//     choke point that covers ⌘Q, the Dock menu, the menu-bar item, and
//     logout/shutdown alike.

import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    /// Four-char codes we'd otherwise have to `import Carbon` for.
    /// Spelled out because the Carbon module's availability from an SPM
    /// target is not something we want to depend on.
    private enum AECode {
        static let coreClass = AEEventClass(0x6165_7674)  // 'aevt'
        static let openApplication = AEEventID(0x6F61_7070)  // 'oapp'
        static let quitApplication = AEEventID(0x7175_6974)  // 'quit'
        /// Present on the 'quit' event only when macOS itself is
        /// terminating us (logout / restart / shutdown), carrying the
        /// reason. A user-initiated ⌘Q has no such attribute.
        static let quitReason = AEKeyword(0x7768_793F)  // 'why?'
    }

    /// How long teardown gets between the user confirming Quit and the
    /// app exiting anyway. A backstop, not a budget: it only matters if
    /// the reply below never gets scheduled.
    private static let teardownDeadline: Duration = .seconds(10)

    /// False when macOS started us as a login item rather than from a
    /// user launch. Read by `MenuBarLabel`'s launch `.task`, which runs
    /// after `applicationDidFinishLaunching`, so the read is ordered.
    private(set) static var launchedByUser = true

    private var didReplyToTermination = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.launchedByUser = Self.looksLikeUserLaunch(notification)
    }

    /// Best-effort launch provenance, biased to say "user launch".
    ///
    /// `NSApplicationLaunchIsDefaultLaunchKey` alone is NOT a
    /// login-item test — NSApplication.h documents it as false for a
    /// login item *and* for opening a file, performing a Service, an
    /// untargeted Apple Event, or "if the app had saved application
    /// state that will be restored". That last case fires on an
    /// ordinary user launch after a quit with saved state, and keying
    /// off it alone would silently kill the launch auto-open.
    ///
    /// So we require a second, positive signal: LaunchServices sends
    /// 'aevt'/'oapp' when a *user* launches an app, and launchd exec's
    /// a login item with no Apple Event at all. Only when both say
    /// "not a user launch" do we suppress the window. Getting this
    /// wrong therefore means showing the window when we could have
    /// stayed quiet — never the reverse.
    private static func looksLikeUserLaunch(_ notification: Notification) -> Bool {
        let isDefaultLaunch = notification.userInfo?[
            NSApplication.launchIsDefaultUserInfoKey
        ] as? Bool ?? true
        if isDefaultLaunch { return true }

        let event = NSAppleEventManager.shared().currentAppleEvent
        return event?.eventClass == AECode.coreClass
            && event?.eventID == AECode.openApplication
    }

    /// True when macOS is terminating us (logout, restart, shutdown)
    /// rather than the user quitting Packxy itself. Detected via the
    /// 'why?' attribute macOS attaches to the 'quit' Apple Event.
    private static var isSystemInitiatedQuit: Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent,
              event.eventClass == AECode.coreClass,
              event.eventID == AECode.quitApplication
        else { return false }
        return event.attributeDescriptor(forKeyword: AECode.quitReason) != nil
    }

    /// AppKit's default is already false, but the app now carries a Dock
    /// tile part of the time and the guarantee is worth one line:
    /// closing the connection window must never kill the agent.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    // Deliberately no `applicationShouldHandleReopen`. Ordering a
    // cached NSWindow front behind SwiftUI's back leaves the `Window`
    // scene's presentation state stale, so the window's own Close
    // button stops working — and it would re-open a window the user
    // deliberately closed. AppKit's default handling (deminiaturize
    // what's actually there) is both correct and what the user meant.

    /// Tears the tunnel down before the process exits, confirming first
    /// when there's an established session the user would notice losing.
    ///
    /// Teardown is gated on `needsTeardown`, not on `.connected`: a
    /// `.dropped` or in-flight session still owns /etc/resolver files
    /// and routes, and exiting without cleaning those up leaves the
    /// user's internal domains resolving through a dead tunnel.
    func applicationShouldTerminate(
        _ sender: NSApplication
    ) -> NSApplication.TerminateReply {
        guard let manager = AppState.current?.connectionManager,
              manager.needsTeardown
        else { return .terminateNow }

        // Confirm only for a session the user is actively using, and
        // only when they asked to quit. During logout/restart/shutdown
        // a modal here would block the whole shutdown behind a dialog
        // that — for a windowless .accessory agent — can end up behind
        // another app, producing "Packxy prevented logout from
        // completing". System-initiated quits tear down silently.
        if case .connected = manager.state, !Self.isSystemInitiatedQuit {
            // Not routed through WindowActivation.present(_:): an
            // NSAlert is not a tracked window, so flipping to .regular
            // here would leave a Dock tile with nothing to close.
            WindowActivation.activateForModal()
            let alert = NSAlert()
            alert.messageText = "Disconnect VPN and quit Packxy?"
            alert.informativeText = "The tunnel will be torn down before the app exits."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Quit")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else {
                return .terminateCancel
            }
        }

        // `.terminateLater` parks termination until we reply, so the
        // tunnel (routes, /etc/resolver entries, ppp0) comes down
        // before AppKit pulls the process out from under it.
        Task { @MainActor [weak self] in
            await manager.stop()
            self?.replyToTerminationOnce()
        }
        // Backstop: the reply above is the only thing that can un-park
        // termination, and it depends on a main-actor continuation
        // being drained while AppKit spins in modal run-loop mode.
        // Without this, a missed hop leaves Packxy half-quit forever —
        // no window, an unresponsive menu-bar item, and ⌘Q inert
        // because the app is already terminating — forcing a Force Quit
        // that skips the very teardown this dance exists to protect.
        // Detached so the timer isn't queued behind the teardown it is
        // supposed to be watching.
        Task.detached {
            try? await Task.sleep(for: Self.teardownDeadline)
            await MainActor.run { [weak self] in
                guard let self, !self.didReplyToTermination else { return }
                NSLog("packxy: teardown did not finish in time; quitting anyway")
                self.replyToTerminationOnce()
            }
        }
        return .terminateLater
    }

    private func replyToTerminationOnce() {
        guard !didReplyToTermination else { return }
        didReplyToTermination = true
        NSApp.reply(toApplicationShouldTerminate: true)
    }
}
