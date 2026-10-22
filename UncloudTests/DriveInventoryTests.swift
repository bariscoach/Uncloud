import Foundation
import os
import Testing
@testable import Uncloud

/// Collects progress reports from the inventory's background task.
private final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [DriveInventory.Progress] = []
    private var mainThreadCalls = 0

    func record(_ progress: DriveInventory.Progress) {
        lock.withLock {
            values.append(progress)
            if Thread.isMainThread { mainThreadCalls += 1 }
        }
    }

    var all: [DriveInventory.Progress] { lock.withLock { values } }
    var callsOnMainThread: Int { lock.withLock { mainThreadCalls } }
}

/// Sets every folder's modification time (the root included) to a fixed date in the past, so that a later change is
/// visible as a difference. Call it after all the files have been written, since writing a file updates its folder.
private func backdate(in destination: URL) throws {
    let past = Date(timeIntervalSince1970: 1_000_000_000)
    let fileManager = FileManager.default
    var folders = [destination]
    if let enumerator = fileManager.enumerator(at: destination, includingPropertiesForKeys: [.isDirectoryKey]) {
        for case let url as URL in enumerator where (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            folders.append(url)
        }
    }
    for folder in folders {
        try fileManager.setAttributes([.modificationDate: past], ofItemAtPath: folder.path(percentEncoded: false))
    }
}

/// Creates `count` empty files spread over `folders` folders, named `f<n>.jpg`. Returns the folder names.
private func makeTree(files count: Int, folders: Int, in destination: URL) throws -> [String] {
    let names = (0..<folders).map { "2024/\(String(format: "%02d", $0 % 12 + 1))/batch\($0)" }
    for name in names {
        try FileManager.default.createDirectory(at: destination.appending(path: name), withIntermediateDirectories: true)
    }
    for index in 0..<count {
        let folder = names[index % folders]
        _ = FileManager.default.createFile(atPath: destination.appending(path: "\(folder)/f\(index).jpg").path(percentEncoded: false), contents: nil)
    }
    return names
}

private func seconds(of duration: Duration) -> Double {
    Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
}

@Suite("DriveInventory")
struct DriveInventoryTests {
    @Test func fullModeListsFilesAndSkipsHiddenPartialAndManifestEntries() async throws {
        try await withTemporaryDirectoryAsync { destination in
            try writeFile("a", to: "2024/07/IMG_0001.HEIC", in: destination)
            try writeFile("b", to: "notes.txt", in: destination)
            try writeFile("hidden", to: "2024/07/.DS_Store", in: destination)
            try writeFile("hidden", to: ".secret/inside.jpg", in: destination)
            try writeFile("manifest", to: ".photo-export/exported.tsv", in: destination)
            try writeFile("partial", to: "2024/07/IMG_0002.HEIC.part", in: destination)
            try writeFile("partial", to: "2024/07/IMG_0003.MOV.partial", in: destination)
            try FileManager.default.createSymbolicLink(
                at: destination.appending(path: "link.jpg"),
                withDestinationURL: destination.appending(path: "notes.txt")
            )

            let result = try await DriveInventory.run(destination: destination, mode: .full)

            #expect(Set(result.files.keys) == ["2024/07/IMG_0001.HEIC", "notes.txt"])
            #expect(result.partialFileCount == 2)
            #expect(result.files["2024/07/IMG_0001.HEIC"]?.size == 1)
            #expect(result.relistedDirectories == ["", "2024", "2024/07"])
            #expect(result.directories.keys.sorted() == ["", "2024", "2024/07"])
        }
    }

    @Test func fullAndQuickAgreeOnAFixtureTreeWithHiddenPartialAndSymlinkEntries() async throws {
        try await withTemporaryDirectoryAsync { destination in
            try writeFile("a", to: "2024/07/IMG_0001.HEIC", in: destination)
            try writeFile("b", to: "notes.txt", in: destination)
            try writeFile("hidden", to: "2024/07/.DS_Store", in: destination)
            try writeFile("hidden", to: ".secret/inside.jpg", in: destination)
            try writeFile("partial", to: "2024/07/IMG_0002.HEIC.part", in: destination)
            try FileManager.default.createSymbolicLink(
                at: destination.appending(path: "link.jpg"),
                withDestinationURL: destination.appending(path: "notes.txt")
            )
            try FileManager.default.createSymbolicLink(
                at: destination.appending(path: "2024/linked-folder"),
                withDestinationURL: destination.appending(path: "2024/07")
            )
            try backdate(in: destination)

            let full = try await DriveInventory.run(destination: destination, mode: .full)

            #expect(full.files.keys.sorted() == ["2024/07/IMG_0001.HEIC", "notes.txt"])
            #expect(full.files["2024/07/IMG_0001.HEIC"]?.size == 1)
            #expect(full.partialFileCount == 1)
            #expect(full.directories.keys.sorted() == ["", "2024", "2024/07"])
            #expect(full.relistedDirectories == ["", "2024", "2024/07"])

            let quick = try await DriveInventory.run(destination: destination, mode: .quick, previous: full.snapshot)

            #expect(quick.relistedDirectories.isEmpty)
            #expect(quick.files == full.files)
            #expect(quick.directories == full.directories)
            #expect(quick.partialFileCount == 0, "unchanged folders are not listed again, so their partial files aren't counted")
        }
    }

    @Test func hiddenFlaggedEntriesAreSkippedLikeDotNames() async throws {
        try await withTemporaryDirectoryAsync { destination in
            try writeFile("a", to: "2024/07/IMG_0001.HEIC", in: destination)
            try writeFile("b", to: "System Volume Information/IMG_0002.HEIC", in: destination)
            try writeFile("c", to: "2024/07/flagged.jpg", in: destination)
            let flaggedFile = destination.appending(path: "2024/07/flagged.jpg")
            let flaggedFolder = destination.appending(path: "$RECYCLE.BIN", directoryHint: .isDirectory)
            try writeFile("d", to: "$RECYCLE.BIN/IMG_0003.HEIC", in: destination)
            #expect(chflags(flaggedFile.path(percentEncoded: false), UInt32(UF_HIDDEN)) == 0)
            #expect(chflags(flaggedFolder.path(percentEncoded: false), UInt32(UF_HIDDEN)) == 0)
            defer {
                _ = chflags(flaggedFile.path(percentEncoded: false), 0)
                _ = chflags(flaggedFolder.path(percentEncoded: false), 0)
            }

            let result = try await DriveInventory.run(destination: destination, mode: .full)

            // The flagged file and the flagged folder are gone; the unflagged "System Volume Information" is not hidden.
            #expect(Set(result.files.keys) == ["2024/07/IMG_0001.HEIC", "System Volume Information/IMG_0002.HEIC"])
            #expect(!result.directories.keys.contains("$RECYCLE.BIN"))
        }
    }

    @Test func unreadableSubfolderIsSkippedAndTheScanContinues() async throws {
        try await withTemporaryDirectoryAsync { destination in
            try writeFile("a", to: "2024/07/IMG_0001.HEIC", in: destination)
            try writeFile("b", to: "2025/01/IMG_0002.HEIC", in: destination)
            let locked = destination.appending(path: "2025/01", directoryHint: .isDirectory)
            #expect(chmod(locked.path(percentEncoded: false), 0) == 0)
            defer { _ = chmod(locked.path(percentEncoded: false), 0o755) }

            let result = try await DriveInventory.run(destination: destination, mode: .full)

            #expect(Set(result.files.keys) == ["2024/07/IMG_0001.HEIC"])
            #expect(!result.relistedDirectories.contains("2025/01"))
        }
    }

    @Test func missingDestinationThrows() async throws {
        let missing = FileManager.default.temporaryDirectory.appending(path: "uncloud-missing-\(UUID().uuidString)")
        await #expect(throws: DriveInventory.InventoryError.destinationMissing) {
            _ = try await DriveInventory.run(destination: missing, mode: .full)
        }
    }

    @Test func quickModeWithoutChangesRelistsNothing() async throws {
        try await withTemporaryDirectoryAsync { destination in
            _ = try makeTree(files: 30, folders: 3, in: destination)
            try backdate(in: destination)
            let full = try await DriveInventory.run(destination: destination, mode: .full)

            let quick = try await DriveInventory.run(destination: destination, mode: .quick, previous: full.snapshot)

            #expect(quick.relistedDirectories.isEmpty)
            #expect(quick.files == full.files)
            #expect(quick.directories == full.directories)
        }
    }

    @Test func quickModeRelistsOnlyTheFolderThatChanged() async throws {
        try await withTemporaryDirectoryAsync { destination in
            let folders = try makeTree(files: 300, folders: 6, in: destination)
            try backdate(in: destination)
            let full = try await DriveInventory.run(destination: destination, mode: .full)

            // Adding a file changes only that folder's modification time.
            let changed = folders[2]
            try writeFile("new", to: "\(changed)/IMG_NEW.jpg", in: destination)

            let quick = try await DriveInventory.run(destination: destination, mode: .quick, previous: full.snapshot)

            #expect(quick.relistedDirectories == [changed])
            #expect(quick.files["\(changed)/IMG_NEW.jpg"] != nil)
            #expect(quick.files.count == full.files.count + 1)
            var expected = full.files
            expected["\(changed)/IMG_NEW.jpg"] = quick.files["\(changed)/IMG_NEW.jpg"]
            #expect(quick.files == expected)
        }
    }

    @Test func quickModeNotesRemovedFilesAndNewFolders() async throws {
        try await withTemporaryDirectoryAsync { destination in
            try writeFile("a", to: "2024/07/IMG_0001.HEIC", in: destination)
            try writeFile("b", to: "2024/07/IMG_0002.HEIC", in: destination)
            try backdate(in: destination)
            let full = try await DriveInventory.run(destination: destination, mode: .full)

            try FileManager.default.removeItem(at: destination.appending(path: "2024/07/IMG_0001.HEIC"))
            try writeFile("c", to: "2024/08/IMG_0003.HEIC", in: destination)

            let quick = try await DriveInventory.run(destination: destination, mode: .quick, previous: full.snapshot)

            #expect(Set(quick.files.keys) == ["2024/07/IMG_0002.HEIC", "2024/08/IMG_0003.HEIC"])
            #expect(quick.relistedDirectories.contains("2024/07"))
            #expect(quick.relistedDirectories.contains("2024"))
        }
    }

    @Test func quickModeWithoutSnapshotListsEverything() async throws {
        try await withTemporaryDirectoryAsync { destination in
            _ = try makeTree(files: 20, folders: 4, in: destination)
            let quick = try await DriveInventory.run(destination: destination, mode: .quick, previous: nil)
            #expect(quick.files.count == 20)
            #expect(quick.relistedDirectories.count == quick.directories.count)
        }
    }

    @Test func progressIsReportedOffTheMainThroughTheSnapshotCount() async throws {
        try await withTemporaryDirectoryAsync { destination in
            _ = try makeTree(files: 2_500, folders: 5, in: destination)
            let full = try await DriveInventory.run(destination: destination, mode: .full)
            let log = ProgressLog()

            let result = try await DriveInventory.run(
                destination: destination, mode: .full, previous: full.snapshot,
                progress: { log.record($0) }
            )

            let reports = log.all
            #expect(reports.count >= 3, "one report per 1,000 files, plus a final one")
            #expect(reports.last?.filesListed == result.files.count)
            #expect(reports.last?.expectedFiles == 2_500)
            #expect(reports.map(\.filesListed) == reports.map(\.filesListed).sorted())
            #expect(log.callsOnMainThread == 0)
        }
    }

    @Test func cancellationStopsTheListingPromptly() async throws {
        try await withTemporaryDirectoryAsync { destination in
            _ = try makeTree(files: 30_000, folders: 30, in: destination)

            let (signals, signal) = AsyncStream<Void>.makeStream()
            // The listing waits at its first progress report until the test has cancelled it. Without this, a busy
            // machine could let the listing finish all 30,000 files before the test got to cancel it.
            let held = DispatchSemaphore(value: 0)
            let isFirstReport = OSAllocatedUnfairLock(initialState: true)
            let task = Task {
                try await DriveInventory.run(destination: destination, mode: .full, progress: { _ in
                    let first = isFirstReport.withLock { first in
                        defer { first = false }
                        return first
                    }
                    guard first else { return }
                    signal.yield()
                    held.wait()
                })
            }
            // Cancel once the listing has started, not before.
            var iterator = signals.makeAsyncIterator()
            _ = await iterator.next()

            let cancelled = ContinuousClock.now
            task.cancel()
            held.signal()
            var threw = false
            do {
                _ = try await task.value
            } catch is CancellationError {
                threw = true
            }
            let elapsed = cancelled.duration(to: .now)
            print("DriveInventory cancel latency: \(elapsed)")
            #expect(threw)
            #expect(elapsed < .milliseconds(100))
        }
    }

    @Test func performanceOfAFullListing() async throws {
        try await withTemporaryDirectoryAsync { destination in
            let count = 30_000
            let started = ContinuousClock.now
            _ = try makeTree(files: count, folders: 300, in: destination)
            print("DriveInventory fixture: \(count) files written in \(started.duration(to: .now))")

            var measuredFull: DriveInventory.Result?
            let fullTime = try await ContinuousClock().measure {
                measuredFull = try await DriveInventory.run(destination: destination, mode: .full)
            }
            let fullSeconds = seconds(of: fullTime)
            let full = try #require(measuredFull)
            #expect(full.files.count == count)

            // Quick mode after touching one folder, for comparison.
            try writeFile("x", to: "2024/01/batch0/IMG_EXTRA.jpg", in: destination)
            var measuredQuick: DriveInventory.Result?
            let quickTime = try await ContinuousClock().measure {
                measuredQuick = try await DriveInventory.run(destination: destination, mode: .quick, previous: full.snapshot)
            }
            let quickSeconds = seconds(of: quickTime)
            let quick = try #require(measuredQuick)
            #expect(quick.files.count == count + 1)

            let per100k = fullSeconds * 100_000 / Double(count)
            print(String(format: "DriveInventory full: %d files in %.3f s (%.1f s per 100k); quick: %.3f s, %d folder(s) relisted",
                         count, fullSeconds, per100k, quickSeconds, quick.relistedDirectories.count))
            // A generous bound, so a slow CI machine doesn't fail. The real target (100k in 10 s) is measured above.
            #expect(fullSeconds < 30)
        }
    }
}
