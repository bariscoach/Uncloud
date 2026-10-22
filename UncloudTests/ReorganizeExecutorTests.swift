import Foundation
import os
import Testing
@testable import Uncloud

@Suite("ReorganizeExecutor")
struct ReorganizeExecutorTests {
    private static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private static func day(_ year: Int, _ month: Int, _ day: Int) -> Date {
        utc.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
    }

    private static let created: [String: Date] = [
        "icloud-id:A": day(2024, 7, 4),
        "icloud-id:B": day(2024, 7, 9),
        "icloud-id:C": day(2023, 11, 15),
        "icloud-id:D": day(2024, 7, 9),
    ]

    /// The bytes of a companion from the AppleDouble fixtures.
    private static func fixture(_ name: String) -> Data {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/AppleDouble/\(name).bin")
        return (try? Data(contentsOf: url)) ?? Data()
    }

    /// A flat backup: a photo, a Live Photo pair with its sidecar, an icloudpd-named photo, an unrecorded file, a
    /// helper holding only the quarantine flag and a helper holding tags. The manifest records every media file.
    private static func makeBackup(_ root: URL) throws {
        try writeFile("photo-1", to: "IMG_1.HEIC", in: root)
        try writeFile("photo-2", to: "IMG_2.HEIC", in: root)
        try writeFile("movie-2", to: "IMG_2.MOV", in: root)
        try writeFile("xmp-2", to: "IMG_2.HEIC.xmp", in: root)
        try writeFile("photo-3", to: "IMG_3.JPG", in: root)
        try writeFile("photo4", to: "IMG_4-6.HEIC", in: root)
        try writeFile("mine", to: "notes.txt", in: root)
        try Data(fixture("quarantine-only")).write(to: root.appending(path: "._IMG_1.HEIC"))
        try Data(fixture("quarantine-tags")).write(to: root.appending(path: "._IMG_3.JPG"))
        try writeFile("flat", to: ".photo-export/layout", in: root)
        try ExportManifest.appendRecords([
            (key: "icloud-id:A", paths: ["IMG_1.HEIC"]),
            (key: "icloud-id:B", paths: ["IMG_2.HEIC", "IMG_2.MOV", "IMG_2.HEIC.xmp"]),
            (key: "icloud-id:C", paths: ["IMG_3.JPG"]),
            (key: "icloud-id:D", paths: ["IMG_4-6.HEIC"]),
        ], in: root)
    }

    /// The plan for the backup as it is now, built the way the app builds it.
    private static func plan(_ root: URL) throws -> ReorganizePlanner.Plan {
        var listing: [String: ReorganizePlanner.RootFile] = [:]
        for entry in try BulkDirectoryLister.list(root) {
            guard case .file = entry.kind else { continue }
            listing[entry.name] = ReorganizePlanner.RootFile(size: entry.size, modified: entry.modified)
        }
        return ReorganizePlanner.plan(ReorganizePlanner.Input(
            records: ExportManifest.records(in: root),
            rootListing: listing,
            targetListings: [:],
            createdByKey: created,
            calendar: utc
        ))
    }

    /// Where the media and the unrecorded file of the backup should be after a finished run.
    private static let movedFiles: [String: String] = [
        "2024/07/IMG_1.HEIC": "photo-1",
        "2024/07/IMG_2.HEIC": "photo-2",
        "2024/07/IMG_2.MOV": "movie-2",
        "2024/07/IMG_2.HEIC.xmp": "xmp-2",
        "2023/11/IMG_3.JPG": "photo-3",
        "2024/07/IMG_4.HEIC": "photo4",
        "notes.txt": "mine",
    ]

    private static let mediaContents = ["photo-1", "photo-2", "movie-2", "xmp-2", "photo-3", "photo4"]

    /// Every file and folder under a destination, except `.photo-export`, by relative path.
    private struct Tree: Equatable {
        var files: [String: Data]
        var folders: Set<String>
    }

    /// Walks with `BulkDirectoryLister`, which lists hidden entries. `FileManager`'s enumerator skips the `._`
    /// companions, and they are part of what these tests check.
    private static func tree(_ root: URL) -> Tree {
        var files: [String: Data] = [:]
        var folders = Set<String>()
        func walk(_ folder: String) {
            let url = folder.isEmpty ? root : root.appending(path: folder, directoryHint: .isDirectory)
            guard let entries = try? BulkDirectoryLister.list(url) else { return }
            for entry in entries {
                if folder.isEmpty, entry.name == ".photo-export" { continue }
                let relative = folder.isEmpty ? entry.name : folder + "/" + entry.name
                switch entry.kind {
                case .directory:
                    folders.insert(relative)
                    walk(relative)
                case .file:
                    files[relative] = (try? Data(contentsOf: root.appending(path: relative))) ?? Data()
                case .symlink, .other:
                    break
                }
            }
        }
        walk("")
        return Tree(files: files, folders: folders)
    }

    /// The tree after a finished run: the moved files, the companion that moved, and the folders the run created.
    /// The quarantine-only companion is gone (deleted, its bytes journaled).
    private static func expectedFinished() -> Tree {
        var files: [String: Data] = [:]
        for (path, text) in movedFiles {
            files[path] = Data(text.utf8)
        }
        files["2023/11/._IMG_3.JPG"] = Data(fixture("quarantine-tags"))
        return Tree(files: files, folders: ["2023", "2023/11", "2024", "2024/07"])
    }

    /// After a crash or a failed step, every media file is in exactly one place: under its old or its new name.
    private static func assertNothingLost(_ tree: Tree) {
        for content in mediaContents {
            let count = tree.files.values.filter { $0 == Data(content.utf8) }.count
            #expect(count == 1, "\(content) is in \(count) places")
        }
        #expect(tree.files["notes.txt"] == Data("mine".utf8))
    }

    private static func executor(
        _ root: URL,
        faults: Faults = Faults(),
        removeHelpers: Bool = true,
        log: MapLog = MapLog()
    ) -> ReorganizeExecutor {
        ReorganizeExecutor(
            destination: root,
            removeHelpers: removeHelpers,
            fs: FaultyFS(faults: faults),
            relocate: { map, _, _ in
                try faults.perform { log.maps.withLock { $0.append(map) } }
            }
        )
    }

    /// Finishes a run that a crash interrupted: resumes it, starts it when nothing was journaled yet, or does nothing
    /// when it already finished.
    private static func finish(_ root: URL, plan: ReorganizePlanner.Plan, log: MapLog = MapLog()) async throws {
        if ReorganizeJournal.pending(in: root) == nil, (try archive(in: root, suffix: ".done")) != nil {
            return
        }
        do {
            try await executor(root, log: log).resume()
        } catch ReorganizeError.nothingPending, ReorganizeError.notStarted {
            try await executor(root, log: log).start(plan: plan)
        }
    }

    /// Finishes an undo that a crash interrupted: resumes it when it was started, starts it otherwise, and does
    /// nothing when it already completed.
    private static func finishUndo(_ root: URL) async throws {
        if ReorganizeJournal.pending(in: root) != nil {
            try await executor(root).resume()
        } else if try archive(in: root, suffix: ".undone") != nil {
            return
        } else {
            try await executor(root).undo()
        }
    }

    /// The archive of a finished or undone run, by suffix, or nil when there is none.
    private static func archive(in root: URL, suffix: String) throws -> URL? {
        let folder = root.appending(path: ".photo-export", directoryHint: .isDirectory)
        let name = try FileManager.default.contentsOfDirectory(atPath: folder.path)
            .first { $0.hasPrefix("reorganize-") && $0.hasSuffix(suffix) }
        return name.map { folder.appending(path: $0) }
    }

    /// The number of mutating operations in a clean run on a fresh copy of the backup.
    private static func operationCount() async throws -> Int {
        try await withTemporaryDirectoryAsync { scratch in
            try makeBackup(scratch)
            let faults = Faults()
            try await executor(scratch, faults: faults).start(plan: try plan(scratch))
            return faults.operations
        }
    }

    // MARK: - Happy path

    @Test func movesEveryRecordedFileIntoMonthFoldersAndKeepsGroupsTogether() async throws {
        try await withTemporaryDirectoryAsync { root in
            try Self.makeBackup(root)
            let plan = try Self.plan(root)
            let log = MapLog()
            try await Self.executor(root, log: log).start(plan: plan)

            #expect(Self.tree(root) == Self.expectedFinished())
            #expect(log.maps.withLock { $0 } == [[
                "IMG_1.HEIC": "2024/07/IMG_1.HEIC",
                "IMG_2.HEIC": "2024/07/IMG_2.HEIC",
                "IMG_2.MOV": "2024/07/IMG_2.MOV",
                "IMG_2.HEIC.xmp": "2024/07/IMG_2.HEIC.xmp",
                "IMG_3.JPG": "2023/11/IMG_3.JPG",
                "IMG_4-6.HEIC": "2024/07/IMG_4.HEIC",
            ]])
            #expect(ReorganizeJournal.pending(in: root) == nil)
            #expect(try Self.archive(in: root, suffix: ".done") != nil)
        }
    }

    @Test func quarantineOnlyHelperIsDeletedAndItsBytesAreJournaled() async throws {
        try await withTemporaryDirectoryAsync { root in
            try Self.makeBackup(root)
            try await Self.executor(root).start(plan: try Self.plan(root))
            let journal = ReorganizeJournal.parse(try Data(contentsOf: try #require(try Self.archive(in: root, suffix: ".done"))))
            #expect(journal.companions.values.contains(.deleted(Self.fixture("quarantine-only"))))
            #expect(!FileManager.default.fileExists(atPath: root.appending(path: "2024/07/._IMG_1.HEIC").path))
        }
    }

    @Test func withRemovalOffEveryCompanionMovesAndNoneIsDeleted() async throws {
        try await withTemporaryDirectoryAsync { root in
            try Self.makeBackup(root)
            try await Self.executor(root, removeHelpers: false).start(plan: try Self.plan(root))
            #expect(try Data(contentsOf: root.appending(path: "2024/07/._IMG_1.HEIC")) == Self.fixture("quarantine-only"))
            #expect(try Data(contentsOf: root.appending(path: "2023/11/._IMG_3.JPG")) == Self.fixture("quarantine-tags"))
        }
    }

    @Test func readOnlyFilesMoveAndKeepTheirModeAndBytes() async throws {
        try await withTemporaryDirectoryAsync { root in
            try Self.makeBackup(root)
            for name in ["IMG_2.MOV", "._IMG_1.HEIC"] {
                try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: root.appending(path: name).path)
            }
            try await Self.executor(root).start(plan: try Self.plan(root))
            let moved = root.appending(path: "2024/07/IMG_2.MOV")
            #expect(try Data(contentsOf: moved) == Data("movie-2".utf8))
            let mode = try FileManager.default.attributesOfItem(atPath: moved.path)[.posixPermissions] as? NSNumber
            #expect(mode?.intValue == 0o444)
            #expect(!FileManager.default.fileExists(atPath: root.appending(path: "._IMG_1.HEIC").path))
        }
    }

    // MARK: - Name collisions

    @Test func takenPlannedNameGetsTheNextFreeNameAndTheOutsideFileIsUntouched() async throws {
        try await withTemporaryDirectoryAsync { root in
            try Self.makeBackup(root)
            let plan = try Self.plan(root)
            // Something else takes the planned name after the plan was made.
            try writeFile("outside", to: "2024/07/IMG_1.HEIC", in: root)
            let log = MapLog()
            try await Self.executor(root, log: log).start(plan: plan)

            #expect(try Data(contentsOf: root.appending(path: "2024/07/IMG_1.HEIC")) == Data("outside".utf8))
            #expect(try Data(contentsOf: root.appending(path: "2024/07/IMG_1 (1).HEIC")) == Data("photo-1".utf8))
            #expect(log.maps.withLock { $0.first }?["IMG_1.HEIC"] == "2024/07/IMG_1 (1).HEIC")
        }
    }

    @Test func collisionAfterACrashStopsWithBothPaths() async throws {
        try await withTemporaryDirectoryAsync { root in
            try Self.makeBackup(root)
            let plan = try Self.plan(root)
            let total = try await Self.operationCount()
            _ = try? await Self.executor(root, faults: Faults(crashAfter: total / 2)).start(plan: plan)

            let journal = ReorganizeJournal.parse(try Data(contentsOf: ReorganizeJournal.url(in: root)))
            #expect(journal.batchesStarted)
            // A file that hasn't moved yet: its old name is there and its new name is free.
            guard let pending = journal.entries.first(where: { entry in
                !journal.done.contains(entry.index)
                    && FileManager.default.fileExists(atPath: root.appending(path: entry.old).path)
                    && !FileManager.default.fileExists(atPath: root.appending(path: entry.new).path)
            }) else {
                Issue.record("the crash point left nothing to move")
                return
            }
            // Something appears under the new name of a file that hasn't moved yet.
            try writeFile("outside", to: pending.new, in: root)
            let runner = Self.executor(root)
            await #expect(throws: ReorganizeError.conflict(old: pending.old, new: pending.new)) {
                try await runner.resume()
            }
            guard case .failed = await runner.phase else {
                Issue.record("the run should be failed")
                return
            }
            #expect(try Data(contentsOf: root.appending(path: pending.new)) == Data("outside".utf8))
            #expect(FileManager.default.fileExists(atPath: root.appending(path: pending.old).path))
        }
    }

    // MARK: - Crash at every step, EIO and ENOSPC at every step

    @Test func crashAfterEveryOperationThenResumeGivesTheSameResult() async throws {
        try await withTemporaryDirectoryAsync { baseline in
            try Self.makeBackup(baseline)
            let plan = try Self.plan(baseline)
            let counter = Faults()
            try await Self.executor(baseline, faults: counter).start(plan: plan)
            let expected = Self.tree(baseline)
            #expect(expected == Self.expectedFinished())
            let total = counter.operations
            #expect(total > 20)

            for crash in 1 ... total {
                try await withTemporaryDirectoryAsync { root in
                    try Self.makeBackup(root)
                    do {
                        try await Self.executor(root, faults: Faults(crashAfter: crash)).start(plan: try Self.plan(root))
                        Issue.record("crash \(crash) did not stop the run")
                    } catch {
                        #expect(error is InjectedCrash, "crash \(crash): \(error)")
                    }
                    Self.assertNothingLost(Self.tree(root))

                    try await Self.finish(root, plan: plan)
                    #expect(Self.tree(root) == expected, "crash \(crash)")
                }
            }
        }
    }

    @Test func crashDuringRecoveryAlsoConverges() async throws {
        try await withTemporaryDirectoryAsync { baseline in
            try Self.makeBackup(baseline)
            let plan = try Self.plan(baseline)
            let counter = Faults()
            try await Self.executor(baseline, faults: counter).start(plan: plan)
            let expected = Self.tree(baseline)
            let total = counter.operations

            for first in 1 ... total {
                for second in [1, 3, 7] {
                    try await withTemporaryDirectoryAsync { root in
                        try Self.makeBackup(root)
                        _ = try? await Self.executor(root, faults: Faults(crashAfter: first)).start(plan: try Self.plan(root))
                        // A second crash while recovering: this resume dies after its `second` operation.
                        _ = try? await Self.executor(root, faults: Faults(crashAfter: second)).resume()
                        try await Self.finish(root, plan: plan)
                        #expect(Self.tree(root) == expected, "crashes \(first),\(second)")
                    }
                }
            }
        }
    }

    @Test func failedRenameOrJournalWriteAtAnyStepLosesNothing() async throws {
        try await withTemporaryDirectoryAsync { baseline in
            try Self.makeBackup(baseline)
            let plan = try Self.plan(baseline)
            let counter = Faults()
            try await Self.executor(baseline, faults: counter).start(plan: plan)
            let expected = Self.tree(baseline)
            let total = counter.operations

            for code in [POSIXErrorCode.EIO, .ENOSPC] {
                for failure in 1 ... total {
                    try await withTemporaryDirectoryAsync { root in
                        try Self.makeBackup(root)
                        do {
                            try await Self.executor(root, faults: Faults(failBefore: failure, code: code)).start(plan: try Self.plan(root))
                            Issue.record("failure \(failure) did not stop the run")
                        } catch let error as POSIXError {
                            #expect(error.code == code)
                        } catch {
                            Issue.record("failure \(failure): unexpected \(error)")
                        }
                        Self.assertNothingLost(Self.tree(root))
                        try await Self.finish(root, plan: plan)
                        #expect(Self.tree(root) == expected, "\(code) at \(failure)")
                    }
                }
            }
        }
    }

    // MARK: - Manifest changes during the move

    @Test func recordsChangedWhileMovingAreNotLost() async throws {
        try await withTemporaryDirectoryAsync { root in
            try Self.makeBackup(root)
            let plan = try Self.plan(root)
            let total = try await Self.operationCount()
            _ = try? await Self.executor(root, faults: Faults(crashAfter: total / 2)).start(plan: plan)

            // An outside change: a new recorded file that isn't in the plan, and a record forgotten mid-move.
            try writeFile("new photo", to: "NEW.HEIC", in: root)
            try ExportManifest.appendRecords([(key: "icloud-id:NEW", paths: ["NEW.HEIC"])], in: root)
            try ExportManifest.forget(["icloud-id:D"], in: root)

            let log = MapLog()
            try await Self.finish(root, plan: plan, log: log)
            // The manifest phase is handed exactly the files this run moved. The new record's file stays out of it.
            #expect(log.maps.withLock { $0 }.last == [
                "IMG_1.HEIC": "2024/07/IMG_1.HEIC",
                "IMG_2.HEIC": "2024/07/IMG_2.HEIC",
                "IMG_2.MOV": "2024/07/IMG_2.MOV",
                "IMG_2.HEIC.xmp": "2024/07/IMG_2.HEIC.xmp",
                "IMG_3.JPG": "2023/11/IMG_3.JPG",
                "IMG_4-6.HEIC": "2024/07/IMG_4.HEIC",
            ])
            #expect(ExportManifest.records(in: root)["icloud-id:NEW"] == ["NEW.HEIC"])
            #expect(FileManager.default.fileExists(atPath: root.appending(path: "NEW.HEIC").path))
        }
    }

    @Test func exportStartingDuringTheMoveStopsItAndResumesLater() async throws {
        try await withTemporaryDirectoryAsync { root in
            try Self.makeBackup(root)
            let plan = try Self.plan(root)
            let total = try await Self.operationCount()
            _ = try? await Self.executor(root, faults: Faults(crashAfter: total / 2)).start(plan: plan)

            try writeFile("", to: ".photo-export/run-in-progress", in: root)
            await #expect(throws: ReorganizeError.exportRunning) {
                try await Self.executor(root).resume()
            }
            try FileManager.default.removeItem(at: root.appending(path: ".photo-export/run-in-progress"))
            try await Self.finish(root, plan: plan)
            #expect(Self.tree(root) == Self.expectedFinished())
        }
    }

    // MARK: - Refusals and recovery edges

    @Test func refusesToStartWhenNotFlatOrWhenAnExportIsRunning() async throws {
        try await withTemporaryDirectoryAsync { root in
            try Self.makeBackup(root)
            let plan = try Self.plan(root)
            try writeFile("month", to: ".photo-export/layout", in: root)
            await #expect(throws: ReorganizeError.layoutNotFlat) {
                try await Self.executor(root).start(plan: plan)
            }
            try writeFile("flat", to: ".photo-export/layout", in: root)
            try writeFile("", to: ".photo-export/run-in-progress", in: root)
            await #expect(throws: ReorganizeError.exportRunning) {
                try await Self.executor(root).start(plan: plan)
            }
            #expect(Self.tree(root).files["notes.txt"] == Data("mine".utf8))
        }
    }

    @Test func aJournalWithoutPlannedIsDiscardedBeforeAnyMove() async throws {
        try await withTemporaryDirectoryAsync { root in
            try Self.makeBackup(root)
            let before = Self.tree(root)
            try writeFile("uncloud-reorganize\t1\tnow\tflat\tmonth\t0\t1\n", to: ".photo-export/reorganize.journal", in: root)
            await #expect(throws: ReorganizeError.notStarted) {
                try await Self.executor(root).resume()
            }
            #expect(Self.tree(root) == before)
        }
    }

    @Test func resumingAFinishedRunDoesNothing() async throws {
        try await withTemporaryDirectoryAsync { root in
            try Self.makeBackup(root)
            try await Self.executor(root).start(plan: try Self.plan(root))
            let finished = Self.tree(root)
            let log = MapLog()
            await #expect(throws: ReorganizeError.nothingPending) {
                try await Self.executor(root, log: log).resume()
            }
            #expect(Self.tree(root) == finished)
            #expect(log.maps.withLock { $0 }.isEmpty)
        }
    }

    // MARK: - Undo

    @Test func undoPutsEverythingBackByteForByte() async throws {
        try await withTemporaryDirectoryAsync { root in
            try Self.makeBackup(root)
            let original = Self.tree(root)
            let manifest = try Data(contentsOf: root.appending(path: ".photo-export/exported.tsv"))
            try await Self.executor(root).start(plan: try Self.plan(root))

            let log = MapLog()
            try await Self.executor(root, log: log).undo()
            #expect(Self.tree(root) == original)
            #expect(try Data(contentsOf: root.appending(path: ".photo-export/exported.tsv")) == manifest)
            #expect(log.maps.withLock { $0 }.last?["2024/07/IMG_1.HEIC"] == "IMG_1.HEIC")
            #expect(try Self.archive(in: root, suffix: ".undone") != nil)
        }
    }

    @Test func undoAfterAnInterruptedRunPutsTheMovedFilesBack() async throws {
        try await withTemporaryDirectoryAsync { root in
            try Self.makeBackup(root)
            let original = Self.tree(root)
            let plan = try Self.plan(root)
            let total = try await Self.operationCount()
            _ = try? await Self.executor(root, faults: Faults(crashAfter: total / 2)).start(plan: plan)
            try await Self.executor(root).undo()
            #expect(Self.tree(root) == original)
        }
    }

    @Test func undoAtEveryStepThenFinishingItRestoresEverything() async throws {
        try await withTemporaryDirectoryAsync { baseline in
            try Self.makeBackup(baseline)
            let original = Self.tree(baseline)
            try await Self.executor(baseline).start(plan: try Self.plan(baseline))
            let counter = Faults()
            try await Self.executor(baseline, faults: counter).undo()
            #expect(Self.tree(baseline) == original)
            let total = counter.operations

            for crash in 1 ... total {
                try await withTemporaryDirectoryAsync { root in
                    try Self.makeBackup(root)
                    try await Self.executor(root).start(plan: try Self.plan(root))
                    _ = try? await Self.executor(root, faults: Faults(crashAfter: crash)).undo()
                    try await Self.finishUndo(root)
                    #expect(Self.tree(root) == original, "undo crash \(crash)")
                }
            }
        }
    }

    @Test func runAndUndoRewriteTheRealManifest() async throws {
        try await withTemporaryDirectoryAsync { root in
            try Self.makeBackup(root)
            let manifest = try Data(contentsOf: root.appending(path: ".photo-export/exported.tsv"))
            try await ReorganizeExecutor(destination: root, removeHelpers: true).start(plan: try Self.plan(root))
            #expect(ExportManifest.records(in: root) == [
                "icloud-id:A": ["2024/07/IMG_1.HEIC"],
                "icloud-id:B": ["2024/07/IMG_2.HEIC", "2024/07/IMG_2.MOV", "2024/07/IMG_2.HEIC.xmp"],
                "icloud-id:C": ["2023/11/IMG_3.JPG"],
                "icloud-id:D": ["2024/07/IMG_4.HEIC"],
            ])
            #expect(ExportManifest.layout(in: root) == .month)

            try await ReorganizeExecutor(destination: root, removeHelpers: true).undo()
            #expect(try Data(contentsOf: root.appending(path: ".photo-export/exported.tsv")) == manifest)
            #expect(ExportManifest.layout(in: root) == .flat)
        }
    }

    @Test func undoIsRefusedAfterSevenDays() async throws {
        try await withTemporaryDirectoryAsync { root in
            try Self.makeBackup(root)
            try await Self.executor(root).start(plan: try Self.plan(root))
            let archive = try #require(try Self.archive(in: root, suffix: ".done"))
            let old = archive.deletingLastPathComponent().appending(path: "reorganize-20200101-000000.done")
            try FileManager.default.moveItem(at: archive, to: old)
            await #expect(throws: ReorganizeError.undoUnavailable) {
                try await Self.executor(root).undo()
            }
        }
    }
}

// MARK: - Test doubles

/// The crash a test injects. It stands for the process dying right after the operation.
struct InjectedCrash: Error {}

/// Counts the mutating operations and stops at one of them: a crash after it, or a failure before it.
final class Faults: Sendable {
    private struct State: Sendable {
        var count = 0
        var crashAfter: Int?
        var failBefore: Int?
        var code: POSIXErrorCode = .EIO
    }

    private let state: OSAllocatedUnfairLock<State>

    init(crashAfter: Int? = nil, failBefore: Int? = nil, code: POSIXErrorCode = .EIO) {
        state = OSAllocatedUnfairLock(initialState: State(crashAfter: crashAfter, failBefore: failBefore, code: code))
    }

    var operations: Int {
        state.withLock { $0.count }
    }

    func perform<T>(_ body: () throws -> T) throws -> T {
        let (number, fail, code) = state.withLock { state -> (Int, Bool, POSIXErrorCode) in
            state.count += 1
            return (state.count, state.count == state.failBefore, state.code)
        }
        if fail {
            throw POSIXError(code)
        }
        let value = try body()
        if state.withLock({ $0.crashAfter == number }) {
            throw InjectedCrash()
        }
        return value
    }
}

/// The maps the manifest phase was given, in order.
final class MapLog: Sendable {
    let maps = OSAllocatedUnfairLock<[[String: String]]>(initialState: [])
}

/// The live file system with the mutating operations counted through `Faults`.
struct FaultyFS: ReorganizeFileSystem {
    let faults: Faults
    private let base = LiveReorganizeFileSystem()

    init(faults: Faults) {
        self.faults = faults
    }

    func rename(_ from: URL, to: URL) throws {
        try faults.perform { try base.rename(from, to: to) }
    }

    func unlink(_ url: URL) throws {
        try faults.perform { try base.unlink(url) }
    }

    func removeEmptyDirectory(_ url: URL) throws {
        try faults.perform { try base.removeEmptyDirectory(url) }
    }

    func createDirectory(_ url: URL) throws {
        try faults.perform { try base.createDirectory(url) }
    }

    func list(_ folder: URL) throws -> [String: BulkDirectoryLister.Entry] {
        try base.list(folder)
    }

    func read(_ url: URL) throws -> Data {
        try base.read(url)
    }

    func writeNew(_ url: URL, _ data: Data) throws {
        try faults.perform { try base.writeNew(url, data) }
    }

    func append(_ url: URL, _ data: Data) throws {
        try faults.perform { try base.append(url, data) }
    }

    func exists(_ url: URL) -> Bool {
        base.exists(url)
    }

    func freeBytes(_ url: URL) throws -> Int64 {
        try base.freeBytes(url)
    }
}
