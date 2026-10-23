import SwiftUI

/// The Uncloud account part of the account popover (plan §6.2): who is signed in, the plan, one status line and the
/// actions. Each action closes the popover first, as the menus do.
struct UncloudAccountSection: View {
    let summary: AccountSummary
    let isExporting: Bool
    let close: () -> Void
    @Environment(AccountModel.self) private var account
    @Environment(\.openSettings) private var openSettings
    @FocusState private var primaryFocused: Bool

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
                if let line = summary.statusLine() {
                    PlanStatusText(line: line)
                }
                if let last = summary.lastCheckedText() {
                    Text(last)
                        .font(Tokens.Font.meta)
                        .foregroundStyle(.secondary)
                }

                if let title = summary.primary.title {
                    primaryButton(title)
                }
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
        .onAppear {
            primaryFocused = true
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: Tokens.Space.m) {
            AccountAvatar(summary: summary, size: 40)
            VStack(alignment: .leading, spacing: Tokens.Space.xs) {
                Text(summary.email ?? "")
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .help(summary.email ?? "")
                if let badge = summary.badge {
                    PlanBadge(text: badge)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(headerLabel)
    }

    /// "name@example.com, Uncloud Plus, Renews on October 18, 2027" (plan §6).
    private var headerLabel: String {
        var parts = [summary.email ?? ""]
        if let badge = summary.badge {
            parts.append(badge)
        }
        if let line = summary.statusLine() {
            parts.append(line.text)
        }
        return parts.joined(separator: ", ")
    }

    @ViewBuilder
    private func primaryButton(_ title: String) -> some View {
        let prominent = summary.primary == .getPlus || summary.primary == .updatePayment
        Button(title) {
            perform(summary.primary)
        }
        .applyPrimaryStyle(prominent: prominent)
        .controlSize(.large)
        .frame(maxWidth: .infinity)
        .focused($primaryFocused)
    }

    /// Closes the popover, then does the action. Each action is the one the Account tab and the menus use.
    private func perform(_ action: AccountSummary.PrimaryAction) {
        close()
        switch action {
        case .getPlus:
            account.showPaywall()
        case .manage, .updatePayment:
            Task { await account.openManageSubscription() }
        case .checkAgain:
            Task { await account.refreshEntitlement(force: true) }
        case .signIn, .none:
            break
        }
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

private extension View {
    /// The one primary action is prominent for a new plan or a failed payment, bordered otherwise (plan §3).
    @ViewBuilder
    func applyPrimaryStyle(prominent: Bool) -> some View {
        if prominent {
            self.buttonStyle(.borderedProminent)
        } else {
            self.buttonStyle(.bordered)
        }
    }
}
