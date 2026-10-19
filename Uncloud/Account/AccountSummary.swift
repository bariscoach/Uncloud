import Foundation

/// What the account button, its popover and the Account tab show in each state (account-menu plan §3).
/// Pure: the clock, locale and time zone are parameters, so every rule and string is testable.
struct AccountSummary: Equatable {
    enum State: Equatable {
        case hidden
        case loading
        case signedOut
        /// `endedOn` is set when a plan existed and is over.
        case free(endedOn: Date?)
        case plusRenewing(renewsOn: Date)
        /// Still in the period, set not to renew.
        case plusEnding(endsOn: Date)
        case pastDue(updateBy: Date)
        case offlineGrace(until: Date)
    }

    enum PrimaryAction: Equatable {
        case getPlus, manage, updatePayment, checkAgain, signIn, none

        /// The button's title. Nil for `none`.
        var title: String? {
            switch self {
            case .getPlus: "Get Uncloud Plus…"
            case .manage: "Manage Subscription…"
            case .updatePayment: "Update Payment Method…"
            case .checkAgain: "Check Again"
            case .signIn: "Sign In…"
            case .none: nil
            }
        }
    }

    /// The status line under the popover's header and in the Account tab. `symbol` is decorative.
    struct StatusLine: Equatable {
        enum Tone: Equatable { case secondary, warning }
        let text: String
        let symbol: String?
        let tone: Tone
    }

    let state: State
    let email: String?
    /// The first letter or digit of the email's local part, uppercased. Nil when there isn't one.
    let initial: String?
    let memberSince: Date?
    /// "Free" or "Uncloud Plus". Nil while loading or signed out.
    let badge: String?
    /// The warning dot on the account button: payment failed, or the plan couldn't be checked.
    let needsAttention: Bool
    let primary: PrimaryAction
    /// Shown as "Last checked …" when the plan couldn't be checked for over a day while offline.
    let lastCheckedNote: Date?
    /// Receipts and invoices exist: the plan has ever been set up.
    let showsReceipts: Bool
    /// The "Renew automatically" switch: a paid plan with a period end, not past due.
    let showsRenewalToggle: Bool
    /// The plan as the server reported it, so the Account tab can show its price and renewal caption.
    let entitlement: Entitlement

    /// True while there is a signed-in account to show (not hidden, loading or signed out).
    var hasAccount: Bool {
        switch state {
        case .hidden, .loading, .signedOut: false
        default: true
        }
    }

    static func make(
        mode: AccountMode,
        phase: AccountModel.Phase,
        account: UncloudAccount?,
        entitlement: Entitlement,
        access: EntitlementPolicy.Access,
        lastError: AccountError?,
        now: Date
    ) -> AccountSummary {
        func summary(
            _ state: State,
            badge: String? = nil,
            attention: Bool = false,
            primary: PrimaryAction = .none,
            renewalToggle: Bool = false,
            lastChecked: Date? = nil,
            email: String? = nil,
            memberSince: Date? = nil
        ) -> AccountSummary {
            AccountSummary(
                state: state,
                email: email,
                initial: initial(for: email),
                memberSince: memberSince,
                badge: badge,
                needsAttention: attention,
                primary: primary,
                lastCheckedNote: lastChecked,
                showsReceipts: entitlement.status != .none,
                showsRenewalToggle: renewalToggle,
                entitlement: entitlement
            )
        }

        guard mode != .off else { return summary(.hidden) }
        switch phase {
        case .off:
            return summary(.hidden)
        case .restoring:
            return summary(.loading)
        case .signedOut:
            return summary(.signedOut, primary: .signIn)
        case .signedIn:
            break
        }

        let email = account?.email
        let memberSince = account?.createdAt
        let anchor = entitlement.currentPeriodEnd
        // Offline for over a day on a paid plan: say when the plan was last checked.
        var lastChecked: Date?
        if access != .free, lastError == .offline, now.timeIntervalSince(entitlement.checkedAt) > 24 * 60 * 60 {
            lastChecked = entitlement.checkedAt
        }

        if entitlement.status == .pastDue, access != .free {
            let updateBy = (anchor ?? now).addingTimeInterval(EntitlementPolicy.gracePeriod)
            return summary(.pastDue(updateBy: updateBy), badge: plusBadge, attention: true, primary: .updatePayment,
                           email: email, memberSince: memberSince)
        }
        if case let .plusGrace(until) = access {
            return summary(.offlineGrace(until: until), badge: plusBadge, attention: true, primary: .checkAgain,
                           renewalToggle: anchor != nil, lastChecked: lastChecked, email: email, memberSince: memberSince)
        }
        if access == .plus {
            let end = anchor ?? now
            let state: State = entitlement.cancelAtPeriodEnd ? .plusEnding(endsOn: end) : .plusRenewing(renewsOn: end)
            return summary(state, badge: plusBadge, primary: .manage, renewalToggle: anchor != nil,
                           lastChecked: lastChecked, email: email, memberSince: memberSince)
        }
        let endedOn = entitlement.status != .none ? anchor : nil
        return summary(.free(endedOn: endedOn), badge: "Free", primary: .getPlus, email: email, memberSince: memberSince)
    }

    private static let plusBadge = "Uncloud Plus"

    /// The first letter or digit of the local part, uppercased. "name@…" → "B"; "_x@…" → nil; "9a@…" → "9".
    static func initial(for email: String?) -> String? {
        guard let email, let local = email.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false).first,
              let first = local.first, first.isLetter || first.isNumber else {
            return nil
        }
        return String(first).uppercased()
    }

    /// The status line for the state, or nil where there is none.
    func statusLine(locale: Locale = .current, timeZone: TimeZone = .current) -> StatusLine? {
        func long(_ date: Date) -> String { PlanText.date(date, locale: locale, timeZone: timeZone) }
        func short(_ date: Date) -> String { PlanText.monthDay(date, locale: locale, timeZone: timeZone) }
        switch state {
        case .hidden, .loading, .signedOut:
            return nil
        case let .free(endedOn):
            if let endedOn {
                return StatusLine(text: "Uncloud Plus ended on \(long(endedOn)).", symbol: nil, tone: .secondary)
            }
            return StatusLine(
                text: "Export is free. Uncloud Plus adds automatic backups, Browse Backup and more.",
                symbol: nil, tone: .secondary
            )
        case let .plusRenewing(renewsOn):
            return StatusLine(text: "Renews on \(long(renewsOn)).", symbol: nil, tone: .secondary)
        case let .plusEnding(endsOn):
            return StatusLine(text: "Ends on \(long(endsOn)). Renewal is off.", symbol: nil, tone: .secondary)
        case let .pastDue(updateBy):
            return StatusLine(
                text: "Your last payment didn’t go through. Update your card by \(short(updateBy)) to keep Uncloud Plus.",
                symbol: "exclamationmark.triangle", tone: .warning
            )
        case let .offlineGrace(until):
            return StatusLine(
                text: "Couldn’t check your plan. Uncloud Plus stays on until \(short(until)) while you’re offline.",
                symbol: "wifi.slash", tone: .secondary
            )
        }
    }

    /// "Member since October 2026", or nil when the creation date isn't known.
    func memberSinceText(locale: Locale = .current, timeZone: TimeZone = .current) -> String? {
        guard let memberSince else { return nil }
        let month = memberSince.formatted(PlanText.zoned(Date.FormatStyle().month(.wide).year(), locale: locale, timeZone: timeZone))
        return "Member since \(month)"
    }

    /// "Last checked October 12.", for the offline note.
    func lastCheckedText(locale: Locale = .current, timeZone: TimeZone = .current) -> String? {
        guard let lastCheckedNote else { return nil }
        return "Last checked \(PlanText.monthDay(lastCheckedNote, locale: locale, timeZone: timeZone))."
    }

    /// The button's accessibility value: the email, the plan and any problem (plan §1.1).
    var accessibilityValue: String {
        guard let email else { return "" }
        switch state {
        case .free: return "\(email), Free"
        case .plusRenewing, .plusEnding: return "\(email), Uncloud Plus"
        case .pastDue: return "\(email), Uncloud Plus, payment didn’t go through"
        case .offlineGrace: return "\(email), Uncloud Plus, couldn’t check your plan"
        case .hidden, .loading, .signedOut: return ""
        }
    }
}
