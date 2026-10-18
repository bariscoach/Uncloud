import Foundation

/// An export that ended for a reason that usually passes by itself, such as Apple limiting downloads,
/// and will be started again automatically at `resumeAt`.
struct AutoResume: Equatable, Sendable {
    /// Which automatic resume this is, from 1.
    var attempt: Int
    /// When the export is started again (wall-clock time).
    var resumeAt: Date
    /// Why the export stopped, for people: "Apple is limiting downloads".
    var reason: String
    /// The selection override of the run that stopped, such as `.everything` from Export All Photos;
    /// nil for the saved selection.
    var selection: LibrarySelection?
    /// Whether the run that stopped was an automatic backup.
    var automatic: Bool
    /// True once `resumeAt` has passed but the destination's drive isn't connected.
    var isWaitingForDestination = false
}

/// How long automatic resumes wait, and how many there are. Tests use shorter times.
struct AutoResumeTiming: Sendable {
    /// The waits before attempts 1, 2, 3…; the last one repeats.
    var delays: [Duration] = [.seconds(15 * 60), .seconds(30 * 60), .seconds(60 * 60)]
    /// Attempts in a row before giving up: 15 + 30 + 6 × 60 minutes, about 6.75 hours.
    var maxAttempts = 8
    /// A resumed run that downloads at least this many items starts the count again.
    var progressReset = 50
    /// How often a due resume that has to wait (for the drive, or for the last run to stop) checks again,
    /// and the longest a waiting resume sleeps before looking at the clock again.
    var recheckInterval: Duration = .seconds(60)

    /// The wait before `attempt` (from 1).
    func delay(beforeAttempt attempt: Int) -> Duration {
        guard let last = delays.last else { return .zero }
        let index = max(0, attempt - 1)
        return index < delays.count ? delays[index] : last
    }
}

/// Which failures are worth retrying automatically, and in what order.
enum AutoResumePolicy {
    /// True for a run that ended because of something that usually passes by itself: Apple limiting
    /// downloads (503), the network, the bridge being restarted, or iCloud still indexing the library.
    /// Sign-in problems, a full or missing destination, cancelling, and anything else are not retried.
    static func isRetryable(_ error: Error) -> Bool {
        reason(for: error) != nil
    }

    /// The user-facing reason a retryable failure stopped the export, or nil when it isn't retryable.
    static func reason(for error: Error) -> String? {
        guard let error = error as? ICloudError else { return nil }
        switch error {
        case .failed(.serviceUnavailable):
            return "Apple is limiting downloads"
        case .failed(.network):
            return "Your Mac is offline"
        case .failed(.libraryIndexing):
            return "iCloud is still preparing your library"
        case .interrupted:
            return "The connection to iCloud was interrupted"
        default:
            return nil
        }
    }

    /// The attempt that follows a retryable failure, or nil to give up.
    /// - Parameters:
    ///   - previous: The attempt the failed run was started by, or nil when it wasn't an automatic resume.
    ///   - downloaded: Items the failed run downloaded. A resumed run that made progress starts the count again.
    static func nextAttempt(after previous: Int?, downloaded: Int, timing: AutoResumeTiming) -> Int? {
        let base = if let previous, downloaded < timing.progressReset { previous } else { 0 }
        let next = base + 1
        return next <= timing.maxAttempts ? next : nil
    }

    static let gaveUpMessage = "Uncloud stopped trying after several hours. Export again to continue. Photos already backed up are skipped."
}

extension Duration {
    /// The duration in seconds, for date arithmetic.
    var timeInterval: TimeInterval {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
