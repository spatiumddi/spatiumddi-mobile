//
//  DeleteConfirmationSheet.swift
//  SpatiumDDI
//

import SwiftUI

/// Deleting something, with the operator typing its name to prove they meant it.
///
/// Non-negotiable #6 says no destructive action lands on a single tap. Two taps
/// clears that bar for most things; deleting a live DNS record does not, because
/// the retraction is pushed to the provider immediately and the name stops
/// resolving before the sheet has finished dismissing.
///
/// The platform uses the same pattern for its own blast-radius operations — a
/// typed-CIDR gate on subnet resize — so this is house style on both sides
/// rather than an invention here.
///
/// Deliberately shows **what will actually happen** rather than "this cannot be
/// undone", because for these two things it is not the same sentence:
///
/// - an IPAM address becomes an `orphan` row that can be re-allocated, but its
///   DNS record is released either way;
/// - a DNS record is restorable from Trash, but stops resolving now.
///
/// Getting that backwards in the copy would be worse than having no copy.
struct DeleteConfirmationSheet: View {
    /// What this deletes, named the way the operator will type it.
    let subject: String
    /// The heading, e.g. "Delete this address?".
    let title: LocalizedStringResource
    /// What happens, stated as fact. Not "are you sure".
    let consequence: LocalizedStringResource
    /// Anything else worth reading first — a warning the server would enforce
    /// anyway, or one it would not.
    var caution: FailureMessage?
    /// Why the delete failed, once it has.
    var failure: FailureMessage?
    var isDeleting: Bool = false
    let onDelete: () -> Void
    let onCancel: () -> Void

    @State private var typed = ""
    @FocusState private var fieldFocused: Bool

    private var matches: Bool { DeleteConfirmation.matches(typed, subject: subject) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label {
                        Text(consequence).font(.callout)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                    }
                    .foregroundStyle(.orange)
                }

                if let caution {
                    Section {
                        Label(caution, systemImage: "info.circle.fill")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                Section {
                    // The value to type, right above the field. Making somebody
                    // go and find it elsewhere turns a safeguard into a puzzle.
                    LabeledContent("Type this") {
                        Text(verbatim: subject)
                            .font(.body.monospaced())
                            .textSelection(.enabled)
                    }
                    TextField("", text: $typed)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.body.monospaced())
                        .focused($fieldFocused)
                } header: {
                    Text("Confirm")
                } footer: {
                    Text("Typing it is the whole confirmation — there is no second prompt.")
                }

                if let failure {
                    Section("Not deleted") {
                        Label(failure, systemImage: "xmark.octagon.fill")
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(Text(title))
            .navigationBarTitleDisplayMode(.inline)
            .dismissableKeyboard()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel, action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isDeleting {
                        ProgressView()
                    } else {
                        Button("Delete", role: .destructive, action: onDelete)
                            .disabled(!matches)
                    }
                }
            }
            .task { fieldFocused = true }
        }
        .interactiveDismissDisabled(isDeleting)
    }
}

/// Whether what was typed clears the gate.
///
/// Extracted from the view because it is the safeguard itself, and a safeguard
/// that is only exercised by tapping through a sheet is one nobody exercises.
nonisolated enum DeleteConfirmation {
    /// Case- and whitespace-insensitive: this is a deliberateness gate, not a
    /// spelling test, and a hostname's case is not meaningful in DNS anyway.
    ///
    /// An empty subject matches **nothing**. Otherwise a row whose name the
    /// server left blank would be deletable by typing nothing at all — the gate
    /// silently absent on exactly the rows least worth guessing about.
    static func matches(_ typed: String, subject: String) -> Bool {
        let target = subject.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else { return false }
        return typed.trimmingCharacters(in: .whitespacesAndNewlines)
            .compare(target, options: [.caseInsensitive]) == .orderedSame
    }
}

#Preview {
    Color.clear.sheet(isPresented: .constant(true)) {
        DeleteConfirmationSheet(
            subject: "10.50.0.1",
            title: "Delete this address?",
            consequence:
                "The address becomes an orphan row in this subnet and can be re-allocated. Its DNS record is deleted either way — the name is released.",
            caution: .app("This address has a DHCP reservation, which is removed with it."),
            onDelete: {}, onCancel: {}
        )
    }
}
