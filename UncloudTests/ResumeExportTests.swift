import Foundation
import Testing
@testable import Uncloud

/// Resume Export: the primary action continues an interrupted run, with the selection that run used.
@Suite("Resume Export")
struct ResumeExportTests {
    /// A session that ended with `status`, having used `kind` of selection.
    private static func session(_ kind: ExportSession.SelectionKind, _ status: ExportSession.Status) -> ExportSession {
        var session = ExportSession(
            trigger: kind == .everything ? .exportAll : .manual,
            startedAt: Date(timeIntervalSinceReferenceDate: 800_000_000),
            appVersion: "test",
            launchID: UUID(),
            source: .iCloud,
            layout: .month,
            writesSidecars: false,
            selection: ExportSession.SelectionSummary(kind: kind, count: 300)
        )
        session.result = ExportSession.Result(status: status, reason: nil, retryable: nil)
        return session
    }

    @Test func resumeExportIsOfferedAfterAnUnfinishedRunStopsWithNoCountdown() {
        let pending = AutoResume(attempt: 1, resumeAt: Date(), reason: "Apple is limiting downloads", selection: nil, automatic: false)
        // Idle after a relaunch, or stopped in this launch by Cancel or a failure.
        #expect(ExportModel.offersResumeExport(phase: .idle, hasIncompleteRun: true, autoResume: nil))
        #expect(ExportModel.offersResumeExport(phase: .cancelled, hasIncompleteRun: true, autoResume: nil))
        #expect(ExportModel.offersResumeExport(phase: .failed("Stopped"), hasIncompleteRun: true, autoResume: nil))
        // Not without an unfinished run, while exporting, or while an automatic resume counts down.
        #expect(!ExportModel.offersResumeExport(phase: .idle, hasIncompleteRun: false, autoResume: nil))
        #expect(!ExportModel.offersResumeExport(phase: .cancelled, hasIncompleteRun: false, autoResume: nil))
        #expect(!ExportModel.offersResumeExport(phase: .paused, hasIncompleteRun: true, autoResume: nil))
        #expect(!ExportModel.offersResumeExport(phase: .running, hasIncompleteRun: true, autoResume: nil))
        #expect(!ExportModel.offersResumeExport(phase: .completed, hasIncompleteRun: true, autoResume: nil))
        #expect(!ExportModel.offersResumeExport(phase: .failed("Stopped"), hasIncompleteRun: true, autoResume: pending))
    }

    @Test func anUnfinishedExportAllSessionMeansResumeExportAll() {
        #expect(ExportModel.interruptedRunWasExportAll(sessions: [Self.session(.everything, .interrupted)]))
        #expect(ExportModel.interruptedRunWasExportAll(sessions: [Self.session(.everything, .failed)]))
        #expect(ExportModel.interruptedRunWasExportAll(sessions: [Self.session(.everything, .running)]))
    }

    @Test func otherSelectionsAndFinishedRunsResumeWithTheSavedSelection() {
        #expect(!ExportModel.interruptedRunWasExportAll(sessions: []))
        #expect(!ExportModel.interruptedRunWasExportAll(sessions: [Self.session(.only, .interrupted)]))
        #expect(!ExportModel.interruptedRunWasExportAll(sessions: [Self.session(.allExcept, .cancelled)]))
        #expect(!ExportModel.interruptedRunWasExportAll(sessions: [Self.session(.everything, .completed)]))
        // Only the newest session counts: an older unfinished Export All behind a completed run isn't resumed.
        #expect(!ExportModel.interruptedRunWasExportAll(sessions: [Self.session(.everything, .interrupted), Self.session(.only, .completed)]))
    }

    @Test @MainActor func otherwiseTheTitlesAreUnchanged() {
        UserDefaults.standard.removeObject(forKey: ExportModel.bookmarkKey)
        let model = ExportModel()
        model.selection = .everything
        #expect(model.exportTitle(total: 10) == "Export All Photos")
        model.selection = .only(["a", "b"])
        #expect(model.exportTitle(total: 10) == "Export 2 Photos")
    }
}

/// Resume Export end to end against the fake icloudpd, as ExportCancellationTests runs it.
extension ExportCancellationTests {
    /// Gives up at once, so the run stops the way an interrupted one does: unfinished, with no retry scheduled.
    private static let giveUpTiming = AutoResumeTiming(delays: [.milliseconds(150)], maxAttempts: 0, recheckInterval: .milliseconds(50))

    @Test @MainActor func resumeExportAfterARelaunchContinuesAnExportAllWithEverything() async throws {
        let state = FileManager.default.temporaryDirectory.appending(path: "uncloud-resume-\(UUID().uuidString)").path(percentEncoded: false)
        defer { try? FileManager.default.removeItem(atPath: state) }
        // The first run is throttled after 100 items and gives up; the relaunched run is not throttled.
        let fixture = try Fixture(icloudpd: ["--total", "300", "--rate", "0", "--throttle-after", "100",
                                             "--throttle-runs", "1", "--throttle-state", state])
        let first = ModelHarness(fixture: fixture, timing: Self.giveUpTiming)
        // The saved selection is one item; Export All overrides it for that run only.
        first.model.selection = .only(["asset-1"])
        first.model.exportAll()
        #expect(await first.waitFor { first.model.phase == .failed(AutoResumePolicy.gaveUpMessage) })
        #expect(await first.waitFor { !first.model.isEngineRunning })
        // Still in this launch: the failed run is offered for Resume Export too. The offer comes from an asynchronous
        // progress refresh, so wait for it, as the cancel test does.
        #expect(await first.waitFor { first.model.offersResumeExport })
        #expect(first.model.primaryExportTitle(total: nil) == "Resume Export")
        #expect(!first.model.canExportAll)

        // Relaunch: a new model reads the destination's session and the unfinished-run marker.
        let relaunched = ModelHarness(fixture: fixture, timing: Self.giveUpTiming)
        let model = relaunched.model
        #expect(await relaunched.waitFor { model.interruptedRunWasExportAll })
        #expect(model.hasIncompleteRun)
        #expect(model.selection == .only(["asset-1"]))
        #expect(model.primaryExportTitle(total: nil) == "Resume Export")
        #expect(model.primaryExportEnabled(total: nil))
        #expect(!model.canExportAll)

        model.startOrResume()
        #expect(await relaunched.waitFor { model.phase == .completed })
        #expect(fixture.files(withExtension: "JPG").count == 300)
        #expect(!ExportManifest.hasIncompleteRun(in: fixture.destination))
        // The resumed run continues the first attempt's chain, recorded as resumed by hand, with everything selected.
        let last = try #require(SessionStore(destination: fixture.destination).list().last)
        #expect(last.trigger == .resume)
        #expect(last.selection.kind == .everything)
        #expect(last.attempt == 2)
        await relaunched.tearDown()
    }

    @Test @MainActor func anUnfinishedRunThatWasNotExportAllFallsBackToTheSavedSelection() async throws {
        let fixture = try Fixture(icloudpd: ["--total", "300", "--rate", "0"])
        // An unfinished run of a partial selection, as an earlier launch left its session and marker. Its item IDs
        // aren't kept, so Resume Export can only use the saved selection.
        var interrupted = ExportSession(
            trigger: .manual,
            startedAt: Date(timeIntervalSinceReferenceDate: 800_000_000),
            appVersion: "test",
            launchID: UUID(),
            source: .iCloud,
            layout: .month,
            writesSidecars: false,
            selection: ExportSession.SelectionSummary(kind: .only, count: 1)
        )
        interrupted.result = ExportSession.Result(status: .interrupted, reason: nil, retryable: nil)
        try SessionStore(destination: fixture.destination).write(interrupted)
        _ = try ExportManifest(destination: fixture.destination)

        let harness = ModelHarness(fixture: fixture, timing: Self.giveUpTiming)
        let model = harness.model
        #expect(await harness.waitFor { model.hasIncompleteRun })
        #expect(!model.interruptedRunWasExportAll)
        #expect(model.primaryExportTitle(total: nil) == "Resume Export")
        #expect(!model.canExportAll)
        await harness.tearDown()
    }

    @Test @MainActor func aCancelledRunOffersResumeExport() async throws {
        let fixture = try Fixture(icloudpd: ["--total", "2000", "--rate", "20"])
        let harness = ModelHarness(fixture: fixture, timing: Self.giveUpTiming)
        let model = harness.model
        model.exportAll()
        #expect(await harness.waitFor { model.phase == .running && model.processedCount > 0 })
        model.cancel()
        #expect(await harness.waitFor { model.phase == .cancelled && !model.isEngineRunning })
        // The progress that says the run is unfinished is read in the background after the cancel.
        #expect(await harness.waitFor { model.hasIncompleteRun })
        #expect(model.offersResumeExport)
        #expect(model.primaryExportTitle(total: 2_000) == "Resume Export")
        #expect(!model.canExportAll)
        await harness.tearDown()
    }

    @Test @MainActor func aPausedRunStillSaysResume() async throws {
        // Slow enough to pause in the middle.
        let fixture = try Fixture(icloudpd: ["--total", "2000", "--rate", "20"])
        let harness = ModelHarness(fixture: fixture, timing: Self.giveUpTiming)
        let model = harness.model
        model.exportAll()
        #expect(await harness.waitFor { model.phase == .running && model.processedCount > 0 })
        model.pause()
        #expect(model.phase == .paused)
        #expect(model.exportTitle(total: 2_000) == "Resume")
        #expect(model.primaryExportTitle(total: 2_000) == "Resume")
        #expect(!model.canExportAll)
        await harness.tearDown()
    }
}
