import Foundation
import os
import Testing
@testable import Uncloud

/// Stops a verify task from a progress callback, whichever is attached first.
private final class StopBox: Sendable {
    private struct State {
        var task: Task<VerificationReport, Error>?
        var stopRequested = false
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    func attach(_ task: Task<VerificationReport, Error>) {
        state.withLock { state in
            state.task = task
            if state.stopRequested { task.cancel() }
        }
    }

    func stop() {
        state.withLock { state in
            state.stopRequested = true
            state.task?.cancel()
        }
    }
}

@Suite("Verify Backup check state")
struct BackupVerificationStateTests {
    private let itemCount = 100

    /// One file per item, `itemCount` items, journal written and run finished.
    private func makeBackup(in destination: URL) throws {
        let manifest = try ExportManifest(destination: destination)
        for index in 0..<itemCount {
            let path = "2024/07/IMG_\(String(format: "%04d", index)).jpg"
            try writeFile("photo \(index)", to: path, in: destination)
            try manifest.recordExport(of: "item\(index)", files: [path])
        }
        manifest.markRunFinished()
    }

    /// A checkpoint that was saved after `next` items, matching the journal as it is now.
    private func saveCheckpoint(_ store: VerifyCheckpointStore, next: Int, in destination: URL) throws {
        let size = VerifyJournal.size(in: destination)
        try store.save(VerifyCheckpoint(
            startedAt: Date(),
            journalBytes: size,
            journalHead: VerifyJournal.headOfCurrentJournal(in: destination, size: size) ?? "",
            nextItemIndex: next,
            checkedFileCount: next,
            verifiedCount: next,
            damagedItemIDs: [],
            unverifiableItemIDs: [],
            missingFiles: [],
            damagedFiles: [],
            updatedAt: Date()
        ))
    }

    @Test func noCheckpointMeansNothingToContinue() throws {
        try withTemporaryDirectory { destination in
            try withTemporaryDirectory { scratch in
                try makeBackup(in: destination)
                let store = VerifyCheckpointStore(url: scratch.appending(path: "checkpoint.json"))
                #expect(BackupVerification.savedCheck(for: destination, store: store) == .none)
            }
        }
    }

    @Test func matchingCheckpointIsResumableWithItsPercentDone() throws {
        try withTemporaryDirectory { destination in
            try withTemporaryDirectory { scratch in
                try makeBackup(in: destination)
                let store = VerifyCheckpointStore(url: scratch.appending(path: "checkpoint.json"))
                try saveCheckpoint(store, next: 44, in: destination)
                #expect(BackupVerification.savedCheck(for: destination, store: store) == .resumable(percentDone: 44, checkedFiles: 44))
            }
        }
    }

    @Test func checkpointFromBeforeAForgetIsStale() throws {
        try withTemporaryDirectory { destination in
            try withTemporaryDirectory { scratch in
                try makeBackup(in: destination)
                let store = VerifyCheckpointStore(url: scratch.appending(path: "checkpoint.json"))
                try saveCheckpoint(store, next: 44, in: destination)
                try ExportManifest.forget(["item5"], in: destination)
                #expect(BackupVerification.savedCheck(for: destination, store: store) == .stale)
            }
        }
    }

    @Test func stoppedFullCheckLeavesAResumableCheckpoint() async throws {
        try await withTemporaryDirectoryAsync { destination in
            try await withTemporaryDirectoryAsync { scratch in
                try makeBackup(in: destination)
                let store = VerifyCheckpointStore(url: scratch.appending(path: "checkpoint.json"))
                let stop = StopBox()
                let task = Task {
                    try await BackupVerifier.verify(destination: destination, checkpoint: store) { done, _ in
                        if done == 30 { stop.stop() }
                    }
                }
                stop.attach(task)
                await #expect(throws: CancellationError.self) { _ = try await task.value }

                // The stopped pass saved its checkpoint, so the sheet offers to continue from it.
                guard case let .resumable(percentDone, _) = BackupVerification.savedCheck(for: destination, store: store) else {
                    Issue.record("A stopped full check should leave a resumable checkpoint")
                    return
                }
                #expect(percentDone >= 30 && percentDone < 100)
            }
        }
    }

    @Test func byteCounterSeesEveryByteOfAFullPass() async throws {
        try await withTemporaryDirectoryAsync { destination in
            try makeBackup(in: destination)
            let counter = VerifyByteCount()
            _ = try await BackupVerifier.verify(destination: destination, bytes: counter) { _, _ in }
            let expected = Int64((0..<itemCount).reduce(0) { $0 + "photo \($1)".utf8.count })
            #expect(counter.value == expected)
        }
    }

    @Test func estimateWaitsUntilItHasAMeasuredRate() {
        // Too few files so far: no estimate yet.
        #expect(VerifyEstimate.secondsRemaining(done: 10, baseline: 0, total: 100, elapsed: 5) == nil)
        // Too little time so far: no estimate yet.
        #expect(VerifyEstimate.secondsRemaining(done: 100, baseline: 0, total: 1_000, elapsed: 1) == nil)
        // Finished: nothing left to estimate.
        #expect(VerifyEstimate.secondsRemaining(done: 100, baseline: 0, total: 100, elapsed: 60) == nil)
    }

    @Test func estimateUsesTheRateOfThisRunOnly() throws {
        // 200 files already done before this run; this run checked 100 files in 50 seconds, so 2 files a second.
        let remaining = try #require(VerifyEstimate.secondsRemaining(done: 300, baseline: 200, total: 500, elapsed: 50))
        #expect(remaining == 100)
    }

    @Test func timeLeftReadsInPlainWords() {
        #expect(VerifyEstimate.timeLeftText(seconds: 20) == "Less than a minute left")
        #expect(VerifyEstimate.timeLeftText(seconds: 13 * 60 + 1) == "About 13 min left")
        #expect(VerifyEstimate.timeLeftText(seconds: 2 * 3_600) == "About 2 hr left")
        #expect(VerifyEstimate.timeLeftText(seconds: 2 * 3_600 + 5 * 60 + 20) == "About 2 hr 5 min left")
    }
}
