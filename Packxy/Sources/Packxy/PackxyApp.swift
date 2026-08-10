// Packxy — macOS menu-bar app for FortiVPN split tunneling.
//
// Single AppState ObservableObject owns the install status + the
// loaded config; a separate ConnectionManager (also @EnvironmentObject)
// owns the live VPN state. Both are injected into every scene so the
// menu bar, Settings, and Connection windows all bind off the same
// source of truth.

import SwiftUI

enum WindowID {
    static let connection = "packxy.connection"
}

@main
struct PackxyApp: App {
    // Needed for launch provenance (login-item vs user launch) and the
    // disconnect-before-quit guard — neither has a SwiftUI scene-level
    // equivalent. See AppDelegate.
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var appState = AppState()

    var body: some Scene {
        MenuBarExtra {
            MenuBarContent()
                .environmentObject(appState)
                .environmentObject(appState.connectionManager)
        } label: {
            // Wrapped in a dedicated view so the label re-renders on
            // both `appState.isInstalled` AND `connectionManager.state`
            // changes — the latter lives on a separate ObservableObject
            // that PackxyApp itself doesn't observe directly.
            MenuBarLabel()
                .environmentObject(appState)
                .environmentObject(appState.connectionManager)
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsView()
                .environmentObject(appState)
                .environmentObject(appState.connectionManager)
        }

        // Single-instance Window for the connect / reconnect flow.
        // Opened from the menu bar by passing WindowID.connection to
        // `openWindow(id:)`. Resizable so the user can give the OTP
        // field more room if they want, but defaults are tight.
        Window("Packxy", id: WindowID.connection) {
            ConnectionWindow()
                .environmentObject(appState)
                .environmentObject(appState.connectionManager)
        }
        // `.contentMinSize` (not `.contentSize`) so the view's frame
        // sets only the *minimum* — the user can grow the window if
        // they want more room for a long `lastError`, and `defaultSize`
        // actually takes effect on first open (under `.contentSize` it
        // would be ignored in favor of the view's intrinsic size).
        .windowResizability(.contentMinSize)
        // Pin the initial size so the window opens consistently
        // regardless of the connection state at open time — without
        // this, a `.dropped` with a long `lastError` opens fatter than
        // a fresh `.disconnected`.
        .defaultSize(width: 540, height: 340)
        // Centre on the main display on first open. Without this,
        // SwiftUI tends to plonk single-instance Windows at the top
        // edge of whatever display the user last clicked from — fine
        // on a single monitor, off-screen risk on multi-monitor
        // setups when the menu-bar icon lives on a non-main display.
        .defaultPosition(.center)
    }
}

/// Menu-bar icon that mirrors the connection state at a glance, the
/// same way Wi-Fi / Bluetooth do. Keeps the shield silhouette across
/// states so the icon's pixel footprint in the menu bar doesn't shift.
private struct MenuBarLabel: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var connectionManager: ConnectionManager
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        // SwiftUI's MenuBarExtra renders Images at a smaller font size
        // than the AppKit menu-bar icons Apple ships (Wi-Fi, Battery,
        // Volume — all ~18pt tall). 18pt + `.medium` weight matches.
        Image(systemName: iconName)
            .font(.system(size: 18, weight: .medium))
            .accessibilityLabel("Packxy")
            // Auto-open the connection window once at launch. The menu-bar
            // label is the only scene element rendered immediately on a
            // pure-MenuBarExtra agent (the menu *content* isn't built until
            // the user opens the menu), so its `.task` is the reliable spot
            // to fire the launch action.
            .task {
                // Bind the AppDelegate's back-reference to the instance
                // SwiftUI actually kept, before any early return below.
                appState.bindAsCurrent()
                guard !appState.didAutoOpenWindow else { return }
                appState.didAutoOpenWindow = true
                // Login-item launch: menu-bar icon only. Throwing a
                // window on screen while the user is still logging in is
                // hostile, and macOS suppresses focus-stealing by
                // background-launched apps anyway, so it would land
                // buried. `launchedByUser` is set in
                // applicationDidFinishLaunching, which runs before
                // SwiftUI's first view update — so this read is ordered,
                // not a race.
                guard AppDelegate.launchedByUser else { return }
                // Don't pull the window forward if a session is already
                // live (e.g. relaunch while the tunnel is up).
                if case .connected = connectionManager.state { return }
                WindowActivation.present(.connection) {
                    openWindow(id: WindowID.connection)
                }
            }
    }

    private var iconName: String {
        // Install failure trumps everything: if the user can't connect
        // at all, that's what the icon should communicate.
        guard appState.isInstalled else { return "exclamationmark.shield.fill" }
        // Switch on the concrete state (not just the indicator) so a
        // freshly-launched `.disconnected` reads as "neutral / idle"
        // (outline shield), while a `.dropped` reads as "something
        // went wrong" (slashed shield). Folding both into the same
        // `.bad` icon was alarming on first launch.
        switch connectionManager.state {
        case .connected:                  return "shield.lefthalf.filled" // Packxy mark
        case .connecting, .reconnecting:  return "ellipsis.shield.fill"
        case .disconnected:               return "shield"                 // neutral / off
        case .dropped, .authLocked:       return "shield.slash.fill"      // error / blocked
        }
    }
}
