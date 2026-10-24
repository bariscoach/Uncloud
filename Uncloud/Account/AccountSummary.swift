import Foundation

/// What the account button, its popover and the Account tab show in each state (account-menu plan §3).
/// Pure: the locale and time zone are parameters, so every rule and string is testable.
struct AccountSummary: Equatable {
    enum State: Equatable {
        case hidden
        case loading
        case signedOut
        case signedIn
    }

    let state: State
    let email: String?
    /// The first letter or digit of the email's local part, uppercased. Nil when there isn't one.
    let initial: String?
    let memberSince: Date?

    /// True while there is a signed-in account to show (not hidden, loading or signed out).
    var hasAccount: Bool {
        state == .signedIn
    }

    static func make(mode: AccountMode, phase: AccountModel.Phase, account: UncloudAccount?) -> AccountSummary {
        func summary(_ state: State, email: String? = nil, memberSince: Date? = nil) -> AccountSummary {
            AccountSummary(state: state, email: email, initial: initial(for: email), memberSince: memberSince)
        }

        guard mode != .off else { return summary(.hidden) }
        switch phase {
        case .off:
            return summary(.hidden)
        case .restoring:
            return summary(.loading)
        case .signedOut:
            return summary(.signedOut)
        case .signedIn:
            return summary(.signedIn, email: account?.email, memberSince: account?.createdAt)
        }
    }

    /// The first letter or digit of the local part, uppercased. "name@…" → "B"; "_x@…" → nil; "9a@…" → "9".
    static func initial(for email: String?) -> String? {
        guard let email, let local = email.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false).first,
              let first = local.first, first.isLetter || first.isNumber else {
            return nil
        }
        return String(first).uppercased()
    }

    /// "Member since October 2026", or nil when the creation date isn't known.
    func memberSinceText(locale: Locale = .current, timeZone: TimeZone = .current) -> String? {
        guard let memberSince else { return nil }
        let month = memberSince.formatted(AccountDateText.zoned(Date.FormatStyle().month(.wide).year(), locale: locale, timeZone: timeZone))
        return "Member since \(month)"
    }

    /// The button's accessibility value: the email, or nothing when there is no account.
    var accessibilityValue: String {
        hasAccount ? (email ?? "") : ""
    }
}

/// Date wording for the Account screens. The locale and time zone are parameters so tests can pin them.
enum AccountDateText {
    /// "October 18, 2027".
    static func date(_ date: Date, locale: Locale = .current, timeZone: TimeZone = .current) -> String {
        date.formatted(zoned(Date.FormatStyle(date: .long, time: .omitted), locale: locale, timeZone: timeZone))
    }

    /// The style with the locale and time zone set, for the tests' pinned output.
    static func zoned(_ style: Date.FormatStyle, locale: Locale, timeZone: TimeZone) -> Date.FormatStyle {
        var style = style
        style.locale = locale
        style.timeZone = timeZone
        return style
    }
}
