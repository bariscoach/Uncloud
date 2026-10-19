import AppKit
import SwiftUI

/// Settings › Account: the email, the plan, the renewal switch and the billing portal (plan §5.4, F.6).
/// First section of Settings. Absent in `off` builds, which look exactly as before.
struct AccountSection: View {
    @Environment(AccountModel.self) private var account
    @Environment(\.openWindow) private var openWindow
    /// True while an export runs. Sign Out is disabled then, as the model refuses it too.
    var isExporting = false
    @State private var confirmingSignOut = false

    var body: some View {
        Section("Account") {
            switch account.phase {
            case .off, .restoring:
                EmptyView()
            case .signedOut:
                signedOutRows
            case .signedIn:
                signedInRows
            }
        }
        .confirmationDialog("Sign out of Uncloud?", isPresented: $confirmingSignOut, titleVisibility: .visible) {
            Button("Sign Out", role: .destructive) {
                Task { await account.signOut() }
            }
        } message: {
            Text("Your photos and backup aren’t changed. Sign in again to use Uncloud Plus.")
        }
    }

    // MARK: - Signed out

    private var signedOutRows: some View {
        LabeledContent("Account") {
            HStack {
                Text("Not signed in")
                    .foregroundStyle(.secondary)
                Button("Sign In…") {
                    account.show(.signIn)
                    openWindow(id: "main")
                    NSApp.activate()
                }
            }
        }
    }

    // MARK: - Signed in

    @ViewBuilder
    private var signedInRows: some View {
        let entitlement = account.entitlement

        LabeledContent("Email") {
            Text(account.account?.email ?? "")
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        LabeledContent("Plan") {
            Text(account.access == .free ? "Free" : "Uncloud Plus")
        }

        if account.access == .free {
            freeRows(entitlement)
        } else {
            plusRows(entitlement)
        }

        if let error = account.error, error != .signedOut {
            Label(error.message, systemImage: "exclamationmark.triangle")
                .font(.callout)
                .foregroundStyle(Tokens.Status.danger)
                .fixedSize(horizontal: false, vertical: true)
        }

        LabeledContent {
            // Free accounts have "Already Subscribed? Refresh" above, so only paid accounts get a second one here.
            if account.access != .free {
                Button("Refresh") {
                    Task { await account.refreshEntitlement(force: true) }
                }
                .buttonStyle(.link)
            }
        } label: {
            Text(checkedText)
                .foregroundStyle(.secondary)
        }

        Button("Sign Out…", role: .destructive) {
            confirmingSignOut = true
        }
        .disabled(isExporting)
        .help(isExporting ? "Sign out after the export finishes." : "Sign out of Uncloud on this Mac.")

        #if DEBUG
        if account.mode == .preview {
            debugRows(entitlement)
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

    @ViewBuilder
    private func freeRows(_ entitlement: Entitlement) -> some View {
        if entitlement.status != .none, let end = entitlement.currentPeriodEnd {
            Text("Your Uncloud Plus plan ended on \(PlanText.date(end)).")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
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
    }

    @ViewBuilder
    private func plusRows(_ entitlement: Entitlement) -> some View {
        let access = account.access
        let isPastDue = entitlement.status == .pastDue

        if isPastDue, let end = entitlement.currentPeriodEnd {
            // Retries run for a week after the period end. Renewal can't be turned off while a payment is owed.
            let until = PlanText.date(end.addingTimeInterval(EntitlementPolicy.gracePeriod))
            Label("Your last payment didn’t go through. Update your card by \(until) to keep Uncloud Plus.", systemImage: "exclamationmark.triangle")
                .font(.callout)
                .foregroundStyle(Tokens.Status.warning)
                .fixedSize(horizontal: false, vertical: true)
        } else if case let .plusGrace(until) = access {
            Label("Couldn’t check your plan. Uncloud Plus stays on until \(PlanText.date(until)) while you’re offline.", systemImage: "wifi.slash")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }

        if !isPastDue, let end = entitlement.currentPeriodEnd {
            Toggle("Renew automatically", isOn: renewalBinding)
                .toggleStyle(.switch)
                .disabled(account.isChangingRenewal)
            if account.isChangingRenewal {
                Label("Saving…", systemImage: "arrow.triangle.2.circlepath")
                    .font(Tokens.Font.meta)
                    .foregroundStyle(.secondary)
            } else if entitlement.cancelAtPeriodEnd {
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

        Button("Manage Subscription…") {
            Task { await account.openManageSubscription() }
        }
        .help("Change your card, see receipts, or cancel or renew in the billing page.")
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
