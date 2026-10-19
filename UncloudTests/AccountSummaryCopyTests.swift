import Foundation
import Testing
@testable import Uncloud

/// The status strings of account-menu plan §2.5, verbatim, in en_US and UTC so the dates are fixed.
@Suite("AccountSummaryCopy")
struct AccountSummaryCopyTests {
    static let locale = Locale(identifier: "en_US")
    static let utc = TimeZone(identifier: "UTC")!

    static func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
    }

    static func summary(_ entitlement: Entitlement, now: Date, error: AccountError? = nil, createdAt: Date? = nil) -> AccountSummary {
        AccountSummary.make(
            mode: .preview,
            phase: .signedIn,
            account: UncloudAccount(id: "u", email: "name@example.com", createdAt: createdAt),
            entitlement: entitlement,
            access: EntitlementPolicy.access(entitlement, now: now),
            lastError: error,
            now: now
        )
    }

    func text(_ summary: AccountSummary) -> String? {
        summary.statusLine(locale: Self.locale, timeZone: Self.utc)?.text
    }

    @Test("Free, never paid: the free sentence")
    func freeNeverPaid() {
        let now = Self.date(2027, 1, 1)
        let summary = Self.summary(.free, now: now)
        #expect(text(summary) == "Export is free. Uncloud Plus adds automatic backups, Browse Backup and more.")
    }

    @Test("Free after a plan ended names the end date")
    func freeEnded() {
        let end = Self.date(2027, 10, 18)
        let entitlement = Entitlement(plan: .free, status: .expired, currentPeriodEnd: end, cancelAtPeriodEnd: false, checkedAt: end)
        #expect(text(Self.summary(entitlement, now: end)) == "Uncloud Plus ended on October 18, 2027.")
    }

    @Test("Plus renewing and ending")
    func plusRenewingAndEnding() {
        let end = Self.date(2027, 10, 18)
        let now = Self.date(2026, 10, 19)
        let renewing = Entitlement(plan: .plus, status: .active, currentPeriodEnd: end, cancelAtPeriodEnd: false, checkedAt: now)
        #expect(text(Self.summary(renewing, now: now)) == "Renews on October 18, 2027.")

        let ending = Entitlement(plan: .plus, status: .active, currentPeriodEnd: end, cancelAtPeriodEnd: true, checkedAt: now)
        #expect(text(Self.summary(ending, now: now)) == "Ends on October 18, 2027. Renewal is off.")
    }

    @Test("Past due names the update date and carries the warning symbol")
    func pastDue() {
        let anchor = Self.date(2027, 10, 18)
        let entitlement = Entitlement(plan: .plus, status: .pastDue, currentPeriodEnd: anchor, cancelAtPeriodEnd: false, checkedAt: anchor)
        let line = Self.summary(entitlement, now: anchor).statusLine(locale: Self.locale, timeZone: Self.utc)
        #expect(line?.text == "Your last payment didn’t go through. Update your card by October 25 to keep Uncloud Plus.")
        #expect(line?.symbol == "exclamationmark.triangle")
        #expect(line?.tone == .warning)
    }

    @Test("Offline grace names the date and carries the offline symbol")
    func offlineGrace() {
        let anchor = Self.date(2027, 10, 18)
        let entitlement = Entitlement(plan: .plus, status: .active, currentPeriodEnd: anchor, cancelAtPeriodEnd: false, checkedAt: anchor)
        let line = Self.summary(entitlement, now: anchor.addingTimeInterval(1)).statusLine(locale: Self.locale, timeZone: Self.utc)
        #expect(line?.text == "Couldn’t check your plan. Uncloud Plus stays on until October 25 while you’re offline.")
        #expect(line?.symbol == "wifi.slash")
        #expect(line?.tone == .secondary)
    }

    @Test("Member since uses the month and year")
    func memberSince() {
        let created = Self.date(2026, 10, 1)
        let summary = Self.summary(.free, now: created, createdAt: created)
        #expect(summary.memberSinceText(locale: Self.locale, timeZone: Self.utc) == "Member since October 2026")
    }

    @Test("The last-checked note names the day without a year")
    func lastChecked() {
        let checked = Self.date(2026, 10, 12)
        let now = Self.date(2026, 10, 14)
        let entitlement = Entitlement(plan: .plus, status: .active, currentPeriodEnd: Self.date(2027, 10, 18), cancelAtPeriodEnd: false, checkedAt: checked)
        let summary = Self.summary(entitlement, now: now, error: .offline)
        #expect(summary.lastCheckedText(locale: Self.locale, timeZone: Self.utc) == "Last checked October 12.")
    }

    @Test("The price line and the delete notice keep their verbatim strings")
    func fixedCopy() {
        #expect(PlanCopy.yearlyPricePlusTax == "$9.99/year + tax")
        #expect(AccountError.confirmationMismatch.message == "The email doesn’t match your Uncloud account.")
        #expect(PlanText.date(Self.date(2027, 10, 18), locale: Self.locale, timeZone: Self.utc) == "October 18, 2027")
    }
}
