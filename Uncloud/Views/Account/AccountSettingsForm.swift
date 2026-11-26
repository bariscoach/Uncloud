import SwiftUI

/// Settings › Account. Signed out, this offers optional sign-in. Signed in, it shows the profile,
/// sign out and Delete Account. Loading covers the moment a session is restored.
struct AccountSettingsForm: View {
    @Environment(AccountModel.self) private var account
    /// True while an export runs. Sign Out and Delete Account are disabled then, as the model refuses them too.
    var isExporting = false
    @State private var confirmingSignOut = false
    @State private var isDeletingAccount = false

    var body: some View {
        Form {
            switch account.phase {
            case .off:
                EmptyView()
            case .restoring:
                loadingSection
            case .signedOut:
                signedOutSections
            case .signedIn:
                signedInSections
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .confirmationDialog("Sign Out of Uncloud?", isPresented: $confirmingSignOut, titleVisibility: .visible) {
            Button("Sign Out", role: .destructive) {
                Task { await account.signOut() }
            }
        } message: {
            Text("Your photos and backup aren’t changed. You can keep using Uncloud without an account.")
        }
        .sheet(isPresented: authSheetPresented) {
            if case let .signedOut(route) = account.phase {
                AccountFlowView(route: route)
                    .environment(account)
                    .frame(minWidth: 560, minHeight: 560)
            }
        }
        .sheet(isPresented: $isDeletingAccount) {
            DeleteAccountSheet(email: account.account?.email ?? "", isExporting: isExporting)
                .environment(account)
        }
    }

    // MARK: - Restoring

    private var loadingSection: some View {
        Section {
            HStack(spacing: Tokens.Space.s) {
                ProgressView()
                    .controlSize(.small)
                Text("Loading your account…")
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Signed out

    @ViewBuilder
    private var signedOutSections: some View {
        Section("Uncloud Account") {
            if account.notice == .accountDeleted {
                Text("Your Uncloud account was deleted.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Text("Optional. Export, backup, browse and verify all work with no account. Sign in only if you want an Uncloud account.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if account.error == .signedOut {
                Text(account.error?.message ?? "")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button("Sign In…") {
                    account.show(.signUp)
                }
                .buttonStyle(.bordered)
            }
        }
    }

    /// The email and code steps. Dismissing the sheet returns to the app; it does not lock it.
    private var authSheetPresented: Binding<Bool> {
        Binding(
            get: { account.isPresentingAuth },
            set: { presented in
                if !presented { account.dismissAuth() }
            }
        )
    }

    // MARK: - Signed in

    @ViewBuilder
    private var signedInSections: some View {
        let summary = account.summary

        Section("Profile") {
            HStack(alignment: .center, spacing: Tokens.Space.m) {
                AccountAvatar(summary: summary, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(summary.email ?? "")
                        .font(.headline)
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(summary.email ?? "")
                    if let member = summary.memberSinceText() {
                        Text(member)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            changeEmailCaption
            errorRow
        }

        Section {
            Button("Sign Out…", role: .destructive) {
                confirmingSignOut = true
            }
            .disabled(isExporting)
            .help(isExporting ? "Sign out after the export finishes." : "Sign out of Uncloud on this Mac.")
        }

        Section("Delete Account") {
            Button("Delete Account…") {
                account.clearError()
                isDeletingAccount = true
            }
            .buttonStyle(.link)
            .foregroundStyle(Tokens.Status.danger)
            .disabled(isExporting)
            .help(isExporting ? "Delete the account after the export finishes." : "Delete your Uncloud account.")
            Text("Deletes your Uncloud account. Your photos and backup aren’t changed.")
                .font(Tokens.Font.meta)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }

        Section {
            LabeledContent {
                HStack(spacing: Tokens.Space.s) {
                    Link("Terms of Use", destination: AccountLinks.terms(AccountConfiguration.current))
                    Text("·").foregroundStyle(.secondary).accessibilityHidden(true)
                    Link("Privacy Policy", destination: AccountLinks.privacy(AccountConfiguration.current))
                }
                .font(Tokens.Font.meta)
            } label: {
                EmptyView()
            }
        }
    }

    /// "To change your email, contact support." The link is a mailto (plan §5).
    private var changeEmailCaption: some View {
        HStack(spacing: 0) {
            Text("To change your email, ")
            Link("contact support", destination: AccountLinks.support)
            Text(".")
        }
        .font(Tokens.Font.meta)
        .foregroundStyle(.secondary)
    }

    /// A failed account action, under Profile. The delete sheet shows its own errors, so they stay there.
    @ViewBuilder
    private var errorRow: some View {
        if let error = account.error, error != .signedOut, error != .confirmationMismatch, !isDeletingAccount {
            Label(error.message, systemImage: "exclamationmark.triangle")
                .font(.callout)
                .foregroundStyle(Tokens.Status.danger)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
