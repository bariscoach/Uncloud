import Foundation
import os
import Testing
@testable import Uncloud

/// A clock the test moves by hand. Safe to share with the verifier's detached work.
private final class ResumeTestClock: Sendable {
    private let state: OSAllocatedUnfairLock<Date>

    init(_ date: Date) {
        state = OSAllocatedUnfairLock(initialState: date)
    }

    var now: Date { state.withLock { $0 } }

    func advance(by seconds: TimeInterval) {
        state.withLock { $0 = $0.addingTimeInterval(seconds) }
    }
}

/// Holds a verify task so a progress callback can cancel it, whichever runs first.
private final class CancelBox: Sendable {
    private struct State {
        var task: Task<VerificationReport, Error>?
        var cancelRequested = false
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    func attach(_ task: Task<VerificationReport, Error>) {
        state.withLock { state in
            state.task = task
            if state.cancelRequested { task.cancel() }
        }
    }

    func cancel() {
        state.withLock { state in
            state.cancelRequested = true
            state.task?.cancel()
        }
    }
}

private let itemCount = 100

private func photoPath(_ index: Int) -> String {
    "2024/07/IMG_\(String(format: "%04d", index)).jpg"
}

/// One item per file, `itemCount` items, each recorded with its checksum.
private func makeBackup(in destination: URL, count: Int = itemCount) throws {
    let manifest = try ExportManifest(destination: destination)
    var sums: [String: String] = [:]
    for index in 0..<count {
        try writeFile("photo \(index) bytes", to: photoPath(index), in: destination)
        try manifest.recordExport(of: "item\(index)", files: [photoPath(index)])
        sums[photoPath(index)] = try FileHasher.sha256(of: destination.appending(path: photoPath(index)))
    }
    try manifest.recordChecksums(sums)
    manifest.markRunFinished()
}

/// Everything a report says, for comparing two runs.
private func summary(_ report: VerificationReport) -> [String] {
    [
        "verified:\(report.verifiedItemIDs.sorted())",
        "damaged:\(report.damagedItemIDs.sorted())",
        "unverifiable:\(report.unverifiableItemIDs.sorted())",
        "missing:\(report.missingFiles)",
        "damagedFiles:\(report.damagedFiles)",
        "checked:\(report.checkedFileCount)",
        "notBackedUp:\(report.notBackedUpCount)",
    ]
}

@Suite("BackupVerifier resumable full pass")
struct BackupVerifierResumeTests {
    /// Corrupts one file before the cancel point, removes one, and corrupts one after it.
    private func damage(_ destination: URL) throws {
        try Data("CORRUPTED".utf8).write(to: destination.appending(path: photoPath(10)))
        try FileManager.default.removeItem(at: destination.appending(path: photoPath(20)))
        try Data("CORRUPTED".utf8).write(to: destination.appending(path: photoPath(60)))
    }

    @Test func interruptedPassResumesToTheSameReportAsAnUninterruptedRun() async throws {
        try await withTemporaryDirectoryAsync { destination in
            try await withTemporaryDirectoryAsync { scratch in
                try makeBackup(in: destination)
                try damage(destination)
                let store = VerifyCheckpointStore(url: scratch.appending(path: "checkpoint.json"))

                let uninterrupted = try await BackupVerifier.verify(destination: destination, libraryIDs: ["item1", "extra"]) { _, _ in }

                let box = CancelBox()
                let task = Task {
                    try await BackupVerifier.verify(destination: destination, libraryIDs: ["item1", "extra"], checkpoint: store) { done, _ in
                        if done == 30 { box.cancel() }
                    }
                }
                box.attach(task)
                await #expect(throws: CancellationError.self) {
                    _ = try await task.value
                }
                // The checkpoint kept what was finished, so the next pass has somewhere to start from.
                let saved = try #require(store.load())
                #expect(saved.nextItemIndex >= 30 && saved.nextItemIndex < itemCount)

                let resumed = try await BackupVerifier.verify(destination: destination, libraryIDs: ["item1", "extra"], checkpoint: store) { _, _ in }
                #expect(resumed.resumedFromCheckpoint)
                #expect(resumed.checkpointRestartReason == nil)
                #expect(summary(resumed) == summary(uninterrupted))
                #expect(resumed.damagedItemIDs == ["item10", "item20", "item60"])
                // The finished pass removes its checkpoint.
                #expect(!FileManager.default.fileExists(atPath: store.url.path(percentEncoded: false)))
            }
        }
    }

    @Test func damagedFileBeforeTheCutIsStillFoundAfterResume() async throws {
        try await withTemporaryDirectoryAsync { destination in
            try await withTemporaryDirectoryAsync { scratch in
                try makeBackup(in: destination)
                try Data("CORRUPTED".utf8).write(to: destination.appending(path: photoPath(3)))
                let store = VerifyCheckpointStore(url: scratch.appending(path: "checkpoint.json"))

                let box = CancelBox()
                let task = Task {
                    try await BackupVerifier.verify(destination: destination, checkpoint: store) { done, _ in
                        if done == 50 { box.cancel() }
                    }
                }
                box.attach(task)
                await #expect(throws: CancellationError.self) { _ = try await task.value }

                let resumed = try await BackupVerifier.verify(destination: destination, checkpoint: store) { _, _ in }
                #expect(resumed.damagedItemIDs == ["item3"])
                #expect(resumed.damagedFiles == [photoPath(3)])
                #expect(resumed.verifiedItemIDs.count == itemCount - 1)
            }
        }
    }

    @Test func recordsAppendedBetweenRunsJoinTheEnd() async throws {
        try await withTemporaryDirectoryAsync { destination in
            try await withTemporaryDirectoryAsync { scratch in
                try makeBackup(in: destination)
                let store = VerifyCheckpointStore(url: scratch.appending(path: "checkpoint.json"))

                let box = CancelBox()
                let task = Task {
                    try await BackupVerifier.verify(destination: destination, checkpoint: store) { done, _ in
                        if done == 40 { box.cancel() }
                    }
                }
                box.attach(task)
                await #expect(throws: CancellationError.self) { _ = try await task.value }

                // A new export appends a record. The journal grows, its head is unchanged, so the checkpoint still holds.
                try writeFile("new photo", to: "2024/08/IMG_NEW.jpg", in: destination)
                let manifest = try ExportManifest(destination: destination)
                try manifest.recordExport(of: "itemNew", files: ["2024/08/IMG_NEW.jpg"])
                try manifest.recordChecksums(["2024/08/IMG_NEW.jpg": try FileHasher.sha256(of: destination.appending(path: "2024/08/IMG_NEW.jpg"))])
                manifest.markRunFinished()

                let uninterrupted = try await BackupVerifier.verify(destination: destination) { _, _ in }
                let resumed = try await BackupVerifier.verify(destination: destination, checkpoint: store) { _, _ in }
                #expect(resumed.resumedFromCheckpoint)
                #expect(resumed.verifiedItemIDs.contains("itemNew"))
                #expect(summary(resumed) == summary(uninterrupted))
            }
        }
    }

    @Test func forgettingAnItemBetweenRunsStartsOver() async throws {
        try await withTemporaryDirectoryAsync { destination in
            try await withTemporaryDirectoryAsync { scratch in
                try makeBackup(in: destination)
                let store = VerifyCheckpointStore(url: scratch.appending(path: "checkpoint.json"))

                let box = CancelBox()
                let task = Task {
                    try await BackupVerifier.verify(destination: destination, checkpoint: store) { done, _ in
                        if done == 30 { box.cancel() }
                    }
                }
                box.attach(task)
                await #expect(throws: CancellationError.self) { _ = try await task.value }

                try ExportManifest.forget(["item5"], in: destination)

                let fresh = try await BackupVerifier.verify(destination: destination) { _, _ in }
                let restarted = try await BackupVerifier.verify(destination: destination, checkpoint: store) { _, _ in }
                #expect(!restarted.resumedFromCheckpoint)
                #expect(restarted.checkpointRestartReason != nil)
                #expect(summary(restarted) == summary(fresh))
                #expect(!restarted.verifiedItemIDs.contains("item5"))
            }
        }
    }

    @Test func itemSubsetsNeverUseOrWriteACheckpoint() async throws {
        try await withTemporaryDirectoryAsync { destination in
            try await withTemporaryDirectoryAsync { scratch in
                try makeBackup(in: destination)
                let store = VerifyCheckpointStore(url: scratch.appending(path: "checkpoint.json"))
                let report = try await BackupVerifier.verify(destination: destination, itemIDs: ["item3", "item4"], checkpoint: store) { _, _ in }
                #expect(report.verifiedItemIDs == ["item3", "item4"])
                #expect(!report.resumedFromCheckpoint)
                #expect(store.load() == nil)
                #expect(!FileManager.default.fileExists(atPath: store.url.path(percentEncoded: false)))
            }
        }
    }

    @Test func unreadableCheckpointIsIgnored() async throws {
        try await withTemporaryDirectoryAsync { destination in
            try await withTemporaryDirectoryAsync { scratch in
                try makeBackup(in: destination)
                let store = VerifyCheckpointStore(url: scratch.appending(path: "checkpoint.json"))
                try Data("{ not json".utf8).write(to: store.url)

                let report = try await BackupVerifier.verify(destination: destination, checkpoint: store) { _, _ in }
                #expect(!report.resumedFromCheckpoint)
                #expect(report.checkpointRestartReason == nil)
                #expect(report.verifiedItemIDs.count == itemCount)
            }
        }
    }

    @Test func checkpointIsSavedEveryItemWhenTheClockMovesAMinutePerFile() async throws {
        try await withTemporaryDirectoryAsync { destination in
            try await withTemporaryDirectoryAsync { scratch in
                try makeBackup(in: destination)
                let clock = ResumeTestClock(Date(timeIntervalSince1970: 1_700_000_000))
                let store = VerifyCheckpointStore(url: scratch.appending(path: "checkpoint.json"), now: { clock.now })
                let observed = OSAllocatedUnfairLock<Int?>(initialState: nil)

                _ = try await BackupVerifier.verify(destination: destination, checkpoint: store) { done, _ in
                    // Each file takes a minute on the fake clock, so every finished item is saved.
                    clock.advance(by: 61)
                    if done == 10 {
                        observed.withLock { $0 = store.load()?.nextItemIndex }
                    }
                }
                #expect(observed.withLock { $0 } == 9)
            }
        }
    }

    @Test func checkpointRoundTripsThroughItsFile() throws {
        try withTemporaryDirectory { scratch in
            let store = VerifyCheckpointStore(url: scratch.appending(path: "sub/checkpoint.json"))
            let saved = VerifyCheckpoint(
                startedAt: Date(timeIntervalSince1970: 1_700_000_000.125),
                journalBytes: 6_213_377,
                journalHead: String(repeating: "a", count: 64),
                nextItemIndex: 41_200,
                checkedFileCount: 45_831,
                verifiedCount: 41_010,
                damagedItemIDs: ["x"],
                unverifiableItemIDs: ["y"],
                missingFiles: ["2024/01/a.jpg"],
                damagedFiles: ["2024/01/b.jpg"],
                updatedAt: Date(timeIntervalSince1970: 1_700_000_060.5)
            )
            try store.save(saved)
            #expect(store.load() == saved)
        }
    }

    @Test func checkpointOfAnotherSchemaIsIgnored() throws {
        try withTemporaryDirectory { scratch in
            let store = VerifyCheckpointStore(url: scratch.appending(path: "checkpoint.json"))
            var other = VerifyCheckpoint(
                startedAt: Date(), journalBytes: 0, journalHead: "", nextItemIndex: 0, checkedFileCount: 0, verifiedCount: 0,
                damagedItemIDs: [], unverifiableItemIDs: [], missingFiles: [], damagedFiles: [], updatedAt: Date()
            )
            other.schema = 2
            try store.save(other)
            #expect(store.load() == nil)
        }
    }

    @Test func sequentialReaderMatchesFileHasher() throws {
        try withTemporaryDirectory { folder in
            for size in [0, 1, 4 << 20, (4 << 20) + 1, 13 << 20] {
                let url = folder.appending(path: "file-\(size).bin")
                let bytes = Data((0..<size).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) })
                try bytes.write(to: url)
                let fast = try SequentialFileReader.sha256(of: url)
                let reference = try FileHasher.sha256(of: url)
                #expect(fast == reference, "size \(size)")
            }
        }
    }
}
