import Foundation

/// One row of Export History: the attempts of one export chain (a run and its automatic or prompt manual
/// resumes), oldest attempt first.
struct ExportHistoryChain: Identifiable, Equatable, Sendable {
    /// How the row's result reads.
    enum Badge: Equatable, Sendable {
        case running
        case completed
        case completedWithFailures(Int)
        case cancelled
        /// Stopped by an error; `reason` is for people, such as "Apple is limiting downloads".
        case stopped(reason: String?)
        case interrupted
        /// Waiting for the automatic resume that `ExportModel.autoResume` has scheduled.
        case resuming(at: Date)
    }

    /// The chain ID.
    let id: UUID
    let attempts: [ExportSession]
    let badge: Badge

    var first: ExportSession { attempts[0] }
    var latest: ExportSession { attempts[attempts.count - 1] }
    var startedAt: Date { first.startedAt }
    /// When the latest attempt ended; nil while it runs.
    var endedAt: Date? { latest.endedAt }

    /// Items downloaded from iCloud or exported from the Photos library, over every attempt.
    var exported: Int { attempts.reduce(0) { $0 + $1.counts.exported } }
    var failed: Int { latest.counts.failed }
    var bytesWritten: Int { attempts.reduce(0) { $0 + $1.counts.bytesWritten } }
    /// Items that were already on the drive when the chain started, from its first drive check.
    var alreadyThere: Int? { first.driveCheck?.onDrive }
    /// True when an attempt was started by automatic backup or automatic resume.
    var isAutomatic: Bool {
        attempts.contains { $0.trigger == .automaticBackup || $0.trigger == .autoResume }
    }
    /// True when a newer Uncloud wrote an attempt; it's shown, never changed.
    var isReadOnly: Bool { attempts.contains(where: \.isReadOnly) }

    /// "Completed", "Completed with 12 failures", "Cancelled", "Stopped: Apple is limiting downloads",
    /// "Interrupted", "Resuming at 15:10".
    var badgeText: String {
        switch badge {
        case .running: "Running"
        case .completed: "Completed"
        case .completedWithFailures(let count): "Completed with \(count.formatted()) \(count == 1 ? "failure" : "failures")"
        case .cancelled: "Cancelled"
        case .stopped(let reason?): "Stopped: \(reason)"
        case .stopped(nil): "Stopped"
        case .interrupted: "Interrupted"
        case .resuming(let date): "Resuming at \(ExportModel.resumeTimeText(date))"
        }
    }

    /// "1,204 downloaded · 9,207 already there · 3 failed · 4.1 GB", leaving out what's zero or unknown.
    /// Photos library exports read "exported"; iCloud downloads read "downloaded".
    var countsText: String {
        var parts = ["\(exported.formatted()) \(latest.source == .photosLibrary ? "exported" : "downloaded")"]
        if let alreadyThere, alreadyThere > 0 {
            parts.append("\(alreadyThere.formatted()) already there")
        }
        if failed > 0 {
            parts.append("\(failed.formatted()) failed")
        }
        if bytesWritten > 0 {
            parts.append(ByteCountFormatter.string(fromByteCount: Int64(bytesWritten), countStyle: .file))
        }
        return parts.joined(separator: " · ")
    }

    /// "3 attempts", or nil for one.
    var attemptsText: String? {
        attempts.count > 1 ? "\(attempts.count) attempts" : nil
    }
}

enum ExportHistory {
    /// Groups sessions into chains, newest chain first (by its latest attempt's start). `pendingResume` is the
    /// model's scheduled automatic resume: the newest chain shows "Resuming at…" while its latest attempt ended
    /// into that resume. Without one, the same attempt reads as stopped, which stays true if the app quit.
    static func chains(from sessions: [ExportSession], pendingResume: AutoResume? = nil) -> [ExportHistoryChain] {
        let grouped = Dictionary(grouping: sessions, by: \.chainID)
        let chains = grouped.map { chainID, members in
            let attempts = members.sorted { lhs, rhs in
                lhs.attempt != rhs.attempt ? lhs.attempt < rhs.attempt : lhs.startedAt < rhs.startedAt
            }
            return ExportHistoryChain(id: chainID, attempts: attempts, badge: badge(for: attempts[attempts.count - 1]))
        }
        var ordered = chains.sorted { $0.latest.startedAt > $1.latest.startedAt }
        if let pendingResume, let newest = ordered.first, isWaitingToResume(newest.latest) {
            ordered[0] = ExportHistoryChain(id: newest.id, attempts: newest.attempts, badge: .resuming(at: pendingResume.resumeAt))
        }
        return ordered
    }

    /// Whether an attempt ended into a scheduled automatic resume.
    static func isWaitingToResume(_ session: ExportSession) -> Bool {
        session.result.status == .failed && session.result.retryable == true && session.autoResume != nil
    }

    private static func badge(for session: ExportSession) -> ExportHistoryChain.Badge {
        switch session.result.status {
        case .running: .running
        case .completed: .completed
        case .completedWithFailures: .completedWithFailures(session.counts.failed)
        case .cancelled: .cancelled
        case .failed: .stopped(reason: session.result.reason)
        case .interrupted: .interrupted
        }
    }
}
