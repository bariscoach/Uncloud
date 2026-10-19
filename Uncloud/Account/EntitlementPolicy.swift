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
    /// How long a cached plan is trusted without a successful check. Past this, every paid right ends (M1).
    static let offlineValidity: TimeInterval = 30 * day
    /// How long Plus stays on after the period end, or after the start of a failed payment (H4).
    static let gracePeriod: TimeInterval = 7 * day

    /// `currentPeriodEnd` is the period end while the plan is active. For `pastDue` the server sends the start of the
    /// period whose payment failed, so the grace counts from the failure and not from a renewal Stripe already moved to.
    static func access(_ entitlement: Entitlement, now: Date) -> Access {
        let status = entitlement.status
        let anchor = entitlement.currentPeriodEnd

        if entitlement.plan == .free || status == .none || status == .expired {
            return .free
        }
        // Every paid right, grace included, needs a successful check within the offline window.
        guard now < entitlement.checkedAt.addingTimeInterval(offlineValidity) else {
            return .free
        }
        switch status {
        case .active, .trialing:
            guard let anchor else { return .free }
            if now < anchor {
                return .plus
            }
            // The renewal date passed without a newer check: grace, unless the plan was set not to renew (plan §6.4).
            if entitlement.cancelAtPeriodEnd, status == .active {
                return .free
            }
            return grace(from: anchor, now: now)
        case .pastDue:
            // No anchor means no way to tell how long the payment has failed, so no grace.
            guard let anchor else { return .free }
            return grace(from: anchor, now: now)
        case .canceled:
            // Paid until the period ends, with no grace after it.
            if let anchor, now < anchor {
                return .plus
            }
            return .free
        case .none, .expired:
            return .free
        }
    }

    private static func grace(from anchor: Date, now: Date) -> Access {
        let until = anchor.addingTimeInterval(gracePeriod)
        return now < until ? .plusGrace(until: until) : .free
    }
}
