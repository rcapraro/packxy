// Generic add/remove text-item editor used for VPN_ROUTES and
// VPN_DOMAINS in the Split tunneling pane.
//
// Each existing item renders as a row with a monospaced label and a
// minus button; a bottom row carries a text field + plus button to
// append new entries. The optional `validate` closure lets the parent
// reject malformed input (e.g. CIDR-shape check) and surface an inline
// error tip without blocking other typing.

import SwiftUI

struct EditableList: View {
    @Binding var items: [String]
    var placeholder: String
    /// Returns `nil` if the value is acceptable, or a short error
    /// message to display under the add field.
    var validate: (String) -> String? = { _ in nil }
    /// Optional transform applied just before insert (e.g. lowercasing
    /// a hostname). Identity by default.
    var normalize: (String) -> String = { $0.trimmingCharacters(in: .whitespaces) }

    @State private var pending: String = ""
    @State private var pendingError: String?
    @FocusState private var addFieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if items.isEmpty {
                // SF symbol prefix signals "no entries yet" visually
                // — without it, the lone "None configured." line
                // could be misread as an actual list entry.
                HStack(spacing: 6) {
                    Image(systemName: "tray")
                        .foregroundStyle(.tertiary)
                    Text("None configured.")
                        .foregroundStyle(.secondary)
                }
                .font(.callout)
            } else {
                ForEach(items.indices, id: \.self) { idx in
                    HStack {
                        Text(items[idx])
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                        Spacer()
                        Button {
                            items.remove(at: idx)
                        } label: {
                            // Larger hit target than the bare 14pt
                            // icon, and a stronger color than
                            // .secondary so the destructive intent
                            // reads at a glance.
                            Image(systemName: "minus.circle.fill")
                                .foregroundStyle(.red.opacity(0.85))
                                .contentShape(Rectangle())
                                .frame(width: 22, height: 22)
                        }
                        .buttonStyle(.borderless)
                        .help("Remove")
                    }
                    .padding(.vertical, 3)
                }
            }

            // No Divider here: the parent Form's grouped style already
            // visually separates the existing-items list from the add
            // row via section spacing.

            HStack {
                // Empty title so the Form's grouped style doesn't
                // promote `placeholder` to a leading label column —
                // the prompt is what should render inside the field
                // as ghosted hint text.
                TextField("", text: $pending, prompt: Text(placeholder))
                    .font(.system(.body, design: .monospaced))
                    .textFieldStyle(.roundedBorder)
                    .focused($addFieldFocused)
                    .onSubmit { tryAdd() }
                Button {
                    tryAdd()
                } label: {
                    Image(systemName: "plus.circle.fill")
                }
                .buttonStyle(.borderless)
                .disabled(pending.trimmingCharacters(in: .whitespaces).isEmpty)
                .help("Add")
            }

            if let err = pendingError {
                // Icon + leading padding align the message with the
                // TextField's text baseline (the .roundedBorder field
                // has ~4pt internal inset). Matches the warning
                // styling used in ConnectionWindow's driver error row.
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                    Text(err)
                }
                .font(.callout)
                .foregroundStyle(.red)
                .padding(.leading, 4)
            }
        }
    }

    private func tryAdd() {
        let value = normalize(pending)
        guard !value.isEmpty else { return }
        if let err = validate(value) {
            pendingError = err
            return
        }
        if items.contains(value) {
            pendingError = "Already in the list."
            return
        }
        items.append(value)
        pending = ""
        pendingError = nil
        // Keep focus on the add field so the user can rapid-fire add
        // multiple entries (Cmd+Tab focus loss after submit is the
        // default and breaks the natural typing flow).
        addFieldFocused = true
    }
}
