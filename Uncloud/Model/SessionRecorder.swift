import Foundation
import os

/// Keeps one export run's session file up to date.
///
/// The run calls `start()`, reports each item (`recordExported`, `recordSkipped`, `recordFailed`, or
/// `record(exported:skipped:failures:failedCount:bytes:)` for a batch), and calls `finish` when it ends.
/// The file is rewritten at start, at the first `markPrepared()`, every `checkpointInterval` seconds or every
/// `checkpointItemLimit` finished items (whichever comes first), on `heartbeat()` when due, on `checkpoint()`,
/// and at the end. A write error never stops the run: the first one is reported through `onWriteFailure`,
/// and later writes are still tried.
///
/// The recorder is used on the main actor, but the files are written by a `SessionWriter` on a serial
/// background queue, in order, so a slow drive never stalls the screen. `flush()` waits for the writes.
@MainActor
final class SessionRecorder {
    /// Failures kept in the file. Counts still include every failure.
    nonisolated static let failureLimit = 50
    /// Retention applied after each finished run. See `SessionStore.prune`.
    static let retentionFiles = 1_000
    static let retentionBytes = 8 * 1024 * 1024

    private(set) var session: ExportSession
    /// Called at most once, with the Activity message, when the history can't be saved on this drive.
    /// Called on the main actor, after the failed write.
    var onWriteFailure: ((String) -> Void)?
    /// Called with the session each time it is handed to the writer, so a history list can show it at once.
    var onSave: ((ExportSession) -> Void)?

    let store: SessionStore
    private let writer: SessionWriter
    private let now: @Sendable () -> Date
    private let checkpointInterval: TimeInterval
    private let checkpointItemLimit: Int
    private var lastCheckpoint: Date?
    private var itemsSinceCheckpoint = 0
    private var didCheckpointPrepared = false
    private var didReportWriteFailure = false

    /// `now` is the clock for timestamps and checkpoints; tests pass a fake one.
    init(
        session: ExportSession,
        store: SessionStore,
        now: @escaping @Sendable () -> Date = { Date() },
        checkpointInterval: TimeInterval = 30,
        checkpointItemLimit: Int = 500
    ) {
        self.session = session
        self.store = store
        writer = SessionWriter(store: store)
        self.now = now
        self.checkpointInterval = checkpointInterval
        self.checkpointItemLimit = checkpointItemLimit
    }

    /// Writes the session file as `running`.
    func start() {
        checkpoint()
    }

    /// Checkpoints once, at the first call. Call it when the engine reports how many items there are.
    func markPrepared() {
        guard !didCheckpointPrepared else { return }
        didCheckpointPrepared = true
        checkpoint()
    }

    /// Sets fields such as `libraryCount`, `driveCheck` or `continuation`. Doesn't write; the next
    /// checkpoint does.
    func update(_ change: (inout ExportSession) -> Void) {
        guard !session.isFinished else { return }
        change(&session)
    }

    func recordExported(bytes: Int? = nil) {
        guard !session.isFinished else { return }
        session.counts.exported += 1
        session.counts.bytesWritten += bytes ?? 0
        finishItem()
    }

    func recordSkipped() {
        guard !session.isFinished else { return }
        session.counts.skipped += 1
        finishItem()
    }

    /// Only the file name and the reason are kept.
    func recordFailed(name: String, reason: String) {
        guard !session.isFinished else { return }
        session.counts.failed += 1
        if session.failures.count < Self.failureLimit {
            session.failures.append(ExportSession.Failure(name: name, reason: reason))
        }
        finishItem()
    }

    /// Records many finished items at once, such as one screen update's worth of export events.
    /// `failedCount` can exceed `failures.count` when only the first failures were kept.
    func record(exported: Int, skipped: Int, failures: [ExportSession.Failure], failedCount: Int, bytes: Int64) {
        guard !session.isFinished else { return }
        let finished = exported + skipped + max(failedCount, failures.count)
        guard finished > 0 || bytes > 0 else { return }
        session.counts.exported += exported
        session.counts.skipped += skipped
        session.counts.failed += max(failedCount, failures.count)
        session.counts.bytesWritten += Int(clamping: bytes)
        let room = max(0, Self.failureLimit - session.failures.count)
        session.failures.append(contentsOf: failures.prefix(room))
        itemsSinceCheckpoint += finished
        if isCheckpointDue {
            checkpoint()
        }
    }

    /// Waits until every write handed to the background writer so far is on disk (or has failed).
    func flush() async {
        await writer.flush()
    }

    /// Writes a checkpoint if one is due. Call it on a timer during long waits, such as a slow download,
    /// so the heartbeat stays fresh.
    func heartbeat() {
        guard !session.isFinished, isCheckpointDue else { return }
        checkpoint()
    }

    /// Writes the current state now.
    func checkpoint() {
        let current = now()
        session.updatedAt = current
        lastCheckpoint = current
        itemsSinceCheckpoint = 0
        save()
    }

    /// Ends the session and writes it, then applies retention to the folder. Calls after the first do nothing.
    func finish(
        status: ExportSession.Status,
        reason: String? = nil,
        retryable: Bool? = nil,
        autoResume: ExportSession.AutoResumeNote? = nil
    ) {
        guard !session.isFinished else { return }
        let ended = now()
        session.endedAt = ended
        session.updatedAt = ended
        session.result = ExportSession.Result(status: status, reason: reason, retryable: retryable)
        session.autoResume = autoResume
        lastCheckpoint = ended
        itemsSinceCheckpoint = 0
        save()
        writer.prune(maxFiles: Self.retentionFiles, maxBytes: Self.retentionBytes)
    }

    // MARK: - Private

    private func finishItem() {
        itemsSinceCheckpoint += 1
        if isCheckpointDue {
            checkpoint()
        }
    }

    private var isCheckpointDue: Bool {
        if itemsSinceCheckpoint >= checkpointItemLimit {
            return true
        }
        guard let lastCheckpoint else { return true }
        return now().timeIntervalSince(lastCheckpoint) >= checkpointInterval
    }

    private func save() {
        onSave?(session)
        writer.write(session) { [weak self] in
            self?.reportWriteFailure()
        }
    }

    private func reportWriteFailure() {
        guard !didReportWriteFailure else { return }
        didReportWriteFailure = true
        onWriteFailure?("Couldn’t save the export history on this drive.")
    }
}

/// Writes session files on a serial background queue, shared by every writer, so all of the app's session
/// writes happen in the order they were handed over. When several states of one session are waiting, only the
/// newest is written, since each one replaces the whole file.
final class SessionWriter: Sendable {
    private let store: SessionStore
    private static let sharedQueue = DispatchQueue(label: "Uncloud.SessionWriter", qos: .utility)
    private var queue: DispatchQueue { Self.sharedQueue }
    /// The newest session waiting to be written, and a counter that tells it from older ones.
    private let pending = OSAllocatedUnfairLock<(session: ExportSession?, generation: Int)>(initialState: (nil, 0))

    init(store: SessionStore) {
        self.store = store
    }

    /// Queues `session` for writing. `onFailure` is called on the main actor if the write fails.
    func write(_ session: ExportSession, onFailure: @escaping @MainActor @Sendable () -> Void) {
        let generation = pending.withLock { state in
            state.generation += 1
            state.session = session
            return state.generation
        }
        let store = store
        let pending = pending
        queue.async {
            // A newer state was queued after this one: its own block writes it.
            let latest: ExportSession? = pending.withLock { state in
                guard state.generation == generation else { return nil }
                defer { state.session = nil }
                return state.session
            }
            guard let latest else { return }
            do {
                try store.write(latest)
            } catch {
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { onFailure() }
                }
            }
        }
    }

    /// Queues retention, after the writes queued so far.
    func prune(maxFiles: Int, maxBytes: Int) {
        let store = store
        queue.async {
            _ = try? store.prune(maxFiles: maxFiles, maxBytes: maxBytes)
        }
    }

    /// Queues `work` after the writes queued so far, such as the interrupted sweep.
    func perform(_ work: @escaping @Sendable (SessionStore) -> Void) {
        let store = store
        queue.async { work(store) }
    }

    /// Returns once everything queued so far has run. A failure reported by those writes reaches the
    /// main actor before this returns to a main-actor caller.
    func flush() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async {
                // Through the main queue, so a failure callback queued by the writes runs first.
                DispatchQueue.main.async { continuation.resume() }
            }
        }
    }
}
