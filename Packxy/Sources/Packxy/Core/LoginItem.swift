// Launch-at-login helper backed by SMAppService (macOS 13+).
//
// SMAppService.mainApp is the modern, sandbox-friendly replacement
// for the deprecated SMLoginItemSetEnabled API. Registration is
// per-bundle-identifier so simply moving the .app or renaming it
// will break the registration — users typically install to
// /Applications/Packxy.app once and forget.
//
// First-time toggle quirk:
//   register() returns successfully but `status` becomes
//   `.requiresApproval`, and macOS automatically opens System
//   Settings → Login Items so the user can confirm. The UI surfaces
//   that intermediate state with a "Confirmation needed" hint plus
//   a button to (re)open Login Items in case the user dismissed it.

import AppKit
import Foundation
import ServiceManagement

enum LoginItemError: LocalizedError {
    case registerFailed(String)
    case unregisterFailed(String)

    var errorDescription: String? {
        switch self {
        case .registerFailed(let s):   return "Could not register: \(s)"
        case .unregisterFailed(let s): return "Could not unregister: \(s)"
        }
    }
}

enum LoginItem {
    /// Current registration status. Mirrors SMAppService.Status.
    static var status: SMAppService.Status {
        SMAppService.mainApp.status
    }

    /// True when macOS will launch Packxy at the next login. False
    /// for every other state, including `.requiresApproval` (the
    /// user must confirm in System Settings → Login Items).
    static var isEnabled: Bool {
        status == .enabled
    }

    /// Toggles the login item registration. Throws a typed error so
    /// the UI can surface "registration failed" with the underlying
    /// reason (typically: app isn't in /Applications, or it's not
    /// code-signed in a way macOS accepts).
    static func setEnabled(_ enable: Bool) async throws {
        let service = SMAppService.mainApp
        if enable {
            do {
                try service.register()
            } catch {
                throw LoginItemError.registerFailed(error.localizedDescription)
            }
        } else {
            do {
                try await service.unregister()
            } catch {
                throw LoginItemError.unregisterFailed(error.localizedDescription)
            }
        }
    }

    /// Opens System Settings on the Login Items pane. macOS does
    /// this automatically on first register() but the user can
    /// dismiss it; this gives them an explicit way back.
    static func openSystemSettingsLoginItems() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }
}
