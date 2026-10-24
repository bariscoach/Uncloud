import SwiftUI

/// Delete Account (account-menu plan §2.4). The button stays off until the email is typed, and Return never deletes.
/// Cancel is the cancel action (Esc). The sheet closes itself when the account is gone. The Account tab clears the
/// last error before it opens the sheet.
struct DeleteAccountSheet: View {
    let email: String
    let isExporting: Bool
    @Environment(AccountModel.self) private var account
    @Environment(\.dismiss) private var dismiss
    @State private var typed: String

    /// `initialConfirmation` is for previews and snapshots only; the sheet opens empty.
    init(email: String, isExporting: Bool, initialConfirmation: String = "") {
        self.email = email
        self.isExporting = isExporting
        _typed = State(initialValue: initialConfirmation)
    }

    /// The typed email, trimmed and lowercased, equals the account's email lowercased.
    private var matches: Bool {
        typed.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == email.lowercased()
    }

    private var canDelete: Bool {
        matches && !isExporting && !account.isDeletingAccount
    }

    private var deleteHelp: String {
        if isExporting {
            return "Delete the account after the export finishes."
        }
        return matches ? "Delete your Uncloud account." : "Type your email to delete your account."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.l) {
            HStack(alignment: .top, spacing: Tokens.Space.m) {
                Image(systemName: "person.crop.circle.badge.xmark")
                    .font(.system(size: 40))
                    .foregroundStyle(Tokens.Status.danger)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: Tokens.Space.s) {
                    Text("Delete Your Uncloud Account?")
                        .font(.title3.weight(.semibold))
                    Text("This deletes the Uncloud account \(email) and signs you out on this Mac. It can’t be undone.")
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            VStack(alignment: .leading, spacing: Tokens.Space.s) {
                bullet("Your photos, your backup folder and iCloud Photos aren’t changed.")
            }
            .font(.callout)

            VStack(alignment: .leading, spacing: Tokens.Space.xs) {
                Text("Type your email to confirm")
                    .font(.callout)
                TextField("", text: $typed, prompt: Text(email))
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    .accessibilityLabel("Type your email to confirm")
                    .disabled(account.isDeletingAccount)
            }

            if let error = account.error, error != .signedOut {
                Label(error.message, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(Tokens.Status.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: Tokens.Space.s) {
                Spacer()
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                .disabled(account.isDeletingAccount)

                Button(role: .destructive) {
                    Task { await deleteAccount() }
                } label: {
                    if account.isDeletingAccount {
                        HStack(spacing: Tokens.Space.xs) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Deleting…")
                        }
                    } else {
                        Text("Delete Account")
                    }
                }
                .disabled(!canDelete)
                .help(deleteHelp)
            }
        }
        .padding(Tokens.Sheet.padding)
        .frame(width: 420)
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Tokens.Space.s) {
            Text("•")
                .accessibilityHidden(true)
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    private func deleteAccount() async {
        if await account.deleteAccount(confirmEmail: typed) {
            dismiss()
        }
    }
}
