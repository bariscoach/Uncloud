import Foundation
import Testing
@testable import Uncloud

@Suite("EntitlementPolicy")
struct EntitlementPolicyTests {
    private static let day: TimeInterval = 24 * 60 * 60
    private static let periodEnd = Date(timeIntervalSince1970: 1_800_000_000 + 100 * day)
    /// The last successful check, a day before the period ends. The tests' "now" is usually this moment.
    private static let checked = periodEnd.addingTimeInterval(-day)

    private static func entitlement(
        plan: Plan = .plus,
        status: Entitlement.Status = .active,
        periodEnd: Date? = periodEnd,
        checkedAt: Date = checked
    ) -> Entitlement {
        Entitlement(plan: plan, status: status, currentPeriodEnd: periodEnd, cancelAtPeriodEnd: false, checkedAt: checkedAt)
    }

    @Test("An active plan is Plus before the period end")
    func activeBeforeEnd() {
        let plan = Self.entitlement()
        #expect(EntitlementPolicy.access(plan, now: Self.periodEnd.addingTimeInterval(-1)) == .plus)
        #expect(EntitlementPolicy.access(plan, now: Self.checked) == .plus)
    }

    @Test("Active becomes grace at the period end, and free after the grace period")
    func activeToGraceToFree() {
        let plan = Self.entitlement()
        let graceEnd = Self.periodEnd.addingTimeInterval(EntitlementPolicy.gracePeriod)
        #expect(EntitlementPolicy.access(plan, now: Self.periodEnd) == .plusGrace(until: graceEnd))
        #expect(EntitlementPolicy.access(plan, now: graceEnd.addingTimeInterval(-1)) == .plusGrace(until: graceEnd))
        #expect(EntitlementPolicy.access(plan, now: graceEnd) == .free)
    }

    @Test("A cached active plan is trusted for 30 days without a check, then no paid right at all")
    func offlineValidity() {
        let renewal = Self.checked.addingTimeInterval(60 * Self.day)
        let plan = Self.entitlement(periodEnd: renewal)
        let stale = Self.checked.addingTimeInterval(EntitlementPolicy.offlineValidity)
        #expect(EntitlementPolicy.access(plan, now: stale.addingTimeInterval(-1)) == .plus)
        #expect(EntitlementPolicy.access(plan, now: stale) == .free)
    }

    @Test("A blocked network cannot keep Plus through the renewal grace past the 30-day window (M1)")
    func offlineWindowEndsGrace() {
        // Last checked 25 days before the period end. The grace would still run at periodEnd + 1 d (to periodEnd + 7 d),
        // but the check is 26 days old, so the offline window (30 days) has closed.
        let lastCheck = Self.periodEnd.addingTimeInterval(-25 * Self.day)
        // Six days after the period end: the window closed at periodEnd + 5 d, and the grace runs to periodEnd + 7 d.
        let now = Self.periodEnd.addingTimeInterval(6 * Self.day)
        let renewing = Self.entitlement(checkedAt: lastCheck)
        #expect(EntitlementPolicy.access(renewing, now: now) == .free)
        // The same plan within the window still gets the grace.
        #expect(EntitlementPolicy.access(renewing, now: lastCheck.addingTimeInterval(EntitlementPolicy.offlineValidity - 1)) == .plusGrace(until: Self.periodEnd.addingTimeInterval(EntitlementPolicy.gracePeriod)))
        // Canceled and past-due plans are bound by the same window.
        let canceled = Self.entitlement(status: .canceled, checkedAt: lastCheck)
        #expect(EntitlementPolicy.access(canceled, now: lastCheck.addingTimeInterval(Self.day)) == .plus)
        #expect(EntitlementPolicy.access(canceled, now: lastCheck.addingTimeInterval(EntitlementPolicy.offlineValidity)) == .free)
        let pastDue = Self.entitlement(status: .pastDue, checkedAt: lastCheck)
        #expect(EntitlementPolicy.access(pastDue, now: now) == .free)
    }

    @Test("An old signed plan restored from the cache is free once its check is stale")
    func staleCacheIsFree() {
        let oldCheck = Self.periodEnd.addingTimeInterval(-90 * Self.day)
        let plan = Self.entitlement(periodEnd: Self.periodEnd.addingTimeInterval(7 * Self.day), checkedAt: oldCheck)
        #expect(EntitlementPolicy.access(plan, now: Self.periodEnd.addingTimeInterval(-1)) == .free)
    }

    @Test("Trialing behaves like active")
    func trialing() {
        let plan = Self.entitlement(status: .trialing)
        #expect(EntitlementPolicy.access(plan, now: Self.checked) == .plus)
    }

    @Test("Past due is grace from the failed payment's start (the anchor), until 7 days later")
    func pastDue() {
        // The server sends the start of the failed period as the anchor, so the grace is 7 days from the failure.
        let anchor = Self.periodEnd
        let plan = Self.entitlement(status: .pastDue, periodEnd: anchor)
        let graceEnd = anchor.addingTimeInterval(EntitlementPolicy.gracePeriod)
        #expect(EntitlementPolicy.access(plan, now: anchor.addingTimeInterval(1)) == .plusGrace(until: graceEnd))
        #expect(EntitlementPolicy.access(plan, now: graceEnd.addingTimeInterval(-1)) == .plusGrace(until: graceEnd))
        #expect(EntitlementPolicy.access(plan, now: graceEnd) == .free)
    }

    @Test("A failed renewal keeps Plus for 7 days, not for the advanced period (H4)")
    func failedRenewalIsSevenDays() {
        // A renewal that failed 8 days ago: the anchor is the failure date, the period end is a year away.
        let failedOn = Self.periodEnd.addingTimeInterval(-8 * Self.day)
        let advanced = Self.periodEnd.addingTimeInterval(365 * Self.day)
        let plan = Self.entitlement(status: .pastDue, periodEnd: failedOn, checkedAt: failedOn.addingTimeInterval(Self.day))
        #expect(EntitlementPolicy.access(plan, now: failedOn.addingTimeInterval(Self.day)) == .plusGrace(until: failedOn.addingTimeInterval(EntitlementPolicy.gracePeriod)))
        #expect(EntitlementPolicy.access(plan, now: Self.periodEnd) == .free)
        #expect(EntitlementPolicy.access(plan, now: advanced) == .free)
    }

    @Test("Past due without an anchor gets no grace")
    func pastDueWithoutAnchor() {
        let plan = Self.entitlement(status: .pastDue, periodEnd: nil)
        #expect(EntitlementPolicy.access(plan, now: Self.checked) == .free)
    }

    @Test("Canceled is Plus until the period end, with no grace after it")
    func canceled() {
        let plan = Self.entitlement(status: .canceled)
        #expect(EntitlementPolicy.access(plan, now: Self.periodEnd.addingTimeInterval(-1)) == .plus)
        #expect(EntitlementPolicy.access(plan, now: Self.periodEnd) == .free)
    }

    @Test("Free, none and expired are always free")
    func freeCases() {
        #expect(EntitlementPolicy.access(.free, now: Self.checked) == .free)
        #expect(EntitlementPolicy.access(Self.entitlement(status: .none), now: Self.checked) == .free)
        #expect(EntitlementPolicy.access(Self.entitlement(status: .expired), now: Self.checked) == .free)
        #expect(EntitlementPolicy.access(Self.entitlement(plan: .free, status: .active), now: Self.checked) == .free)
    }

    @Test("A plan set not to renew ends at the period end, with no grace")
    func nonRenewingEndsWithoutGrace() {
        let ending = Entitlement(plan: .plus, status: .active, currentPeriodEnd: Self.periodEnd, cancelAtPeriodEnd: true, checkedAt: Self.checked)
        #expect(EntitlementPolicy.access(ending, now: Self.periodEnd.addingTimeInterval(-1)) == .plus)
        #expect(EntitlementPolicy.access(ending, now: Self.periodEnd) == .free)
        #expect(EntitlementPolicy.access(ending, now: Self.periodEnd.addingTimeInterval(EntitlementPolicy.gracePeriod / 2)) == .free)
    }

    @Test("A renewing plan past its period end keeps the grace period")
    func renewingKeepsGrace() {
        let renewing = Entitlement(plan: .plus, status: .active, currentPeriodEnd: Self.periodEnd, cancelAtPeriodEnd: false, checkedAt: Self.checked)
        let graceEnd = Self.periodEnd.addingTimeInterval(EntitlementPolicy.gracePeriod)
        #expect(EntitlementPolicy.access(renewing, now: Self.periodEnd) == .plusGrace(until: graceEnd))
    }
}
