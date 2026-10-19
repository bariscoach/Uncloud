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

    @Test("A cached active plan is trusted for 30 days without a check")
    func offlineValidity() {
        let renewal = Self.checked.addingTimeInterval(60 * Self.day)
        let plan = Self.entitlement(periodEnd: renewal)
        let stale = Self.checked.addingTimeInterval(EntitlementPolicy.offlineValidity)
        #expect(EntitlementPolicy.access(plan, now: stale.addingTimeInterval(-1)) == .plus)
        #expect(EntitlementPolicy.access(plan, now: stale) == .plusGrace(until: renewal.addingTimeInterval(EntitlementPolicy.gracePeriod)))
    }

    @Test("Trialing behaves like active")
    func trialing() {
        let plan = Self.entitlement(status: .trialing)
        #expect(EntitlementPolicy.access(plan, now: Self.checked) == .plus)
    }

    @Test("Past due is grace from the period end until the grace period ends")
    func pastDue() {
        let plan = Self.entitlement(status: .pastDue)
        let graceEnd = Self.periodEnd.addingTimeInterval(EntitlementPolicy.gracePeriod)
        #expect(EntitlementPolicy.access(plan, now: Self.periodEnd.addingTimeInterval(1)) == .plusGrace(until: graceEnd))
        #expect(EntitlementPolicy.access(plan, now: graceEnd) == .free)
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
}
