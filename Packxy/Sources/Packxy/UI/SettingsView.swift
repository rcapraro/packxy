// Packxy Settings — bound to the on-disk ~/.config/packxy.conf via
// AppState.config. Save commits to disk and reloads so the in-memory
// state never drifts from the file.
//
// Layout:
//
//   NavigationSplitView
//     ├─ Sidebar (grouped sections, version footer)
//     └─ Detail pane (Form, scrolls if content overflows)
//   GlobalActionBar (sticky bottom — dirty indicator + Revert + Save)
//
// The action bar lives at the SettingsView root rather than inside each
// pane so the dirty indicator + Save/Revert buttons are visible no
// matter which section the user is editing.

import AppKit
import ServiceManagement
import SwiftUI

private enum SettingsSection: String, CaseIterable, Identifiable {
    case general, installation, connection, splitTunneling

    var id: String { rawValue }

    var label: String {
        switch self {
        case .general:        return "General"
        case .installation:   return "Installation"
        case .connection:     return "Connection"
        case .splitTunneling: return "Split tunneling"
        }
    }

    var systemImage: String {
        switch self {
        case .general:        return "gear"
        case .installation:   return "checkmark.shield"
        case .connection:     return "network"
        case .splitTunneling: return "arrow.triangle.branch"
        }
    }

    /// Whether this pane mutates `appState.config`. Drives the
    /// visibility of the global Save/Revert bar — on `.general` and
    /// `.installation` the bar would mislead (no config edits happen
    /// there).
    var editsConfig: Bool {
        switch self {
        case .connection, .splitTunneling: return true
        case .general, .installation:      return false
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject var appState: AppState
    @State private var selection: SettingsSection = .connection
    @State private var saveError: String?

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            VStack(spacing: 0) {
                detailPane
                    .navigationTitle(selection.label)
                // Save bar lives at window level (not per-pane) so the
                // dirty dot + Save / Revert stay visible while the
                // user hops between Connection and Split tunneling.
                // Hidden on `.general` / `.installation` where it
                // would be misleading clutter.
                if selection.editsConfig {
                    actionBar
                }
            }
        }
        // The default NavigationSplitView ships a sidebar-collapse
        // button. In a Settings window (which has no real toolbar) it
        // floats as a stray control at the top of the sidebar — not
        // the look we want. The sidebar is always useful here, so
        // removing the toggle entirely is the right call.
        .toolbar(removing: .sidebarToggle)
        .frame(minWidth: 640, minHeight: 440)
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(spacing: 0) {
            List(selection: $selection) {
                Section("App") {
                    row(.general)
                }
                Section("Components") {
                    row(.installation)
                }
                Section("VPN") {
                    row(.connection)
                    row(.splitTunneling)
                }
            }
            .listStyle(.sidebar)

            Spacer(minLength: 0)

            HStack(spacing: 6) {
                Image(systemName: "shield.lefthalf.filled")
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
                Text("Packxy")
                    .foregroundStyle(.secondary)
                Text(versionString)
                    .foregroundStyle(.tertiary)
                    .font(.callout.monospacedDigit())
            }
            .font(.callout)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 240)
    }

    private func row(_ section: SettingsSection) -> some View {
        Label(section.label, systemImage: section.systemImage)
            .tag(section)
    }

    private var versionString: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let short = info["CFBundleShortVersionString"] as? String ?? "dev"
        return "v\(short)"
    }

    // MARK: - Detail

    @ViewBuilder
    private var detailPane: some View {
        switch selection {
        case .general:        GeneralPane()
        case .installation:   InstallationPane()
        case .connection:     ConnectionPane()
        case .splitTunneling: SplitTunnelingPane()
        }
    }

    // MARK: - Global action bar

    private var actionBar: some View {
        VStack(spacing: 0) {
            // saveError gets its own row above the buttons so a
            // long-ish error message doesn't compete with the dirty
            // dot for the same horizontal slot. Persists until next
            // save / revert.
            if let err = saveError {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                    Text(err)
                        .foregroundStyle(.red)
                        .font(.callout)
                        .lineLimit(2)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 16)
                .padding(.top, 6)
            }

            HStack(spacing: 10) {
                // Minimal dirty indicator: an orange dot instead of
                // verbose "Unsaved changes" text. The disabled/enabled
                // state of Save & Revert already signals editability
                // to anyone who scans the bar.
                if appState.isDirty {
                    Circle()
                        .fill(.orange)
                        .frame(width: 7, height: 7)
                        .accessibilityLabel("Unsaved changes")
                }
                Spacer()
                Button("Revert") {
                    appState.revertConfig()
                    saveError = nil
                }
                .disabled(!appState.isDirty)
                .keyboardShortcut("z", modifiers: [.command])

                Button("Save") {
                    do {
                        try appState.saveConfig()
                        saveError = nil
                    } catch {
                        saveError = error.localizedDescription
                    }
                }
                .disabled(!appState.isDirty)
                .keyboardShortcut("s", modifiers: [.command])
                .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .background(.bar)
        .overlay(alignment: .top) {
            Divider()
        }
    }
}

// MARK: - General pane

private struct GeneralPane: View {
    @State private var loginItemEnabled: Bool = LoginItem.isEnabled
    @State private var loginItemStatus: SMAppService.Status = LoginItem.status
    @State private var loginItemError: String?
    @State private var working = false

    var body: some View {
        Form {
            Section {
                // Standard checkbox toggle. The async work happens in
                // .onChange; if it fails we revert the visual state so
                // the toggle never lies about what's actually
                // registered with launchd.
                Toggle("Launch Packxy at login", isOn: $loginItemEnabled)
                    .disabled(working)
                    .onChange(of: loginItemEnabled) { _, newValue in
                        Task { await applyLoginItem(newValue) }
                    }

                if let err = loginItemError {
                    Label(err, systemImage: "xmark.octagon.fill")
                        .foregroundStyle(.red)
                        .font(.callout)
                }
            } header: {
                Text("Startup")
            } footer: {
                Text("When enabled, Packxy launches automatically when you log in to your Mac.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            // Approval section appears only when macOS is waiting on
            // the user to confirm in System Settings → Login Items.
            // Splitting it out from the Startup section visually
            // signals it's a discrete intermediate state, not a
            // permanent setting.
            if loginItemStatus == .requiresApproval {
                Section("Approval needed") {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "info.circle.fill")
                            .foregroundStyle(.orange)
                        Text("macOS is waiting for you to confirm Packxy in System Settings → Login Items.")
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                    Button("Open Login Items") {
                        LoginItem.openSystemSettingsLoginItems()
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { refresh() }
        // SMAppService doesn't fire a publisher when status changes
        // (e.g. user confirms in System Settings). Refreshing on app
        // re-activation catches the "user toggled in System Settings
        // and switched back" path without polling.
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification)
        ) { _ in
            refresh()
        }
    }

    private func applyLoginItem(_ enable: Bool) async {
        // Avoid loops: if the @State value already matches what
        // LoginItem reports, the change came from `refresh()` and we
        // shouldn't trigger another setEnabled call.
        if enable == LoginItem.isEnabled { return }

        working = true
        defer { working = false }
        do {
            try await LoginItem.setEnabled(enable)
            loginItemError = nil
        } catch {
            loginItemError = error.localizedDescription
            // Revert the visual toggle so it reflects reality.
            loginItemEnabled = LoginItem.isEnabled
        }
        refresh()
    }

    private func refresh() {
        loginItemStatus = LoginItem.status
        loginItemEnabled = LoginItem.isEnabled
    }
}

// MARK: - Connection pane

private struct ConnectionPane: View {
    @EnvironmentObject var appState: AppState
    @State private var showPassword = false

    var body: some View {
        Form {
            Section {
                LabeledContent("Host") {
                    TextField("", text: $appState.config.host,
                              prompt: Text("vpn.example.com"))
                        .textFieldStyle(.roundedBorder)
                }
                LabeledContent("Port") {
                    TextField("", text: $appState.config.port,
                              prompt: Text("443"))
                        .textFieldStyle(.roundedBorder)
                }
            } header: {
                Text("Gateway")
            } footer: {
                Text("Hostname and TCP port of the FortiGate SSL VPN.")
                    .font(.callout).foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("Username") {
                    TextField("", text: $appState.config.user,
                              prompt: Text("jdoe"))
                        .textFieldStyle(.roundedBorder)
                }
                // SecureField rendered with a bordered box (same as
                // the username row) so users can tell at a glance the
                // field is editable. The Show toggle (eye icon) flips
                // to a plain TextField on demand — the user can
                // verify what's stored or paste a new one without
                // ambiguity.
                LabeledContent("Password") {
                    HStack(spacing: 6) {
                        Group {
                            if showPassword {
                                TextField("", text: $appState.config.password)
                            } else {
                                SecureField("", text: $appState.config.password)
                            }
                        }
                        .textFieldStyle(.roundedBorder)

                        Button {
                            showPassword.toggle()
                        } label: {
                            Image(systemName: showPassword ? "eye.slash" : "eye")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.borderless)
                        // `.help()` provides a hover tooltip but
                        // VoiceOver on macOS doesn't read it; the
                        // explicit accessibility label is what makes
                        // the button announce its purpose.
                        .accessibilityLabel(showPassword ? "Hide password" : "Show password")
                        .help(showPassword ? "Hide password" : "Show password")
                    }
                }
            } header: {
                Text("Credentials")
            } footer: {
                Text("Stored in clear text in ~/.config/packxy.conf (perms 0600). OTP is asked at every connect — never persisted.")
                    .font(.callout).foregroundStyle(.secondary)
            }

            Section("Advanced") {
                // SHA-256 fingerprints are 64 hex chars — let the field
                // grow vertically so the user sees the full value at
                // narrow widths. Using the standard label+prompt form
                // (rather than LabeledContent + bare TextField) avoids
                // the Form .grouped style mis-placing the TextField's
                // label to the right of the wrapped value.
                LabeledContent("Trusted cert") {
                    TextField("", text: $appState.config.trustedCert,
                              prompt: Text("sha256 fingerprint"),
                              axis: .vertical)
                        .lineLimit(1...3)
                        .font(.system(.body, design: .monospaced))
                        .textFieldStyle(.roundedBorder)
                }
                LabeledContent("Realm") {
                    TextField("", text: $appState.config.realm,
                              prompt: Text("optional FortiGate realm"))
                        .textFieldStyle(.roundedBorder)
                }
                Toggle("Disable FTM push", isOn: $appState.config.noFTMPush)
                LabeledContent("OTP prompt override") {
                    TextField("", text: $appState.config.otpPrompt,
                              prompt: Text("substring openfortivpn matches"))
                        .textFieldStyle(.roundedBorder)
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Split tunneling pane

private struct SplitTunnelingPane: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        Form {
            Section {
                EditableList(
                    items: $appState.config.vpnRoutes,
                    placeholder: "10.0.0.0/8",
                    validate: validateCIDR
                )
            } header: {
                Text("Routes")
            } footer: {
                Text("CIDR ranges sent through the VPN. Everything else uses the host's default route.")
                    .font(.callout).foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("DNS resolver") {
                    TextField("", text: $appState.config.vpnDNS,
                              prompt: Text("10.0.0.1"))
                        .font(.system(.body, design: .monospaced))
                        .textFieldStyle(.roundedBorder)
                }
                EditableList(
                    items: $appState.config.vpnDomains,
                    placeholder: "internal.example.com",
                    validate: validateDomain,
                    normalize: { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                )
            } header: {
                Text("Split DNS")
            } footer: {
                Text("Internal DNS server and the domains it answers for. Written to /etc/resolver/<domain>.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func validateCIDR(_ value: String) -> String? {
        // Lightweight check: NUM.NUM.NUM.NUM/NUM. Real parsing happens
        // when `route add` runs; this just catches obvious typos.
        let parts = value.split(separator: "/")
        guard parts.count == 2,
              let bits = Int(parts[1]), (0...32).contains(bits) else {
            return "Expected IP/MASK (e.g. 10.0.0.0/8)."
        }
        let octets = parts[0].split(separator: ".")
        guard octets.count == 4,
              octets.allSatisfy({ Int($0).map { (0...255).contains($0) } ?? false }) else {
            return "Invalid IPv4 address."
        }
        return nil
    }

    private func validateDomain(_ value: String) -> String? {
        guard value.contains(".") else {
            return "Expected a domain like internal.example.com."
        }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789.-")
        if value.lowercased().unicodeScalars.contains(where: { !allowed.contains($0) }) {
            return "Domain contains invalid characters."
        }
        return nil
    }
}

// MARK: - Installation pane

private struct InstallationPane: View {
    @EnvironmentObject var appState: AppState
    @State private var working = false
    @State private var resultMessage: String?
    @State private var isError = false
    @State private var openfortivpnPath: String? = try? Installer.findOpenfortivpn()

    var body: some View {
        Form {
            Section("Status") {
                statusRow
                LabeledContent("Sudoers drop-in") {
                    pathRow(Installer.sudoersPath)
                }
                LabeledContent("pppd peer file") {
                    pathRow(Installer.peerPath)
                }
                LabeledContent("openfortivpn") {
                    if let p = openfortivpnPath {
                        pathRow(p)
                    } else {
                        Text("not found — `brew install openfortivpn`")
                            .font(.callout)
                            .foregroundStyle(.red)
                    }
                }
                LabeledContent("Config file") {
                    pathRow(ConfigStore.defaultURL.path)
                }
            }

            Section("Actions") {
                HStack(spacing: 10) {
                    // Two branches so the primary-vs-bordered choice
                    // is unambiguous to the type checker: on a fresh
                    // machine Install is the call-to-action (prominent
                    // tinted button), on a re-run Reinstall is a quiet
                    // secondary action.
                    if appState.isInstalled {
                        Button("Reinstall…") {
                            Task { await runInstall() }
                        }
                        .buttonStyle(.bordered)
                        .disabled(working || openfortivpnPath == nil)
                        .keyboardShortcut(.defaultAction)

                        Button("Uninstall…", role: .destructive) {
                            Task { await runUninstall() }
                        }
                        .disabled(working)
                    } else {
                        Button("Install…") {
                            Task { await runInstall() }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(working || openfortivpnPath == nil)
                        .keyboardShortcut(.defaultAction)
                    }

                    if working {
                        ProgressView().controlSize(.small)
                    }
                    Spacer()
                }
                if let msg = resultMessage {
                    Label(msg, systemImage: isError ? "xmark.octagon.fill" : "checkmark.circle.fill")
                        .foregroundStyle(isError ? .red : .green)
                        .font(.callout)
                }
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private var statusRow: some View {
        // `.body.weight(.medium)` keeps the row legible without
        // shouting; `.headline` was visually heavier than the path
        // rows it sits next to, breaking the form's rhythm.
        if appState.isInstalled {
            Label("Components installed", systemImage: "checkmark.seal.fill")
                .foregroundStyle(.green)
                .font(.body.weight(.medium))
        } else {
            Label("Components missing", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.body.weight(.medium))
        }
    }

    /// Monospaced path + a "Reveal in Finder" button. We let the
    /// path wrap rather than truncate so the user can read every
    /// component — middle-truncation on a 60-char system path is
    /// useless ("…/etc/…/packxy" tells nobody anything).
    private func pathRow(_ path: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(path)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button {
                reveal(path)
            } label: {
                Image(systemName: "arrow.up.right.square")
            }
            .buttonStyle(.borderless)
            .help("Reveal in Finder")
            .disabled(!FileManager.default.fileExists(atPath: path))
        }
    }

    private func reveal(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    private func runInstall() async {
        working = true
        defer { working = false }
        do {
            try await Installer.install()
            appState.refreshInstallStatus()
            openfortivpnPath = try? Installer.findOpenfortivpn()
            isError = false
            resultMessage = "Installed successfully."
        } catch InstallerError.cancelled {
            // No-op: user dismissed the admin prompt.
        } catch {
            isError = true
            resultMessage = error.localizedDescription
        }
    }

    private func runUninstall() async {
        working = true
        defer { working = false }
        do {
            try await Installer.uninstall()
            appState.refreshInstallStatus()
            isError = false
            resultMessage = "Uninstalled."
        } catch InstallerError.cancelled {
            // No-op
        } catch {
            isError = true
            resultMessage = error.localizedDescription
        }
    }
}
