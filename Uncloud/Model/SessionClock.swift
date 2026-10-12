import Foundation

/// Measures active (unpaused) export time to estimate the time remaining.
struct SessionClock {
    private var accumulated: Duration = .zero
    private var runningSince: ContinuousClock.Instant?
    private var itemsFinished = 0

    mutating func start() {
        if runningSince == nil {
            runningSince = .now
        }
    }

    mutating func pause() {
        if let runningSince {
            accumulated += runningSince.duration(to: .now)
            self.runningSince = nil
        }
    }

    /// Starts measuring afresh, so time spent on items that don't count isn't averaged in.
    mutating func discardSamples() {
        accumulated = .zero
        itemsFinished = 0
        if runningSince != nil {
            runningSince = .now
        }
    }

    mutating func itemsDidFinish(_ count: Int) {
        itemsFinished += count
    }

    func estimate(remainingItems: Int) -> Duration? {
        // A few samples keep the first estimate from swinging wildly.
        guard itemsFinished >= 3, remainingItems > 0 else { return nil }
        let elapsed = accumulated + (runningSince.map { $0.duration(to: .now) } ?? .zero)
        return elapsed / itemsFinished * remainingItems
    }
}
