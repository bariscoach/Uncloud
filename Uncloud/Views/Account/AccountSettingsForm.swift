import AppKit
import SwiftUI

/// Settings › Account (account-menu plan §2): profile, subscription, sign out and Delete Account. The sections that
/// show depend on the phase: loading, signed out (with the notice after a deletion) or signed in.
struct AccountSettingsForm: View {
    @Environment(AccountModel.self) private var account
    @Environment(\.openWindow) private var openWindow
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
            Text("Your photos and backup aren’t changed. Sign in again to use Uncloud Plus.")
        }
        .sheet(isPresented: $isDeletingAccount) {
            DeleteAccountSheet(
                email: account.account?.email ?? "",
                isPaid: account.access != .free,
                hadPlan: account.entitlement.status != .none,
                isExporting: isExporting
            )
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
            Text("Sign in to use Uncloud Plus on this Mac. Export is free without an account.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Sign In…") {
                    openMain(.signIn)
                }
                .buttonStyle(.bordered)
                Button("Create Account…") {
                    openMain(.signUp)
                }
                .buttonStyle(.link)
            }
        }
    }

    /// Signed out from Settings: the main window shows the route, and the app comes forward (as before).
    private func openMain(_ route: AccountModel.Route) {
        account.show(route)
        openWindow(id: "main")
        NSApp.activate()
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
        }

        Section("Subscription") {
            LabeledContent("Plan") {
                if let badge = summary.badge {
                    PlanBadge(text: badge)
                }
            }
            // A renewing plan's status repeats the renewal caption under the switch, so only the other states show it here.
            if !isRenewing(summary), let line = summary.statusLine() {
                PlanStatusText(line: line)
            }
            LabeledContent("Price") {
                Text(PlanCopy.yearlyPricePlusTax)
            }
            if summary.showsRenewalToggle {
                renewalRows(summary.entitlement)
            }
            subscriptionActions(summary)
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
            Text("Deletes your Uncloud account and stops Uncloud Plus. Your photos and backup aren’t changed.")
                .font(Tokens.Font.meta)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }

        Section {
            #if DEBUG
            if account.mode == .preview {
                debugRows(summary.entitlement)
            }
            #endif
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

    @ViewBuilder
    private func subscriptionActions(_ summary: AccountSummary) -> some View {
        if summary.primary == .getPlus {
            HStack {
                Button("Get Uncloud Plus…") {
                    account.showPaywall()
                }
                .buttonStyle(.bordered)
                Spacer()
                Button("Already Subscribed? Refresh") {
                    Task { await account.refreshEntitlement(force: true) }
                }
                .buttonStyle(.link)
            }
        } else {
            HStack {
                if let title = summary.primary.title {
                    Button(title) {
                        Task { await account.openManageSubscription() }
                    }
                    .buttonStyle(.bordered)
                    .help("Change your card, see receipts, or cancel or renew in the billing page.")
                }
                Spacer()
                Button("Refresh") {
                    Task { await account.refreshEntitlement(force: true) }
                }
                .buttonStyle(.link)
            }
        }
        if summary.showsReceipts {
            Button("Receipts and Invoices") {
                Task { await account.openManageSubscription() }
            }
            .buttonStyle(.link)
        }
        Text(checkedText)
            .font(Tokens.Font.meta)
            .foregroundStyle(.secondary)
    }

    private func isRenewing(_ summary: AccountSummary) -> Bool {
        if case .plusRenewing = summary.state { return true }
        return false
    }

    /// The renewal switch, its saving state and its caption, for a paid plan with a period end.
    @ViewBuilder
    private func renewalRows(_ entitlement: Entitlement) -> some View {
        Toggle("Renew automatically", isOn: renewalBinding)
            .toggleStyle(.switch)
            .disabled(account.isChangingRenewal)
        if account.isChangingRenewal {
            Label("Saving…", systemImage: "arrow.triangle.2.circlepath")
                .font(Tokens.Font.meta)
                .foregroundStyle(.secondary)
        } else if let end = entitlement.currentPeriodEnd {
            if entitlement.cancelAtPeriodEnd {
                Text("Uncloud Plus ends on \(PlanText.date(end)). Turn on renewal to keep it.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Renews on \(PlanText.date(end)) for \(PlanCopy.price) plus tax.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// A failed account action, under Subscription. The delete sheet shows its own errors, so they stay there.
    @ViewBuilder
    private var errorRow: some View {
        if let error = account.error, error != .signedOut, error != .confirmationMismatch, !isDeletingAccount {
            Label(error.message, systemImage: "exclamationmark.triangle")
                .font(.callout)
                .foregroundStyle(Tokens.Status.danger)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The switch shows the saved renewal; it springs back if the server refuses the change.
    private var renewalBinding: Binding<Bool> {
        Binding(
            get: { !account.entitlement.cancelAtPeriodEnd },
            set: { autoRenew in
                Task { await account.setAutoRenew(autoRenew) }
            }
        )
    }

    /// "Plan checked today at 9:41." The time of the last server answer.
    private var checkedText: String {
        let checked = account.entitlement.checkedAt
        guard checked != .distantPast else {
            return "Plan not checked yet."
        }
        let time = checked.formatted(date: .omitted, time: .shortened)
        if Calendar.current.isDateInToday(checked) {
            return "Plan checked today at \(time)."
        }
        return "Plan checked \(checked.formatted(date: .abbreviated, time: .omitted)) at \(time)."
    }

    #if DEBUG
    /// Preview builds only: the renewal switch and "Expire Now", so the states can be checked by hand.
    @ViewBuilder
    private func debugRows(_ entitlement: Entitlement) -> some View {
        if entitlement.status == .active {
            Button(entitlement.cancelAtPeriodEnd ? "Turn Renewal On (Preview)" : "Turn Renewal Off (Preview)") {
                Task { await account.setAutoRenew(entitlement.cancelAtPeriodEnd) }
            }
        }
        Button("Expire Now (Preview)") {
            account.debugExpireNow()
        }
    }
    #endif
}
