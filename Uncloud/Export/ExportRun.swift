import Foundation
import os

/// A started export: its events, and the task that produces them.
///
/// Cancelling `task` stops the export. The engine then finishes `events` (with `CancellationError`)
/// once it has really stopped, such as after its helper process exited, so a consumer that keeps
/// reading learns when the export is over. Ending the iteration early cancels the task as well.
struct ExportRun: Sendable {
    let events: AsyncThrowingStream<ExportEvent, Error>
    let task: Task<Void, Never>

    static func start(
        _ body: @escaping @Sendable (_ emit: @escaping @Sendable (ExportEvent) -> Void) async throws -> Void
    ) -> ExportRun {
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: ExportEvent.self)
        let task = Task.detached {
            do {
                try await body { continuation.yield($0) }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { _ in task.cancel() }
        return ExportRun(events: stream, task: task)
    }
}

/// Export events summed up for one update of the export screen. Counts are exact; the activity
/// entries keep only the newest `maxEntries`, which is all the activity list shows.
struct ExportBatch: Sendable {
    /// The last `.prepared` in the batch. Counts before it in the batch are superseded by it.
    var prepared: (total: Int, alreadyExported: Int)?
    var totalIncrease = 0
    var processed = 0
    var skipped = 0
    var exported = 0
    var failed = 0
    /// Bytes the exported items wrote, as far as the engine reported them.
    var bytes: Int64 = 0
    /// The first failures of the batch, by item name, for the export session. `failed` counts them all.
    var failures: [ExportSession.Failure] = []
    /// Whether a skip arrived, after which only `finishedSinceSkip` items count toward the time estimate.
    var sawSkip = false
    var finishedSinceSkip = 0
    /// Oldest first.
    var entries: [ActivityEntry] = []
    /// The run's latest `.continuation`, for the export session.
    var continuation: ExportSession.Continuation?
    /// Set on the last batch: how the export ended.
    var ending: Result<Void, Error>?

    static let maxEntries = 500

    var isEmpty: Bool {
        prepared == nil && totalIncrease == 0 && processed == 0 && entries.isEmpty && ending == nil && continuation == nil
    }

    mutating func add(_ event: ExportEvent) {
        switch event {
        case let .prepared(total, alreadyExported):
            prepared = (total, alreadyExported)
            totalIncrease = 0
            processed = 0
            if alreadyExported > 0 {
                log(.info, "Skipping \(alreadyExported.formatted()) photos that are already backed up.")
            }
        case let .totalIncreased(by: count):
            totalIncrease += count
        case .skipped:
            processed += 1
            skipped += 1
            // Skips take almost no time, so they restart the rate the estimate uses.
            sawSkip = true
            finishedSinceSkip = 0
        case let .exported(name, fileCount, bytes):
            processed += 1
            exported += 1
            self.bytes += bytes ?? 0
            finishedSinceSkip += 1
            log(.success, fileCount > 1 ? "Exported \(name) (\(fileCount) files)" : "Exported \(name)")
        case let .failed(name, reason):
            processed += 1
            failed += 1
            if failures.count < SessionRecorder.failureLimit {
                failures.append(ExportSession.Failure(name: name, reason: reason))
            }
            finishedSinceSkip += 1
            log(.warning, "Couldn’t export \(name): \(reason)")
        case let .note(message):
            log(.info, message)
        case let .continuation(continuation):
            self.continuation = continuation
        }
    }

    private mutating func log(_ kind: ActivityEntry.Kind, _ message: String) {
        entries.append(ActivityEntry(kind: kind, message: message))
        if entries.count > Self.maxEntries * 2 {
            entries.removeFirst(entries.count - Self.maxEntries)
        }
    }

    /// The newest `maxEntries` entries, oldest first.
    var recentEntries: ArraySlice<ActivityEntry> {
        entries.suffix(Self.maxEntries)
    }
}

/// Reads an export's events off the main actor and hands them on as batches, at most one per
/// `interval`, so a helper that reports thousands of items a second can't flood the main actor or
/// build up a backlog. The last batch carries the ending. Ending the iteration stops the reading.
enum ExportEventBatcher {
    static func batches(
        of events: AsyncThrowingStream<ExportEvent, Error>,
        interval: Duration = .milliseconds(100)
    ) -> AsyncStream<ExportBatch> {
        let (output, continuation) = AsyncStream.makeStream(of: ExportBatch.self)
        let (wake, wakeContinuation) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        let pending = OSAllocatedUnfairLock(initialState: ExportBatch())

        let reader = Task.detached {
            let ending: Result<Void, Error>
            do {
                for try await event in events {
                    pending.withLock { $0.add(event) }
                    wakeContinuation.yield()
                }
                ending = Task.isCancelled ? .failure(CancellationError()) : .success(())
            } catch {
                ending = .failure(error)
            }
            pending.withLock { $0.ending = ending }
            wakeContinuation.yield()
            wakeContinuation.finish()
        }
        let flusher = Task.detached {
            for await _ in wake {
                let batch = pending.withLock { batch in
                    defer { batch = ExportBatch() }
                    return batch
                }
                if !batch.isEmpty {
                    continuation.yield(batch)
                }
                if batch.ending != nil {
                    break
                }
                try? await Task.sleep(for: interval)
            }
            continuation.finish()
        }
        continuation.onTermination = { _ in
            reader.cancel()
            flusher.cancel()
        }
        return output
    }
}
