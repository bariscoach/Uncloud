import Foundation
import os
import Testing
@testable import Uncloud

/// A fixed start time, at file scope so the `@Sendable` clocks can read it.
private let recorderTestStart = ISO8601DateFormatter().date(from: "2026-10-12T14:03:27Z")!

@MainActor
@Suite("SessionRecorder")
struct SessionRecorderTests {
    /// A clock the test moves by hand. Lock-protected, so the recorder's `@Sendable` clock can read it.
    private final class FakeClock: Sendable {
        private let state: OSAllocatedUnfairLock<Date>

        init(_ start: Date) {
            state = OSAllocatedUnfairLock(initialState: start)
        }

        var now: Date { state.withLock { $0 } }

        func advance(by seconds: TimeInterval) {
            state.withLock { $0 = $0.addingTimeInterval(seconds) }
        }
    }

    private static func makeSession() -> ExportSession {
        ExportSession(
            trigger: .manual,
            startedAt: recorderTestStart,
            appVersion: "0.1.4 (14)",
            launchID: UUID(),
            source: .iCloud,
            layout: .month,
            writesSidecars: false,
            selection: ExportSession.SelectionSummary(kind: .everything, count: 100)
        )
    }

    /// The file on disk, as a reader would see it.
    private static func saved(in directory: URL) -> ExportSession? {
        SessionStore(directory: directory).list().first
    }

    @Test func startWritesARunningSession() async throws {
        try await withTemporaryDirectoryAsync { directory in
            let store = SessionStore(directory: directory)
            let recorder = SessionRecorder(session: Self.makeSession(), store: store, now: { recorderTestStart })
            recorder.start()

            await recorder.flush()
            let saved = try #require(Self.saved(in: directory))
            #expect(saved.result.status == .running)
            #expect(saved.counts == ExportSession.Counts())
            #expect(saved.endedAt == nil)
        }
    }

    @Test func itemsAreCheckpointedOnTheTimeInterval() async throws {
        try await withTemporaryDirectoryAsync { directory in
            let clock = FakeClock(recorderTestStart)
            let store = SessionStore(directory: directory)
            let recorder = SessionRecorder(session: Self.makeSession(), store: store, now: { clock.now })
            recorder.start()

            clock.advance(by: 10)
            recorder.recordExported(bytes: 500)
            await recorder.flush()
            #expect(Self.saved(in: directory)?.counts.exported == 0)

            clock.advance(by: 25)
            recorder.recordExported(bytes: 500)
            await recorder.flush()
            let saved = try #require(Self.saved(in: directory))
            #expect(saved.counts.exported == 2)
            #expect(saved.counts.bytesWritten == 1_000)
            #expect(saved.updatedAt == clock.now)
        }
    }

    @Test func itemsAreCheckpointedOnTheItemLimit() async throws {
        try await withTemporaryDirectoryAsync { directory in
            let store = SessionStore(directory: directory)
            let recorder = SessionRecorder(
                session: Self.makeSession(), store: store, now: { recorderTestStart }, checkpointItemLimit: 3
            )
            recorder.start()

            recorder.recordSkipped()
            recorder.recordSkipped()
            await recorder.flush()
            #expect(Self.saved(in: directory)?.counts.skipped == 0)

            recorder.recordFailed(name: "IMG_0003.HEIC", reason: "Timed out")
            await recorder.flush()
            let saved = try #require(Self.saved(in: directory))
            #expect(saved.counts.skipped == 2)
            #expect(saved.counts.failed == 1)
            #expect(saved.failures == [ExportSession.Failure(name: "IMG_0003.HEIC", reason: "Timed out")])
        }
    }

    @Test func heartbeatWritesOnlyWhenDue() async {
        await withTemporaryDirectoryAsync { directory in
            let clock = FakeClock(recorderTestStart)
            let store = SessionStore(directory: directory)
            let recorder = SessionRecorder(session: Self.makeSession(), store: store, now: { clock.now })
            recorder.start()

            clock.advance(by: 29)
            recorder.heartbeat()
            await recorder.flush()
            #expect(Self.saved(in: directory)?.updatedAt == recorderTestStart)

            clock.advance(by: 1)
            recorder.heartbeat()
            await recorder.flush()
            #expect(Self.saved(in: directory)?.updatedAt == clock.now)
        }
    }

    @Test func updateWaitsForTheNextCheckpoint() async {
        await withTemporaryDirectoryAsync { directory in
            let store = SessionStore(directory: directory)
            let recorder = SessionRecorder(session: Self.makeSession(), store: store, now: { recorderTestStart })
            recorder.start()

            recorder.update { $0.libraryCount = 93_015 }
            await recorder.flush()
            #expect(Self.saved(in: directory)?.libraryCount == nil)
            #expect(recorder.session.libraryCount == 93_015)

            recorder.checkpoint()
            await recorder.flush()
            #expect(Self.saved(in: directory)?.libraryCount == 93_015)
        }
    }

    @Test func markPreparedCheckpointsOnlyOnce() async {
        await withTemporaryDirectoryAsync { directory in
            let store = SessionStore(directory: directory)
            let recorder = SessionRecorder(session: Self.makeSession(), store: store, now: { recorderTestStart })
            recorder.start()

            recorder.update { $0.libraryCount = 100 }
            recorder.markPrepared()
            await recorder.flush()
            #expect(Self.saved(in: directory)?.libraryCount == 100)

            recorder.update { $0.libraryCount = 200 }
            recorder.markPrepared()
            await recorder.flush()
            #expect(Self.saved(in: directory)?.libraryCount == 100)
        }
    }

    @Test func finishWritesTheOutcomeAndIgnoresLaterCalls() async throws {
        try await withTemporaryDirectoryAsync { directory in
            let clock = FakeClock(recorderTestStart)
            let store = SessionStore(directory: directory)
            let recorder = SessionRecorder(session: Self.makeSession(), store: store, now: { clock.now })
            recorder.start()

            clock.advance(by: 120)
            recorder.recordExported(bytes: 10)
            recorder.finish(status: .cancelled, reason: "Cancelled by you")

            await recorder.flush()
            let saved = try #require(Self.saved(in: directory))
            #expect(saved.result == ExportSession.Result(status: .cancelled, reason: "Cancelled by you", retryable: nil))
            #expect(saved.endedAt == clock.now)
            #expect(saved.counts.exported == 1)
            #expect(recorder.session.isFinished)

            recorder.finish(status: .completed)
            recorder.recordExported()
            await recorder.flush()
            #expect(Self.saved(in: directory)?.result.status == .cancelled)
            await recorder.flush()
            #expect(Self.saved(in: directory)?.counts.exported == 1)
        }
    }

    @Test func failedRunCarriesRetryAndAutoResume() async throws {
        try await withTemporaryDirectoryAsync { directory in
            let store = SessionStore(directory: directory)
            let resumeAt = recorderTestStart.addingTimeInterval(900)
            let recorder = SessionRecorder(session: Self.makeSession(), store: store, now: { recorderTestStart })
            recorder.start()
            recorder.finish(
                status: .failed,
                reason: "Apple is limiting downloads",
                retryable: true,
                autoResume: ExportSession.AutoResumeNote(attempt: 1, resumeAt: resumeAt)
            )

            await recorder.flush()
            let saved = try #require(Self.saved(in: directory))
            #expect(saved.result.status == .failed)
            #expect(saved.result.retryable == true)
            #expect(saved.autoResume == ExportSession.AutoResumeNote(attempt: 1, resumeAt: resumeAt))
        }
    }

    @Test func failuresStopAtTheLimitButCountingContinues() async throws {
        try await withTemporaryDirectoryAsync { directory in
            let store = SessionStore(directory: directory)
            let recorder = SessionRecorder(
                session: Self.makeSession(), store: store, now: { recorderTestStart }, checkpointItemLimit: 10_000
            )
            recorder.start()
            for index in 0..<(SessionRecorder.failureLimit + 10) {
                recorder.recordFailed(name: "IMG_\(index).HEIC", reason: "Timed out")
            }
            recorder.finish(status: .completedWithFailures)

            await recorder.flush()
            let saved = try #require(Self.saved(in: directory))
            #expect(saved.counts.failed == SessionRecorder.failureLimit + 10)
            #expect(saved.failures.count == SessionRecorder.failureLimit)
            #expect(saved.failures.first?.name == "IMG_0.HEIC")
        }
    }

    @Test func writeFailureIsReportedOnceAndTheRunGoesOn() async throws {
        try await withTemporaryDirectoryAsync { root in
            // The "folder" is a regular file, so nothing can be saved inside it.
            let blocker = root.appending(path: "blocker")
            try Data().write(to: blocker)
            let store = SessionStore(directory: blocker.appending(path: "sessions", directoryHint: .isDirectory))

            var messages: [String] = []
            let recorder = SessionRecorder(
                session: Self.makeSession(), store: store, now: { recorderTestStart }, checkpointItemLimit: 1
            )
            recorder.onWriteFailure = { messages.append($0) }
            recorder.start()
            recorder.recordExported()
            recorder.recordExported()
            recorder.recordSkipped()
            recorder.finish(status: .completed)

            await recorder.flush()
            #expect(messages == ["Couldn't save the export history on this drive"])
            #expect(recorder.session.counts.exported == 2)
            #expect(recorder.session.counts.skipped == 1)
            #expect(recorder.session.result.status == .completed)
        }
    }

    @Test func finishKeepsTheRunWhenHistoryIsWithinLimits() async throws {
        try await withTemporaryDirectoryAsync { directory in
            let store = SessionStore(directory: directory)
            // A few older sessions. They are well within the real retention limits, so finishing must keep them all.
            for day in 1...3 {
                try store.write(ExportSession(
                    trigger: .manual,
                    startedAt: recorderTestStart.addingTimeInterval(TimeInterval(-day * 86_400)),
                    appVersion: "0.1.3 (4)",
                    launchID: UUID(),
                    source: .iCloud,
                    layout: .month,
                    writesSidecars: false,
                    selection: ExportSession.SelectionSummary(kind: .everything, count: 1)
                ))
            }
            let recorder = SessionRecorder(session: Self.makeSession(), store: store, now: { recorderTestStart })
            recorder.start()
            recorder.finish(status: .completed)

            await recorder.flush()
            #expect(store.list().count == 4)
            await recorder.flush()
            #expect(store.list().contains { $0.id == recorder.session.id && $0.result.status == .completed })
        }
    }

    @Test func batchesAreCountedAndFailuresCapped() async throws {
        try await withTemporaryDirectoryAsync { directory in
            let store = SessionStore(directory: directory)
            let recorder = SessionRecorder(
                session: Self.makeSession(), store: store, now: { recorderTestStart }, checkpointItemLimit: 10
            )
            recorder.start()
            let failures = (0..<60).map { ExportSession.Failure(name: "IMG_\($0).HEIC", reason: "Timed out") }
            recorder.record(exported: 3, skipped: 2, failures: Array(failures.prefix(40)), failedCount: 45, bytes: 3_000)
            recorder.record(exported: 1, skipped: 0, failures: Array(failures.suffix(20)), failedCount: 20, bytes: 500)
            await recorder.flush()
            let saved = try #require(Self.saved(in: directory))
            #expect(saved.counts == ExportSession.Counts(exported: 4, skipped: 2, failed: 65, bytesWritten: 3_500))
            #expect(saved.failures.count == SessionRecorder.failureLimit)
        }
    }

    /// Writes go through one serial background queue: many checkpoints in a row end with the newest state on disk.
    @Test func backgroundWritesKeepTheirOrder() async {
        await withTemporaryDirectoryAsync { directory in
            let store = SessionStore(directory: directory)
            let recorder = SessionRecorder(
                session: Self.makeSession(), store: store, now: { recorderTestStart }, checkpointItemLimit: 1
            )
            recorder.start()
            for _ in 0..<200 {
                recorder.recordExported(bytes: 1)
            }
            await recorder.flush()
            #expect(Self.saved(in: directory)?.counts.exported == 200)
            #expect(store.list().count == 1)
        }
    }
}
