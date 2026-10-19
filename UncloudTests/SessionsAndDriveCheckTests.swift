import Foundation
import Testing
@testable import Uncloud

/// Export sessions and "Check the drive", end to end: an ExportModel or an engine against the fake icloudpd and
/// the fake bridge. Part of ExportCancellationTests, so it never runs alongside the other suites that swap the helpers.
extension ExportCancellationTests {
    private static func quickResumes() -> AutoResumeTiming {
        AutoResumeTiming(delays: [.milliseconds(150)], maxAttempts: 8, progressReset: 50, recheckInterval: .milliseconds(50))
    }

    private static let waitingResumes = AutoResumeTiming(delays: [.seconds(3600)], recheckInterval: .seconds(3600))

    private static func stateFile() -> String {
        FileManager.default.temporaryDirectory.appending(path: "uncloud-state-\(UUID().uuidString)").path(percentEncoded: false)
    }

    /// Sets the cached iCloud library size for one test and puts the old value back afterwards.
    @MainActor
    private static func withLibraryCount<T>(_ count: Int, _ body: () async throws -> T) async rethrows -> T {
        let key = "icloudLibraryCount"
        let old = UserDefaults.standard.object(forKey: key)
        UserDefaults.standard.set(count, forKey: key)
        defer { UserDefaults.standard.set(old, forKey: key) }
        return try await body()
    }

    private static func sessions(in destination: URL) -> [ExportSession] {
        SessionStore(destination: destination).list()
    }

    // MARK: - Sessions

    @Test @MainActor func sessionsAreWrittenAndChainedAcrossAnAutomaticResume() async throws {
        let state = Self.stateFile()
        defer { try? FileManager.default.removeItem(atPath: state) }
        let fixture = try Fixture(icloudpd: ["--total", "30", "--rate", "0", "--throttle-after", "5",
                                             "--throttle-runs", "1", "--throttle-state", state])
        let harness = ModelHarness(fixture: fixture, timing: Self.quickResumes())
        let model = harness.model
        try await Self.withLibraryCount(30) {
            model.startOrResume()
            #expect(await harness.waitFor { model.phase == .completed })
            await model.flushSessionWrites()

            let sessions = Self.sessions(in: fixture.destination)
            try #require(sessions.count == 2)
            let (first, second) = (sessions[0], sessions[1])
            #expect(first.attempt == 1 && second.attempt == 2)
            #expect(first.chainID == first.id)
            #expect(second.chainID == first.chainID)
            #expect(first.trigger == .manual)
            #expect(second.trigger == .autoResume)
            #expect(first.result == ExportSession.Result(status: .failed, reason: "Apple is limiting downloads", retryable: true))
            #expect(first.autoResume?.attempt == 1)
            #expect(second.result.status == .completed)
            #expect(second.autoResume == nil)
            #expect(first.counts.exported == 5)
            #expect(second.counts.exported == 25)
            #expect(first.counts.bytesWritten > 0)
            #expect(first.launchID == ExportModel.launchID)
            #expect(first.source == .iCloud && first.layout == .month)
            #expect(first.account == ExportSession.accountHash(appleID: fixture.appleID))
            #expect(first.selection == ExportSession.SelectionSummary(kind: .everything, count: 30))
            // Each attempt checked the drive first; the second found the first's five items.
            #expect(first.driveCheck?.onDrive == 0)
            #expect(second.driveCheck?.onDrive == 5)
            #expect(second.driveCheck?.toGo == 25)
            #expect(sessions.allSatisfy { $0.endedAt != nil })

            // Export History groups the attempts into one chain.
            let history = model.exportHistory
            #expect(history.count == 1)
            #expect(history.first?.attempts.count == 2)
            #expect(history.first?.badge == .completed)
            #expect(history.first?.exported == 30)
            #expect(history.first?.isAutomatic == true)
            // Counts after the export are items on the drive.
            #expect(model.processedCount == 30)
            #expect(model.totalCount == 30)
        }
        await harness.tearDown()
    }

    @Test @MainActor func historyShowsTheLiveResumeTimeWhileWaiting() async throws {
        let fixture = try Fixture(icloudpd: ["--total", "100", "--rate", "0", "--throttle-after", "5"])
        let harness = ModelHarness(fixture: fixture, timing: Self.waitingResumes)
        let model = harness.model
        model.startOrResume()
        #expect(await harness.waitFor { model.autoResume != nil && !model.isEngineRunning })
        let pending = try #require(model.autoResume)
        let newest = try #require(model.exportHistory.first)
        #expect(newest.badge == .resuming(at: pending.resumeAt))
        #expect(newest.badgeText == "Resuming at \(ExportModel.resumeTimeText(pending.resumeAt))")

        // Without the pending resume, the same attempt reads as stopped.
        model.cancelAutoResume()
        #expect(model.exportHistory.first?.badge == .stopped(reason: "Apple is limiting downloads"))
        await harness.tearDown()
    }

    @Test @MainActor func cancellingAnExportEndsItsSessionAsCancelled() async throws {
        let fixture = try Fixture(icloudpd: ["--total", "100000", "--rate", "100"])
        let harness = ModelHarness(fixture: fixture, timing: Self.waitingResumes)
        let model = harness.model
        model.startOrResume()
        #expect(await harness.waitFor { model.phase == .running && model.processedCount >= 5 })
        model.cancel()
        #expect(await harness.waitFor { model.phase == .cancelled })
        await model.flushSessionWrites()

        let session = try #require(Self.sessions(in: fixture.destination).last)
        #expect(session.result.status == .cancelled)
        #expect(session.counts.exported >= 5)
        #expect(session.endedAt != nil)
        await harness.tearDown()
    }

    @Test @MainActor func resumingByHandSoonAfterACancelContinuesTheChain() async throws {
        let fixture = try Fixture(icloudpd: ["--total", "200", "--rate", "100"])
        let harness = ModelHarness(fixture: fixture, timing: Self.waitingResumes)
        let model = harness.model
        model.startOrResume()
        #expect(await harness.waitFor { model.phase == .running && model.processedCount >= 5 })
        model.cancel()
        #expect(await harness.waitFor { model.phase == .cancelled && !model.isEngineRunning && model.hasIncompleteRun })

        model.startOrResume()
        #expect(await harness.waitFor { model.phase == .completed })
        await model.flushSessionWrites()
        let sessions = Self.sessions(in: fixture.destination).sorted { $0.attempt < $1.attempt }
        try #require(sessions.count == 2)
        #expect(sessions[0].result.status == .cancelled)
        #expect(sessions[1].trigger == .resume)
        #expect(sessions[1].attempt == 2)
        #expect(sessions[1].chainID == sessions[0].chainID)
        #expect(model.exportHistory.count == 1)
        await harness.tearDown()
    }

    @Test @MainActor func sessionsLeftRunningByAnEarlierLaunchAreSweptAsInterrupted() async throws {
        let fixture = try Fixture()
        let started = Date().addingTimeInterval(-3600)
        var orphan = ExportSession(
            trigger: .manual, startedAt: started, appVersion: "0.1.3 (4)", launchID: UUID(),
            source: .iCloud, layout: .month, writesSidecars: false,
            selection: ExportSession.SelectionSummary(kind: .everything, count: 10)
        )
        orphan.updatedAt = started.addingTimeInterval(60)
        // A fresh one from another Mac writing to the same drive: left alone.
        var fresh = orphan
        fresh.id = UUID()
        fresh.chainID = fresh.id
        fresh.startedAt = Date()
        fresh.updatedAt = Date()
        let store = SessionStore(destination: fixture.destination)
        try store.write(orphan)
        try store.write(fresh)

        let harness = ModelHarness(fixture: fixture, timing: Self.waitingResumes)
        let model = harness.model
        #expect(await harness.waitFor { model.sessions.count == 2 })
        let swept = try #require(model.sessions.first { $0.id == orphan.id })
        #expect(swept.result.status == .interrupted)
        #expect(swept.result.reason == "Uncloud quit or the Mac restarted while exporting")
        // Stored to the millisecond.
        #expect(swept.endedAt.map { abs($0.timeIntervalSince(orphan.updatedAt)) < 0.001 } == true)
        #expect(model.sessions.first { $0.id == fresh.id }?.result.status == .running)
        #expect(store.list().first { $0.id == orphan.id }?.result.status == .interrupted)
        #expect(model.exportHistory.contains { $0.badge == .interrupted })
        await harness.tearDown()
    }

    // MARK: - Checking the drive

    @Test @MainActor func cancellingWhileTheDriveIsCheckedLaunchesNoEngine() async throws {
        let fixture = try Fixture(icloudpd: ["--total", "10", "--rate", "0"])
        // Enough of the user's own files that listing them takes a while. Not at icloudpd paths, so never recorded.
        for folder in 0..<20 {
            let directory = fixture.destination.appending(path: "Documents/folder\(folder)", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for index in 0..<1_000 {
                FileManager.default.createFile(atPath: directory.appending(path: "note\(index).txt").path(percentEncoded: false), contents: nil)
            }
        }
        let harness = ModelHarness(fixture: fixture, timing: Self.waitingResumes)
        let model = harness.model
        model.startOrResume()
        #expect(await harness.waitFor { model.phase == .preparing && model.isCheckingDrive })
        model.cancel()
        #expect(await harness.waitFor { model.phase == .cancelled })
        #expect(!model.isCheckingDrive)
        try await Task.sleep(for: .milliseconds(300))
        #expect(harness.icloudpdLaunches == 0)
        #expect(ExportManifest.records(in: fixture.destination).isEmpty)
        await model.flushSessionWrites()
        #expect(Self.sessions(in: fixture.destination).last?.result.status == .cancelled)
        await harness.tearDown()
    }

    /// The owner's case: a backup with export history but no New Photos watermark still offers new photos only.
    @Test @MainActor func newPhotosOfferComesFromTheBackupNotTheWatermark() async throws {
        let fixture = try Fixture(icloudpd: ["--total", "20", "--rate", "0"])
        let harness = ModelHarness(fixture: fixture, timing: Self.waitingResumes)
        let model = harness.model
        try await Self.withLibraryCount(21) {
            // Before any run the folder holds nothing: the first export keeps its title.
            #expect(!model.offersNewPhotosOnly)
            #expect(model.primaryExportTitle(total: nil) == "Export All Photos")

            model.startOrResume()
            #expect(await harness.waitFor { model.phase == .completed })
            #expect(await harness.waitFor { !model.isEngineRunning })
            // The run left no watermark, as with runs that had a failed item or came before New Photos.
            #expect(model.newPhotosStatus == nil)
            #expect(model.onDriveCount == 20)
            #expect(model.toGoCount == 1)
            #expect(model.offersNewPhotosOnly)
            #expect(model.primaryExportHelp == NewPhotosTitle.newOnlyHelp)
            // Items recorded by asset ID count exactly. Path-only records make the count approximate, and then the
            // title and subtitle drop the number (plan 1.3). Both are the same offer.
            if model.isOnDriveCountApproximate {
                #expect(model.primaryExportTitle(total: nil) == "Export New Photos")
                #expect(model.notBackedUpSummary == "about 1 not backed up")
            } else {
                #expect(model.primaryExportTitle(total: nil) == "Export 1 New Photo")
                #expect(model.notBackedUpSummary == "1 not backed up")
            }
        }
        await harness.tearDown()
    }

    @Test @MainActor func checkDriveFindsMissingTruncatedUntrackedAndPartialFiles() async throws {
        let fixture = try Fixture(icloudpd: ["--total", "20", "--rate", "0"])
        let harness = ModelHarness(fixture: fixture, timing: Self.waitingResumes)
        let model = harness.model
        try await Self.withLibraryCount(20) {
            model.startOrResume()
            #expect(await harness.waitFor { model.phase == .completed })
            // A full check records every file's size.
            #expect(await harness.waitFor { model.canCheckDrive })
            model.checkDrive()
            #expect(await harness.waitFor { model.lastDriveCheck?.mode == .full && !model.isCheckingDrive })
            #expect(model.lastDriveCheck?.onDrive == 20)

            let destination = fixture.destination
            let missing = "2001/01/IMG_000003.JPG"
            let truncated = "2001/01/IMG_000004.JPG"
            let untracked = "2001/01/IMG_EXTRA.JPG"
            try FileManager.default.removeItem(at: destination.appending(path: missing))
            try writeFile("pho", to: truncated, in: destination)
            try writeFile("from an icloudpd run", to: untracked, in: destination)
            try writeFile("half", to: "2001/01/IMG_000099.JPG.part", in: destination)
            try writeFile("mine", to: "notes.txt", in: destination)

            model.checkDrive()
            #expect(await harness.waitFor {
                if case .checked(let report) = model.driveCheckState { report.missingItems > 0 } else { false }
            })
            let report = try #require(model.lastDriveCheck)
            #expect(report.mode == .full)
            #expect(report.missingFiles == [missing])
            #expect(report.damagedFiles == [truncated])
            #expect(report.setAsideFiles == [truncated])
            #expect(report.registeredFiles == [untracked])
            #expect(report.otherFiles == 1)
            #expect(report.partialFiles == 1)
            #expect(report.onDrive == 19, "20 − missing − truncated + the untracked download")
            #expect(report.isApproximate)
            #expect(model.processedCount == 19)
            #expect(model.onDriveSummaryText == "about 19 backed up · about 1 to go")

            // Set aside, never deleted; the records are gone, so the next export downloads both again.
            let aside = destination.appending(path: ".photo-export/set-aside/\(report.setAsideFolder)/\(truncated)")
            #expect(try String(contentsOf: aside, encoding: .utf8) == "pho")
            let records = ExportManifest.records(in: destination)
            #expect(records["icloud:\(missing)"] == nil)
            #expect(records["icloud:\(truncated)"] == nil)
            #expect(records["icloud:\(untracked)"] == [untracked])
            #expect(ExportManifest.checksums(in: destination)[untracked] == nil, "hashed later, not during the check")

            let launches = harness.icloudpdLaunches
            model.startOrResume()
            #expect(await harness.waitFor { model.phase == .completed && harness.icloudpdLaunches == launches + 1 })
            #expect(try String(contentsOf: destination.appending(path: truncated), encoding: .utf8) == "photo 4\n")
            #expect(FileManager.default.fileExists(atPath: destination.appending(path: missing).path(percentEncoded: false)))
            // The export's scanner backfilled the untracked file's checksum.
            #expect(ExportManifest.checksums(in: destination)[untracked] != nil)
            #expect(FileManager.default.fileExists(atPath: aside.path(percentEncoded: false)))
        }
        await harness.tearDown()
    }

    @Test @MainActor func progressStartsFromWhatIsAlreadyOnTheDrive() async throws {
        let state = Self.stateFile()
        defer { try? FileManager.default.removeItem(atPath: state) }
        let fixture = try Fixture(icloudpd: ["--total", "30", "--rate", "15", "--throttle-after", "10",
                                             "--throttle-runs", "1", "--throttle-state", state])
        let harness = ModelHarness(fixture: fixture, timing: Self.waitingResumes)
        let model = harness.model
        await Self.withLibraryCount(30) {
            model.startOrResume()
            #expect(await harness.waitFor { model.autoResume != nil && !model.isEngineRunning })
            model.cancelAutoResume()

            model.startOrResume()
            var lowest: Int?
            var firstRunning: Int?
            var highest = 0
            #expect(await harness.waitFor(.seconds(20)) {
                if model.phase == .running {
                    firstRunning = firstRunning ?? model.processedCount
                    lowest = min(lowest ?? .max, model.processedCount)
                    highest = max(highest, model.processedCount)
                }
                return model.phase == .completed
            })
            #expect(firstRunning.map { (10...11).contains($0) } == true, "\(String(describing: firstRunning))")
            #expect(lowest == firstRunning)
            #expect(highest <= 30)
            #expect(model.processedCount == 30)
        }
        await harness.tearDown()
    }

    @Test @MainActor func idleCountIsItemsNotFilesWithLivePhotosAndSidecars() async throws {
        let fixture = try Fixture(icloudpd: ["--total", "20", "--rate", "0", "--live-every", "2"])
        let harness = ModelHarness(fixture: fixture, timing: Self.waitingResumes)
        let model = harness.model
        model.writesSidecars = true
        defer { model.writesSidecars = false }
        await Self.withLibraryCount(20) {
            model.startOrResume()
            #expect(await harness.waitFor { model.phase == .completed })
            #expect(fixture.files(withExtension: "JPG").count == 20)
            #expect(fixture.files(withExtension: "MOV").count == 10)
            #expect(fixture.files(withExtension: "xmp").count == 20)
            // 50 files, 20 items.
            #expect(await harness.waitFor { !model.isEngineRunning && model.processedCount == 20 })
            #expect(model.totalCount == 20)
            let (progress, isApproximate) = ExportModel.iCloudProgress(toward: fixture.destination, selection: .everything)
            #expect(progress.exported == 20)
            #expect(isApproximate)
        }
        await harness.tearDown()
    }

    // MARK: - Bridge records

    @Test func bridgeDownloadsAreRecordedByAssetIDAndAHalfDoneLivePhotoIsNot() async throws {
        let first = try Fixture(bridge: ["--total", "10", "--rate", "0", "--live-every", "2", "--movie-fails-at", "4"])
        let destination = first.destination
        defer { first.tearDown() }
        // Everything but an item that doesn't exist: the bridge path, which knows each item's asset ID.
        let selection = LibrarySelection.allExcept(["asset-none"])
        let run = first.engine(selection: selection).start()
        let collector = Collector()
        await collector.read(run).value
        #expect(collector.snapshot.processed == 10)

        let items = ExportManifest.iCloudItems(in: destination)
        #expect(items.count == 9)
        #expect(items["asset-4"] == nil)
        #expect(items["asset-0"] == ["2001/01/IMG_000000.JPG", "2001/01/IMG_000000.MOV"])
        #expect(items["asset-1"] == ["2001/01/IMG_000001.JPG"])
        let records = ExportManifest.records(in: destination)
        #expect(records["icloud-partial:asset-4"] == ["2001/01/IMG_000004.JPG"])
        // The half-done photo isn't recorded by path either, so it never counts as on the drive.
        #expect(records.keys.allSatisfy { !$0.hasPrefix("icloud:") })
        #expect(ICloudItemCount.count(records: records) == ICloudItemCount.Count(exact: 9, grouped: 0))
        // The recorded files still get checksums.
        #expect(ExportManifest.checksums(in: destination)["2001/01/IMG_000000.MOV"] != nil)

        // The next run (the movie downloads this time) finishes the item. The nine done items are counted from
        // the start, not as skips.
        let second = try Fixture(bridge: ["--total", "10", "--rate", "0", "--live-every", "2"])
        defer { second.tearDown() }
        let next = second.engine(selection: selection, destination: destination).start()
        let nextCollector = Collector()
        await nextCollector.read(next).value
        #expect(nextCollector.snapshot.error == nil)
        #expect(nextCollector.snapshot.exported == 1)
        #expect(nextCollector.snapshot.processed == 1)
        let finished = ExportManifest.records(in: destination)
        #expect(finished["icloud-id:asset-4"] == ["2001/01/IMG_000004.JPG", "2001/01/IMG_000004.MOV"])
        #expect(ICloudItemCount.count(records: finished).total == 10)
    }
}
