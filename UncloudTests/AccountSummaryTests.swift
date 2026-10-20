import Foundation
import Testing
@testable import Uncloud

/// Every rule of the account summary (account-menu plan §3), at its boundaries. Pure: the clock is a parameter.
@Suite("AccountSummary")
struct AccountSummaryTests {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)
    static let day: TimeInterval = 24 * 60 * 60
    static let account = UncloudAccount(id: "user-1", email: "name@example.com", createdAt: now.addingTimeInterval(-400 * day))

    /// The summary for a signed-in account with `entitlement`, with the access the policy gives at `now`.
    static func signedIn(
        _ entitlement: Entitlement,
        error: AccountError? = nil,
        now: Date = now,
        account: UncloudAccount? = account
    ) -> AccountSummary {
        AccountSummary.make(
            mode: .preview,
            phase: .signedIn,
            account: account,
            entitlement: entitlement,
            access: EntitlementPolicy.access(entitlement, now: now),
            lastError: error,
            now: now
        )
    }

    static func plan(
        _ status: Entitlement.Status,
        periodEnd: Date?,
        cancelAtPeriodEnd: Bool = false,
        checkedAt: Date = now
    ) -> Entitlement {
        Entitlement(
            plan: status == .none || status == .expired ? .free : .plus,
            status: status,
            currentPeriodEnd: periodEnd,
            cancelAtPeriodEnd: cancelAtPeriodEnd,
            checkedAt: checkedAt
        )
    }

    // MARK: - Phases and mode

    @Test("Mode off is hidden even when signed in")
    func offIsHidden() {
        let summary = AccountSummary.make(
            mode: .off, phase: .signedIn, account: Self.account, entitlement: .free,
            access: .free, lastError: nil, now: Self.now
        )
        #expect(summary.state == .hidden)
        #expect(summary.hasAccount == false)
        #expect(summary.primary == .none)
    }

    @Test("Restoring is loading with no primary action")
    func restoringIsLoading() {
        let summary = AccountSummary.make(
            mode: .preview, phase: .restoring, account: nil, entitlement: .free,
            access: .free, lastError: nil, now: Self.now
        )
        #expect(summary.state == .loading)
        #expect(summary.primary == .none)
        #expect(summary.hasAccount == false)
    }

    @Test("Signed out offers Sign In and shows no account data")
    func signedOut() {
        let summary = AccountSummary.make(
            mode: .preview, phase: .signedOut(.welcome), account: nil, entitlement: .free,
            access: .free, lastError: nil, now: Self.now
        )
        #expect(summary.state == .signedOut)
        #expect(summary.primary == .signIn)
        #expect(summary.email == nil)
        #expect(summary.badge == nil)
        #expect(summary.needsAttention == false)
    }

    // MARK: - Free

    @Test("A Free account that never paid offers Get Uncloud Plus and no receipts")
    func freeNeverPaid() {
        let summary = Self.signedIn(.free)
        #expect(summary.state == .free(endedOn: nil))
        #expect(summary.badge == "Free")
        #expect(summary.primary == .getPlus)
        #expect(summary.showsReceipts == false)
        #expect(summary.showsRenewalToggle == false)
        #expect(summary.needsAttention == false)
    }

    @Test("A plan that has ended shows its end date and keeps receipts")
    func freeEnded() {
        let ended = Self.now.addingTimeInterval(-Self.day)
        let summary = Self.signedIn(Self.plan(.expired, periodEnd: ended))
        #expect(summary.state == .free(endedOn: ended))
        #expect(summary.showsReceipts)
        #expect(summary.primary == .getPlus)
    }

    @Test("A canceled plan stays Plus until its period end, then becomes Free at once")
    func canceledEndsAtPeriodEnd() {
        let end = Self.now.addingTimeInterval(Self.day)
        let before = Self.signedIn(Self.plan(.canceled, periodEnd: end))
        #expect(before.state == .plusEnding(endsOn: end))

        let after = Self.signedIn(Self.plan(.canceled, periodEnd: end), now: end.addingTimeInterval(1))
        #expect(after.state == .free(endedOn: end))
        #expect(after.primary == .getPlus)
    }

    // MARK: - Plus

    @Test("Plus renewing shows the renewal date, Manage Subscription and the renewal switch")
    func plusRenewing() {
        let end = Self.now.addingTimeInterval(30 * Self.day)
        let summary = Self.signedIn(Self.plan(.active, periodEnd: end))
        #expect(summary.state == .plusRenewing(renewsOn: end))
        #expect(summary.badge == "Uncloud Plus")
        #expect(summary.primary == .manage)
        #expect(summary.showsRenewalToggle)
        #expect(summary.needsAttention == false)
    }

    @Test("Plus set not to renew is ending, still with the switch")
    func plusEnding() {
        let end = Self.now.addingTimeInterval(30 * Self.day)
        let summary = Self.signedIn(Self.plan(.active, periodEnd: end, cancelAtPeriodEnd: true))
        #expect(summary.state == .plusEnding(endsOn: end))
        #expect(summary.showsRenewalToggle)
        #expect(summary.primary == .manage)
    }

    @Test("One second before the period end is still renewing; one second after is grace")
    func periodEndBoundary() {
        let end = Self.now.addingTimeInterval(1)
        #expect(Self.signedIn(Self.plan(.active, periodEnd: end)).state == .plusRenewing(renewsOn: end))

        let passed = Self.now.addingTimeInterval(-1)
        let late = Self.signedIn(Self.plan(.active, periodEnd: passed))
        #expect(late.state == .offlineGrace(until: passed.addingTimeInterval(EntitlementPolicy.gracePeriod)))
    }

    @Test("Grace ends one second before the grace date and Free one second after")
    func graceBoundary() {
        let anchor = Self.now.addingTimeInterval(-Self.day)
        let until = anchor.addingTimeInterval(EntitlementPolicy.gracePeriod)
        let entitlement = Self.plan(.active, periodEnd: anchor, checkedAt: Self.now)

        let inGrace = Self.signedIn(entitlement, now: until.addingTimeInterval(-1))
        #expect(inGrace.state == .offlineGrace(until: until))
        #expect(inGrace.primary == .checkAgain)
        #expect(inGrace.needsAttention)
        #expect(inGrace.badge == "Uncloud Plus")

        let expired = Self.signedIn(entitlement, now: until.addingTimeInterval(1))
        #expect(expired.state == .free(endedOn: anchor))
    }

    // MARK: - Past due

    @Test("Past due within the grace shows the update date, the warning and Update Payment Method")
    func pastDue() {
        let anchor = Self.now.addingTimeInterval(-Self.day)
        let summary = Self.signedIn(Self.plan(.pastDue, periodEnd: anchor))
        #expect(summary.state == .pastDue(updateBy: anchor.addingTimeInterval(EntitlementPolicy.gracePeriod)))
        #expect(summary.primary == .updatePayment)
        #expect(summary.needsAttention)
        #expect(summary.showsRenewalToggle == false)
        #expect(summary.accessibilityValue == "name@example.com, Uncloud Plus, payment didn’t go through")
    }

    @Test("Past due without a period end gets no grace and is Free")
    func pastDueWithoutAnchor() {
        let summary = Self.signedIn(Self.plan(.pastDue, periodEnd: nil))
        #expect(summary.state == .free(endedOn: nil))
        #expect(summary.needsAttention == false)
    }

    @Test("Past due after the grace is Free")
    func pastDueAfterGrace() {
        let anchor = Self.now.addingTimeInterval(-9 * Self.day)
        let summary = Self.signedIn(Self.plan(.pastDue, periodEnd: anchor))
        #expect(summary.state == .free(endedOn: anchor))
    }

    // MARK: - Offline

    @Test("Offline for over a day on a paid plan says when it was last checked")
    func lastCheckedNoteAfterADay() {
        let checked = Self.now.addingTimeInterval(-Self.day - 1)
        let end = Self.now.addingTimeInterval(30 * Self.day)
        let summary = Self.signedIn(Self.plan(.active, periodEnd: end, checkedAt: checked), error: .offline)
        #expect(summary.lastCheckedNote == checked)
        #expect(summary.lastCheckedText(locale: Locale(identifier: "en_US"), timeZone: TimeZone(identifier: "UTC")!) != nil)
    }

    @Test("Exactly a day offline, and an error that isn't offline, give no last-checked note")
    func lastCheckedNoteBoundary() {
        let end = Self.now.addingTimeInterval(30 * Self.day)
        let exactlyADay = Self.now.addingTimeInterval(-Self.day)
        #expect(Self.signedIn(Self.plan(.active, periodEnd: end, checkedAt: exactlyADay), error: .offline).lastCheckedNote == nil)

        let old = Self.now.addingTimeInterval(-3 * Self.day)
        #expect(Self.signedIn(Self.plan(.active, periodEnd: end, checkedAt: old), error: .server(message: nil)).lastCheckedNote == nil)
        #expect(Self.signedIn(Self.plan(.active, periodEnd: end, checkedAt: old), error: nil).lastCheckedNote == nil)
    }

    @Test("Free never has a last-checked note")
    func freeHasNoLastChecked() {
        let old = Self.now.addingTimeInterval(-3 * Self.day)
        let summary = Self.signedIn(Self.plan(.none, periodEnd: nil, checkedAt: old), error: .offline)
        #expect(summary.lastCheckedNote == nil)
    }

    // MARK: - Initials, receipts and accessibility

    @Test("The initial is the first letter or digit of the local part, uppercased")
    func initials() {
        #expect(AccountSummary.initial(for: "name@example.com") == "N")
        #expect(AccountSummary.initial(for: "_x@example.com") == nil)
        #expect(AccountSummary.initial(for: "9a@example.com") == "9")
        #expect(AccountSummary.initial(for: nil) == nil)
    }

    @Test("The avatar and the value follow the account, and the member date comes from it")
    func profileFields() {
        let summary = Self.signedIn(.free)
        #expect(summary.initial == "N")
        #expect(summary.memberSince == Self.account.createdAt)
        #expect(summary.accessibilityValue == "name@example.com, Free")
        #expect(summary.hasAccount)

        let unknownDate = Self.signedIn(.free, account: UncloudAccount(id: "u", email: "b@example.com"))
        #expect(unknownDate.memberSince == nil)
        #expect(unknownDate.memberSinceText() == nil)
    }

    @Test("In grace, the value says the plan couldn't be checked")
    func offlineValue() {
        let anchor = Self.now.addingTimeInterval(-Self.day)
        let summary = Self.signedIn(Self.plan(.active, periodEnd: anchor, checkedAt: Self.now))
        #expect(summary.accessibilityValue == "name@example.com, Uncloud Plus, couldn’t check your plan")
    }

    @Test("A plan that has never been set up has no receipts")
    func receiptsOnlyAfterAPlan() {
        #expect(Self.signedIn(.free).showsReceipts == false)
        #expect(Self.signedIn(Self.plan(.canceled, periodEnd: Self.now.addingTimeInterval(Self.day))).showsReceipts)
    }
}
