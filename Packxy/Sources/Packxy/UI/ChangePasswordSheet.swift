import SwiftUI

struct ChangePasswordSheet: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var connectionManager: ConnectionManager
    @Environment(\.dismiss) private var dismiss

    /// Wide enough for a `user@REALM` principal without scrolling.
    private static let fieldWidth: CGFloat = 260

    @State private var principal = ""
    @State private var currentPassword = ""
    @State private var newPassword = ""
    @State private var confirmation = ""
    @State private var updateSavedPassword = true
    @State private var working = false
    @State private var errorMessage: String?
    @State private var succeeded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section {
                    LabeledContent("Account") {
                        TextField("", text: $principal, prompt: Text("jdoe@EXAMPLE.LOCAL"))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: Self.fieldWidth)
                    }
                    LabeledContent("Current password") {
                        SecureField("", text: $currentPassword)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: Self.fieldWidth)
                    }
                    LabeledContent("New password") {
                        SecureField("", text: $newPassword)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: Self.fieldWidth)
                    }
                    LabeledContent("Confirm") {
                        SecureField("", text: $confirmation)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: Self.fieldWidth)
                    }
                    Toggle("Save the new password in Packxy", isOn: $updateSavedPassword)
                } header: {
                    Text("Change domain password")
                } footer: {
                    Text(hint)
                        .font(.callout)
                        .foregroundStyle(hintIsWarning ? .orange : .secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                if let errorMessage {
                    Label(errorMessage, systemImage: "xmark.octagon.fill")
                        .foregroundStyle(.red)
                        .font(.callout)
                        .textSelection(.enabled)
                }
                if succeeded {
                    Label("Password changed.", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.callout)
                }
            }
            .formStyle(.grouped)
            .disabled(working || succeeded)

            HStack {
                if working {
                    ProgressView().controlSize(.small)
                }
                Spacer()
                if succeeded {
                    Button("Done") { dismiss() }
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("Cancel") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                        .disabled(working)
                    Button("Change Password") {
                        Task { await submit() }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSubmit)
                }
            }
            .padding([.horizontal, .bottom], 20)
        }
        .frame(width: 480)
        // The change can't be cancelled once sent to the KDC; closing
        // mid-flight would hide whether the password actually changed.
        .interactiveDismissDisabled(working)
        .onAppear {
            principal = PasswordChange.defaultPrincipal(for: appState.savedConfig)
            currentPassword = appState.savedConfig.password
        }
    }

    private var isConnected: Bool {
        if case .connected = connectionManager.state { return true }
        return false
    }

    private var confirmationMismatch: Bool {
        !confirmation.isEmpty && confirmation != newPassword
    }

    private var hintIsWarning: Bool {
        !isConnected || confirmationMismatch
    }

    private var hint: String {
        if !isConnected {
            return "Connect to the VPN first to reach the domain controller."
        }
        if confirmationMismatch {
            return "The new passwords don't match."
        }
        return "Your current VPN session stays connected."
    }

    private var canSubmit: Bool {
        isConnected
            && !working
            && !principal.trimmingCharacters(in: .whitespaces).isEmpty
            && !currentPassword.isEmpty
            && !newPassword.isEmpty
            && newPassword == confirmation
    }

    private func submit() async {
        guard canSubmit else { return }
        working = true
        errorMessage = nil
        defer { working = false }
        do {
            try await PasswordChange.change(
                principal: principal.trimmingCharacters(in: .whitespaces),
                old: currentPassword,
                new: newPassword
            )
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        succeeded = true
        guard updateSavedPassword else { return }
        do {
            try appState.saveNewPassword(newPassword)
        } catch {
            errorMessage = "The password was changed, but saving it to Packxy failed: \(error.localizedDescription). It's kept as an unsaved edit — use Save (⌘S) to retry."
        }
    }
}
