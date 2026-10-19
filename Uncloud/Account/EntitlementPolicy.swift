import Foundation

/// What the cached plan allows, decided by the offline and grace rules (plan D.6). Pure: the clock is a parameter.
enum EntitlementPolicy {
    /// What a paid feature check gets: Plus, Plus during a grace period until a date, or Free.
    enum Access: Equatable, Sendable {
        case plus
        case plusGrace(until: Date)
        case free
    }

    private static let day: TimeInterval = 24 * 60 * 60
    /// How long a cached "active" plan is trusted without a successful check.
    static let offlineValidity: TimeInterval = 30 * day
    /// How long Plus stays on past the period end, or after a failed payment.
    static let gracePeriod: TimeInterval = 7 * day

    static func access(_ entitlement: Entitlement, now: Date) -> Access {
        let status = entitlement.status
        let periodEnd = entitlement.currentPeriodEnd

        if entitlement.plan == .free || status == .none || status == .expired {
            return .free
        }
        // Paid and current, and the last check is recent enough to trust offline.
        if [Entitlement.Status.active, .trialing].contains(status), let periodEnd,
           now < periodEnd, now < entitlement.checkedAt.addingTimeInterval(offlineValidity) {
            return .plus
        }
        // Offline past the renewal date, or a card that failed while Stripe retries it.
        if [Entitlement.Status.active, .trialing, .pastDue].contains(status) {
            let until = (periodEnd ?? entitlement.checkedAt).addingTimeInterval(gracePeriod)
            if now < until {
                return .plusGrace(until: until)
            }
        }
        // Canceled: paid until the period ends, with no grace after it.
        if status == .canceled, let periodEnd, now < periodEnd {
            return .plus
        }
        return .free
    }
}
