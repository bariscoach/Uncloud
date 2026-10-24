import SwiftUI

/// The Uncloud account part of the account popover (plan §6.2): who is signed in and the two actions. Each action
/// closes the popover first, as the menus do.
struct UncloudAccountSection: View {
    let summary: AccountSummary
    let isExporting: Bool
    let close: () -> Void
    @Environment(AccountModel.self) private var account
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.m) {
            Text("Uncloud Account")
                .font(Tokens.Font.meta.weight(.semibold))
                .foregroundStyle(.secondary)

            if summary.state == .loading {
                HStack(spacing: Tokens.Space.s) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Loading your account…")
                        .font(Tokens.Font.help)
                        .foregroundStyle(.secondary)
                }
            } else {
                header
                Button("Account Settings…") {
                    close()
                    UserDefaults.standard.set(SettingsTab.account.rawValue, forKey: SettingsTab.storageKey)
                    openSettings()
                    NSApp.activate()
                }
                .buttonStyle(.link)

                Button("Sign Out of Uncloud…") {
                    close()
                    account.isConfirmingSignOut = true
                }
                .buttonStyle(.link)
                .disabled(isExporting)
                .help(isExporting ? "Sign out after the export finishes." : "Sign out of Uncloud on this Mac.")
            }
        }
        .padding(Tokens.Space.l)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: Tokens.Space.m) {
            AccountAvatar(summary: summary, size: 40)
            Text(summary.email ?? "")
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .help(summary.email ?? "")
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(summary.email ?? "")
    }
}

/// The Uncloud account section alone, at a fixed 280 pt width. Kept for the account snapshots until T1 moves them to `AccountFooterPopover`.
struct AccountPopover: View {
    let summary: AccountSummary
    let isExporting: Bool
    let close: () -> Void

    var body: some View {
        UncloudAccountSection(summary: summary, isExporting: isExporting, close: close)
            .frame(width: 280)
    }
}
