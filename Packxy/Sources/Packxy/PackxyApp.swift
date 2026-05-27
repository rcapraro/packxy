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
    @StateObject private var appState = AppState()

    var body: some Scene {
        MenuBarExtra {
            MenuBarContent()
                .environmentObject(appState)
                .environmentObject(appState.connectionManager)
        } label: {
            // SwiftUI's MenuBarExtra renders Images at a smaller font
            // size than the AppKit menu-bar icons Apple ships (Wi-Fi,
            // Battery, Volume — all ~18pt tall). Setting an explicit
            // 18pt font on the SF Symbol matches that height, and
            // `.medium` weight keeps the thin half-shield outline
            // readable at that scale.
            Image(systemName: menuBarIcon)
                .font(.system(size: 18, weight: .medium))
                .accessibilityLabel("Packxy")
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
        .windowResizability(.contentSize)
        // Centre on the main display on first open. Without this,
        // SwiftUI tends to plonk single-instance Windows at the top
        // edge of whatever display the user last clicked from — fine
        // on a single monitor, off-screen risk on multi-monitor
        // setups when the menu-bar icon lives on a non-main display.
        .defaultPosition(.center)
    }

    private var menuBarIcon: String {
        // Match the Settings sidebar footer for brand consistency: the
        // half-filled shield is the Packxy mark. The warning variant
        // keeps the same silhouette so the icon's location in the menu
        // bar doesn't shift when install status flips.
        appState.isInstalled ? "shield.lefthalf.filled" : "exclamationmark.shield.fill"
    }
}
