// App-wide observable state.
//
// For Phase 1 this carries the install status, the current (in-memory)
// config that the Settings UI binds against, and a snapshot of what's
// on disk so we can flag "Unsaved changes" and provide a Revert action.
// Later phases will fold in ConnectionManager state (.connected /
// .dropped / …) so the views can drive the entire connection lifecycle
// off a single source of truth.

import Foundation
import SwiftUI

@MainActor
final class AppState: ObservableObject {
    @Published var isInstalled: Bool
    @Published var config: Config { didSet { refreshDirty() } }

    /// Owns the live VPN connection. The UI binds against
    /// connectionManager.state for status display + show/hide of
    /// connect/disconnect actions.
    let connectionManager: ConnectionManager

    /// Snapshot of the last successfully-loaded-or-saved config. Backs
    /// `isDirty` and supports Revert without re-hitting disk. Stays in
    /// sync with config every time save/reload runs.
    ///
    /// The `didSet` matters: `saveConfig()` moves *only* this side of
    /// the comparison, and a plain stored property publishes nothing.
    /// Without it the Settings action bar kept rendering the pre-save
    /// state — "Unsaved" dot up, Save/Revert enabled — until some
    /// unrelated change (switching panes) forced a re-render.
    private var savedConfig: Config { didSet { refreshDirty() } }

    /// True once the connection window has been auto-opened at launch,
    /// so the one-shot `.task` on the menu-bar label doesn't re-fire if
    /// the label view is ever re-instantiated. Not @Published: this is a
    /// one-shot lifecycle effect, not observed UI state.
    var didAutoOpenWindow = false

    /// The live AppState, so non-SwiftUI entry points can reach it —
    /// specifically AppDelegate.applicationShouldTerminate, which fires
    /// for ⌘Q / Dock Quit / logout and has no access to the SwiftUI
    /// environment.
    ///
    /// Deliberately strong, and deliberately NOT assigned from `init`.
    /// SwiftUI may evaluate a @StateObject's initializer more than once
    /// and discard all but one instance, so an init-time assignment can
    /// bind a throwaway — which, held weakly, then goes nil and makes
    /// the quit guard silently skip teardown. `bindAsCurrent()` is
    /// instead called from the scene that received the instance SwiftUI
    /// actually kept.
    static private(set) var current: AppState?

    /// Marks this instance as the one non-SwiftUI code should reach for.
    func bindAsCurrent() {
        Self.current = self
    }

    /// True when the in-memory config has unsaved edits. Drives the
    /// "Unsaved changes" indicator and enables Save/Revert in the UI.
    /// Published rather than computed so every transition — in *both*
    /// directions — emits `objectWillChange` on its own.
    @Published private(set) var isDirty: Bool = false

    /// Recomputed from both sides of the comparison. Only assigns on an
    /// actual flip, so per-keystroke config edits don't publish a
    /// redundant `isDirty` change on top of the `config` one.
    private func refreshDirty() {
        let dirty = config != savedConfig
        if isDirty != dirty { isDirty = dirty }
    }

    init() {
        let loaded = ConfigStore.load()
        self.isInstalled = Installer.isInstalled()
        self.config = loaded
        self.savedConfig = loaded
        self.connectionManager = ConnectionManager()
        // Non-blocking. macOS pops the "Packxy wants to send you
        // notifications" alert once, the first time the app runs;
        // subsequent launches are a no-op. If the user denies, drop
        // and success banners just don't show — no other behaviour
        // depends on them.
        Notifications.shared.requestAuthorizationIfNeeded()
    }

    func refreshInstallStatus() {
        isInstalled = Installer.isInstalled()
    }

    func reloadConfig() {
        let loaded = ConfigStore.load()
        config = loaded
        savedConfig = loaded
    }

    func saveConfig() throws {
        try ConfigStore.save(config)
        savedConfig = config
    }

    /// Discards in-memory edits and snaps `config` back to whatever was
    /// last persisted.
    func revertConfig() {
        config = savedConfig
    }
}
