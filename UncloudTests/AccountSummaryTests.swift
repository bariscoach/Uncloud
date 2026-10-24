import Foundation
import Testing
@testable import Uncloud

/// What the account button, popover and Account tab show in each state, and the wording of the account dates.
@Suite("AccountSummary")
struct AccountSummaryTests {
    static let locale = Locale(identifier: "en_US")
    static let utc = TimeZone(identifier: "UTC")!

    static func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
    }

    static let account = UncloudAccount(id: "u", email: "name@example.com", createdAt: date(2026, 10, 1))

    static func make(_ phase: AccountModel.Phase, mode: AccountMode = .preview, account: UncloudAccount? = account) -> AccountSummary {
        AccountSummary.make(mode: mode, phase: phase, account: account)
    }

    @Test("Mode off is hidden even when signed in")
    func offIsHidden() {
        let summary = Self.make(.signedIn, mode: .off)
        #expect(summary.state == .hidden)
        #expect(summary.hasAccount == false)
    }

    @Test("Restoring is loading, and loading has no account")
    func restoringIsLoading() {
        let summary = Self.make(.restoring)
        #expect(summary.state == .loading)
        #expect(summary.hasAccount == false)
        #expect(summary.email == nil)
    }

    @Test("Signed out shows no account data")
    func signedOutHasNoData() {
        let summary = Self.make(.signedOut(.welcome))
        #expect(summary.state == .signedOut)
        #expect(summary.email == nil)
        #expect(summary.accessibilityValue == "")
    }

    @Test("Signed in shows the email, the initial and the accessibility value")
    func signedInShowsAccount() {
        let summary = Self.make(.signedIn)
        #expect(summary.state == .signedIn)
        #expect(summary.hasAccount)
        #expect(summary.email == "name@example.com")
        #expect(summary.accessibilityValue == "name@example.com")
    }

    @Test("The initial is the first letter or digit of the local part, uppercased")
    func initials() {
        #expect(AccountSummary.initial(for: "name@example.com") == "N")
        #expect(AccountSummary.initial(for: "9a@example.com") == "9")
        #expect(AccountSummary.initial(for: "_x@example.com") == nil)
        #expect(AccountSummary.initial(for: nil) == nil)
    }

    @Test("Member since uses the month and year, and is nil without a creation date")
    func memberSince() {
        let summary = Self.make(.signedIn)
        #expect(summary.memberSinceText(locale: Self.locale, timeZone: Self.utc) == "Member since October 2026")
        let unknown = Self.make(.signedIn, account: UncloudAccount(id: "u", email: "name@example.com"))
        #expect(unknown.memberSinceText(locale: Self.locale, timeZone: Self.utc) == nil)
    }

    @Test("Account dates read as a day in full")
    func accountDate() {
        #expect(AccountDateText.date(Self.date(2027, 10, 18), locale: Self.locale, timeZone: Self.utc) == "October 18, 2027")
    }
}
