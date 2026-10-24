import Foundation
import Testing
@testable import Uncloud

/// The Google Photos import's state: what the pane shows and which runs are allowed. The engine is replaced by a
/// scripted run, and every folder is a temporary one.
@MainActor
@Suite("GoogleImportModel")
struct GoogleImportModelTests {
    struct TimedOut: Error {}

    /// What the app would tell the import: the folder, its layout, whether an export runs, and a destination problem.
    @MainActor
    final class HostState {
        var destination: URL?
        var layout: FolderLayout = .month
        var isExporting = false
        var destinationIssue: String?
    }

    /// The model with its host and engine replaced. The test feeds the run's events through `feed`.
    @MainActor
    final class Harness {
        let host: HostState
        let model: GoogleImportModel
        /// The importers the model started, one per run.
        private(set) var importers: [TakeoutImporter] = []
        /// Feeds the events of the latest run. Finishing it ends the run without an error.
        private(set) var feed: AsyncStream<ExportEvent>.Continuation?
        /// The files the panel "chose", for `addInputs()`.
        var panelChoice: [URL] = []

        init(destination: URL?) {
            let host = HostState()
            host.destination = destination
            self.host = host
            model = GoogleImportModel(host: GoogleImportModel.Host(
                destination: { host.destination },
                destinationIssue: { host.destinationIssue },
                layout: { host.layout },
                isExporting: { host.isExporting }
            ))
        }

        /// Wires the engine: each run reads the events the test yields, and waits on the pause gate before each copy.
        func install() {
            model.makeRun = { [weak self] importer in
                self?.importers.append(importer)
                let (events, continuation) = AsyncStream.makeStream(of: ExportEvent.self)
                self?.feed = continuation
                return ExportRun.start { emit in
                    for await event in events {
                        if case .exported = event {
                            await importer.gate.waitWhilePaused()
                        }
                        try Task.checkCancellation()
                        emit(event)
                    }
                    // Ends with a cancellation when Stop was chosen, as the real engine does.
                    try Task.checkCancellation()
                }
            }
            model.chooseInputs = { [weak self] in self?.panelChoice ?? [] }
        }
    }

    /// Waits until `condition` holds, or fails the test.
    @MainActor
    private func waitFor(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<500 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw TimedOut()
    }

    /// A harness with a folder and one Takeout file chosen, ready to start.
    private func readyHarness(_ folder: URL) throws -> Harness {
        let harness = Harness(destination: folder)
        harness.install()
        harness.panelChoice = [try writeFile("zip", to: "takeout-001.zip", in: folder)]
        harness.model.addInputs()
        return harness
    }

    // MARK: - Runs

    @Test func aRunCountsItsPhotosListsTheFailuresAndCallsOnFinished() async throws {
        try await withTemporaryDirectoryAsync { folder in
            let harness = try readyHarness(folder)
            var finishedCalls = 0
            harness.model.onFinished = { finishedCalls += 1 }
            harness.model.start()
            #expect(harness.model.phase == .scanning)

            let feed = try #require(harness.feed)
            feed.yield(.note("Reading your Takeout files…"))
            feed.yield(.prepared(total: 5, alreadyExported: 1))
            feed.yield(.exported(name: "a.jpg", fileCount: 1, bytes: 10))
            feed.yield(.exported(name: "b.mov", fileCount: 2, bytes: 20))
            feed.yield(.skipped)
            feed.yield(.failed(name: "c.jpg", reason: "The file is damaged."))
            feed.finish()
            try await waitFor { !harness.model.isRunning }

            let expected = GoogleImportModel.Summary(
                imported: 2,
                alreadyInBackup: 2,
                failedCount: 1,
                failures: [GoogleImportModel.Failure(name: "c.jpg", reason: "The file is damaged.")],
                wasStopped: false
            )
            #expect(harness.model.phase == .finished(expected))
            #expect(harness.model.done == 5)
            #expect(harness.model.total == 5)
            #expect(finishedCalls == 1)
            #expect(harness.importers.first?.inputs == harness.model.inputs)
            #expect(harness.importers.first?.layout == .month)
        }
    }

    @Test func aRunIsScanningUntilTheTotalIsKnown() async throws {
        try await withTemporaryDirectoryAsync { folder in
            let harness = try readyHarness(folder)
            harness.model.start()
            #expect(harness.model.phase == .scanning)
            let feed = try #require(harness.feed)
            feed.yield(.prepared(total: 3, alreadyExported: 0))
            try await waitFor { harness.model.phase == .importing }
            feed.finish()
            try await waitFor { !harness.model.isRunning }
        }
    }

    @Test func pauseHoldsTheNextPhotoUntilResume() async throws {
        try await withTemporaryDirectoryAsync { folder in
            let harness = try readyHarness(folder)
            harness.model.start()
            let feed = try #require(harness.feed)
            feed.yield(.prepared(total: 3, alreadyExported: 0))
            feed.yield(.exported(name: "a.jpg", fileCount: 1, bytes: nil))
            try await waitFor { harness.model.done == 1 }

            harness.model.pause()
            #expect(harness.model.phase == .paused)
            #expect(harness.model.isPaused)
            feed.yield(.exported(name: "b.jpg", fileCount: 1, bytes: nil))
            try await Task.sleep(for: .milliseconds(200))
            #expect(harness.model.done == 1, "A paused import copies nothing")

            harness.model.resume()
            #expect(harness.model.phase == .importing)
            try await waitFor { harness.model.done == 2 }
            feed.finish()
            try await waitFor { !harness.model.isRunning }
            #expect(harness.model.phase == .finished(GoogleImportModel.Summary(
                imported: 2, alreadyInBackup: 0, failedCount: 0, failures: [], wasStopped: false
            )))
        }
    }

    @Test func stopEndsTheRunAndSaysWhatWasCopied() async throws {
        try await withTemporaryDirectoryAsync { folder in
            let harness = try readyHarness(folder)
            harness.model.start()
            let feed = try #require(harness.feed)
            feed.yield(.prepared(total: 3, alreadyExported: 0))
            feed.yield(.exported(name: "a.jpg", fileCount: 1, bytes: nil))
            try await waitFor { harness.model.done == 1 }

            harness.model.stop()
            #expect(harness.model.isStopping)
            try await waitFor { !harness.model.isRunning }
            #expect(harness.model.phase == .finished(GoogleImportModel.Summary(
                imported: 1, alreadyInBackup: 0, failedCount: 0, failures: [], wasStopped: true
            )))
            #expect(!harness.model.isStopping)
        }
    }

    @Test func stopWhilePausedEndsTheRun() async throws {
        try await withTemporaryDirectoryAsync { folder in
            let harness = try readyHarness(folder)
            harness.model.start()
            let feed = try #require(harness.feed)
            feed.yield(.prepared(total: 3, alreadyExported: 0))
            try await waitFor { harness.model.phase == .importing }
            harness.model.pause()
            harness.model.stop()
            try await waitFor { !harness.model.isRunning }
            #expect(harness.model.phase == .finished(GoogleImportModel.Summary(
                imported: 0, alreadyInBackup: 0, failedCount: 0, failures: [], wasStopped: true
            )))
        }
    }

    @Test func aRunThatFailsShowsItsErrorAndCanBeStartedAgain() async throws {
        try await withTemporaryDirectoryAsync { folder in
            let harness = try readyHarness(folder)
            var finishedCalls = 0
            harness.model.onFinished = { finishedCalls += 1 }
            // The engine stops with an error that isn't a cancellation, such as a full disk.
            harness.model.makeRun = { _ in ExportRun.start { _ in throw ExportError.destinationFull } }
            harness.model.start()
            try await waitFor { !harness.model.isRunning }
            #expect(harness.model.phase == .failed(ExportError.destinationFull.localizedDescription))
            #expect(finishedCalls == 1)
            #expect(harness.model.canStart, "A failed import can be started again; it picks up where it stopped")
        }
    }

    // MARK: - Starting

    @Test func cannotStartWithoutADestination() async throws {
        try await withTemporaryDirectoryAsync { folder in
            let harness = Harness(destination: nil)
            harness.install()
            harness.panelChoice = [try writeFile("zip", to: "takeout.zip", in: folder)]
            harness.model.addInputs()
            #expect(harness.model.blockReason == .noFolder)
            #expect(harness.model.blockReason?.message == "Choose a backup folder in Export Settings first.")
            #expect(!harness.model.canStart)
            harness.model.start()
            #expect(harness.model.phase == .idle)
            #expect(harness.importers.isEmpty)
        }
    }

    @Test func cannotStartWhileAnExportRuns() async throws {
        try await withTemporaryDirectoryAsync { folder in
            let harness = try readyHarness(folder)
            harness.host.isExporting = true
            #expect(harness.model.blockReason == .exporting)
            #expect(harness.model.blockReason?.message == "Wait for the export to finish.")
            harness.model.start()
            #expect(harness.model.phase == .idle)
            #expect(harness.importers.isEmpty)
        }
    }

    @Test func cannotStartWithoutFiles() async throws {
        try await withTemporaryDirectoryAsync { folder in
            let harness = Harness(destination: folder)
            harness.install()
            #expect(harness.model.blockReason == .noFiles)
            #expect(harness.model.blockReason?.message == "Choose the Takeout files you downloaded first.")
            harness.model.start()
            #expect(harness.model.phase == .idle)
        }
    }

    @Test func aDestinationProblemIsTheReason() async throws {
        try await withTemporaryDirectoryAsync { folder in
            let harness = try readyHarness(folder)
            harness.host.destinationIssue = "“Backup” isn’t connected."
            #expect(harness.model.blockReason == .destinationIssue("“Backup” isn’t connected."))
            #expect(harness.model.blockReason?.message == "“Backup” isn’t connected.")
        }
    }

    @Test func aReadyImportHasNoReason() async throws {
        try await withTemporaryDirectoryAsync { folder in
            let harness = try readyHarness(folder)
            #expect(harness.model.blockReason == nil)
            #expect(harness.model.canStart)
        }
    }

    @Test func layoutIsRecordedWhenTheFolderHasNone() async throws {
        try await withTemporaryDirectoryAsync { folder in
            let harness = try readyHarness(folder)
            harness.host.layout = .flat
            #expect(ExportManifest.layout(in: folder) == nil)
            harness.model.start()
            #expect(ExportManifest.layout(in: folder) == .flat)
            harness.feed?.finish()
            try await waitFor { !harness.model.isRunning }
        }
    }

    @Test func anExistingLayoutIsNeverChanged() async throws {
        try await withTemporaryDirectoryAsync { folder in
            try ExportManifest(destination: folder, marksRun: false).recordLayout(.album)
            let harness = try readyHarness(folder)
            harness.host.layout = .flat
            harness.model.start()
            #expect(ExportManifest.layout(in: folder) == .album)
            harness.feed?.finish()
            try await waitFor { !harness.model.isRunning }
        }
    }

    // MARK: - Chosen files

    @Test func filesAreAddedOnceAndRemoved() async throws {
        try await withTemporaryDirectoryAsync { folder in
            let harness = Harness(destination: folder)
            harness.install()
            let first = try writeFile("0123456789", to: "one.zip", in: folder)
            let second = try writeFile("abc", to: "two.zip", in: folder)
            harness.panelChoice = [first, second]
            harness.model.addInputs()
            harness.model.addInputs()
            #expect(harness.model.inputs == [first, second])
            #expect(harness.model.sizes[first] == 10)
            harness.model.remove(first)
            #expect(harness.model.inputs == [second])
            #expect(harness.model.sizes[first] == nil)
        }
    }

    @Test func filesCannotChangeDuringARun() async throws {
        try await withTemporaryDirectoryAsync { folder in
            let harness = try readyHarness(folder)
            harness.model.start()
            harness.panelChoice = [try writeFile("x", to: "later.zip", in: folder)]
            harness.model.addInputs()
            #expect(harness.model.inputs.count == 1)
            harness.feed?.finish()
            try await waitFor { !harness.model.isRunning }
        }
    }

    // MARK: - Summary copy

    @Test func summaryCopyUsesPlainWordsAndSingularForms() {
        let one = GoogleImportModel.Summary(imported: 1, alreadyInBackup: 1, failedCount: 0, failures: [], wasStopped: false)
        #expect(one.headline == "Imported 1 photo or video.")
        #expect(one.alreadyInBackupText == "1 was already in your backup.")

        let many = GoogleImportModel.Summary(imported: 4_988, alreadyInBackup: 12, failedCount: 3, failures: [], wasStopped: false)
        #expect(many.headline == "Imported \(4_988.formatted()) photos and videos.")
        #expect(many.alreadyInBackupText == "12 were already in your backup.")

        let none = GoogleImportModel.Summary(imported: 0, alreadyInBackup: 0, failedCount: 0, failures: [], wasStopped: false)
        #expect(none.alreadyInBackupText == nil)

        let stopped = GoogleImportModel.Summary(imported: 3, alreadyInBackup: 0, failedCount: 0, failures: [], wasStopped: true)
        #expect(stopped.headline == "Import stopped. Imported 3 so far.")
    }
}
