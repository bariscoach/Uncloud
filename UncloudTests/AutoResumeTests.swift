import AppKit
import Foundation
import Testing
@testable import Uncloud

@Suite("AutoResumePolicy")
struct AutoResumePolicyTests {
    @Test func retriesFailuresThatPassByThemselves() {
        #expect(AutoResumePolicy.isRetryable(ICloudError.failed(.serviceUnavailable)))
        #expect(AutoResumePolicy.isRetryable(ICloudError.failed(.network)))
        #expect(AutoResumePolicy.isRetryable(ICloudError.failed(.libraryIndexing)))
        #expect(AutoResumePolicy.isRetryable(ICloudError.interrupted))
        #expect(AutoResumePolicy.reason(for: ICloudError.failed(.serviceUnavailable)) == "Apple is limiting downloads")
        #expect(AutoResumePolicy.reason(for: ICloudError.failed(.network)) == "Your Mac is offline")
        #expect(AutoResumePolicy.reason(for: ICloudError.failed(.libraryIndexing)) == "iCloud is still preparing your library")
    }

    @Test func doesNotRetryWhatNeedsTheUser() {
        let errors: [Error] = [
            ICloudError.signInRequired,
            ICloudError.failed(.invalidCredentials),
            ICloudError.failed(.twoFactorFailed),
            ICloudError.failed(.sessionExpired(needsSignIn: true)),
            ICloudError.failed(.setupIncomplete),
            ICloudError.failed(.webAccessDisabled),
            ICloudError.failed(.other("Something")),
            ICloudError.helperMissing,
            ICloudError.exited(1, lastMessage: "Something"),
            ExportError.destinationFull,
            ExportError.destinationUnavailable,
            CancellationError(),
            CocoaError(.fileWriteOutOfSpace),
        ]
        for error in errors {
            #expect(!AutoResumePolicy.isRetryable(error), "\(error)")
        }
    }

    @Test func backoffIs15Then30ThenHourlyForAboutSixHours() {
        let timing = AutoResumeTiming()
        let delays = (1...timing.maxAttempts).map { timing.delay(beforeAttempt: $0) }
        #expect(delays == [.seconds(900), .seconds(1800)] + Array(repeating: .seconds(3600), count: 6))
        #expect(delays.reduce(.zero, +) == .seconds(405 * 60))
    }

    @Test func attemptsCountUpToTheCapThenGiveUp() {
        let timing = AutoResumeTiming()
        #expect(AutoResumePolicy.nextAttempt(after: nil, downloaded: 0, timing: timing) == 1)
        #expect(AutoResumePolicy.nextAttempt(after: nil, downloaded: 9_207, timing: timing) == 1)
        #expect(AutoResumePolicy.nextAttempt(after: 1, downloaded: 0, timing: timing) == 2)
        #expect(AutoResumePolicy.nextAttempt(after: 7, downloaded: 49, timing: timing) == 8)
        #expect(AutoResumePolicy.nextAttempt(after: 8, downloaded: 0, timing: timing) == nil)
    }

    @Test func aResumedRunThatMadeProgressStartsTheCountAgain() {
        let timing = AutoResumeTiming()
        #expect(AutoResumePolicy.nextAttempt(after: 5, downloaded: 50, timing: timing) == 1)
        #expect(AutoResumePolicy.nextAttempt(after: 8, downloaded: 1_000, timing: timing) == 1)
    }

    @Test func statusTextCountsDownAndNamesTheDrive() {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let resumeAt = now.addingTimeInterval(14 * 60 - 20)
        let pending = AutoResume(attempt: 2, resumeAt: resumeAt, reason: "Apple is limiting downloads", selection: nil, automatic: false)
        let text = AutoResumeStatus.text(for: pending, destinationName: "Drive", now: now)
        #expect(text.hasPrefix("Apple is limiting downloads. Resuming automatically at \(ExportModel.resumeTimeText(resumeAt)) (in 14"))
        var waiting = pending
        waiting.isWaitingForDestination = true
        #expect(AutoResumeStatus.text(for: waiting, destinationName: "Drive", now: now)
            == "Apple is limiting downloads. Uncloud resumes automatically when “Drive” is connected.")
    }
}

/// Automatic resume end to end: an ExportModel against the fake icloudpd, which Apple "throttles".
/// Part of ExportCancellationTests, so it never runs alongside the other suites that swap the helpers.
extension ExportCancellationTests {
    /// A wall clock tests can move forward; the real one until they do.
    @MainActor
    final class TestClock {
        var override: Date?
        var date: Date { override ?? Date() }
    }

    /// A model exporting the fake's library from the fake account into the fixture's destination.
    @MainActor
    final class ModelHarness {
        let model: ExportModel
        let fixture: Fixture
        let clock = TestClock()
        var storageQuestions = 0

        init(fixture: Fixture, timing: AutoResumeTiming) {
            let defaults = UserDefaults.standard
            defaults.removeObject(forKey: ExportModel.bookmarkKey)
            defaults.set(LibrarySource.iCloud.rawValue, forKey: "librarySource")
            defaults.set(FolderLayout.month.rawValue, forKey: "folderLayout")
            ICloudAccount.appleID = fixture.appleID
            self.fixture = fixture
            model = ExportModel()
            model.chooseDestination(.success(fixture.destination))
            model.autoResumeTiming = timing
            let clock = clock
            model.currentDate = { clock.date }
            model.storageWarningConfirmation = { [weak self] _ in
                self?.storageQuestions += 1
                return true
            }
        }

        var icloudpdLaunches: Int { fixture.pids("icloudpd").count }

        func waitFor(_ timeout: Duration = .seconds(20), _ condition: () -> Bool) async -> Bool {
            await ExportCancellationTests.wait(timeout: timeout, condition) != nil
        }

        func tearDown() async {
            model.cancelAutoResume()
            if model.canCancel {
                model.cancel()
            }
            _ = await waitFor(.seconds(10)) { !model.isExporting && !model.isEngineRunning }
            ICloudAccount.appleID = nil
            UserDefaults.standard.removeObject(forKey: ExportModel.bookmarkKey)
            fixture.tearDown()
        }
    }

    private static func fastTiming(maxAttempts: Int = 8, progressReset: Int = 50) -> AutoResumeTiming {
        AutoResumeTiming(delays: [.milliseconds(150)], maxAttempts: maxAttempts, progressReset: progressReset,
                         recheckInterval: .milliseconds(50))
    }

    private static let slowTiming = AutoResumeTiming(delays: [.seconds(3600)], recheckInterval: .seconds(3600))

    private static func throttleState() -> String {
        FileManager.default.temporaryDirectory.appending(path: "uncloud-throttle-\(UUID().uuidString)").path(percentEncoded: false)
    }

    @Test @MainActor func aThrottledExportAllResumesByItselfWithTheSameSelectionAndCompletes() async throws {
        let state = Self.throttleState()
        defer { try? FileManager.default.removeItem(atPath: state) }
        let fixture = try Fixture(icloudpd: ["--total", "300", "--rate", "0", "--throttle-after", "100",
                                             "--throttle-runs", "1", "--throttle-state", state])
        let harness = ModelHarness(fixture: fixture, timing: Self.fastTiming())
        let model = harness.model
        // The saved selection is a single item; Export All overrides it with everything.
        model.selection = .only(["asset-1"])
        model.storageWarningOverride = "“dest” may not have enough space."

        model.exportAll()
        #expect(await harness.waitFor { model.autoResume != nil || model.phase == .completed })
        let pending = try #require(model.autoResume)
        #expect(pending.attempt == 1)
        #expect(pending.reason == "Apple is limiting downloads")
        #expect(pending.selection == .everything)
        #expect(!pending.automatic)
        #expect(model.phase == .failed(ICloudFailure.serviceUnavailable.message))
        #expect(model.activity.contains { $0.message.hasPrefix("Paused because Apple is limiting downloads. Resuming at ") && $0.message.hasSuffix("(attempt 1).") })
        #expect(harness.storageQuestions == 1)

        var sawResumedRun = false
        #expect(await harness.waitFor {
            if model.isExporting, model.isAutoResumedRunInProgress { sawResumedRun = true }
            return model.phase == .completed
        })
        #expect(sawResumedRun)
        #expect(model.autoResume == nil)
        #expect(!model.isAutoResumedRunInProgress)
        // The resume ran icloudpd for the whole library again (not the bridge for the saved selection),
        // without asking about space a second time.
        #expect(harness.icloudpdLaunches == 2)
        #expect(harness.storageQuestions == 1)
        #expect(fixture.files(withExtension: "JPG").count == 300)
        #expect(!ExportManifest.hasIncompleteRun(in: fixture.destination))
        model.selection = .everything
        await harness.tearDown()
    }

    @Test @MainActor func throttlingThatNeverEndsGivesUpAfterTheLastAttempt() async throws {
        // Every run downloads 10 items, then is throttled: too little progress to start the count again.
        let fixture = try Fixture(icloudpd: ["--total", "1000", "--rate", "0", "--throttle-after", "10", "--throttle-level", "ERROR"])
        let harness = ModelHarness(fixture: fixture, timing: Self.fastTiming(maxAttempts: 2))
        let model = harness.model

        model.startOrResume()
        #expect(await harness.waitFor { model.phase == .failed(AutoResumePolicy.gaveUpMessage) })
        #expect(model.autoResume == nil)
        #expect(harness.icloudpdLaunches == 3)
        #expect(model.activity.contains { $0.message.hasSuffix("(attempt 2).") })
        await harness.tearDown()
    }

    @Test @MainActor func resumedRunsThatMakeProgressKeepGoingPastTheCap() async throws {
        // Throttled after every 10 downloads, with the count starting again after 5: never gives up.
        let fixture = try Fixture(icloudpd: ["--total", "60", "--rate", "0", "--throttle-after", "10"])
        let harness = ModelHarness(fixture: fixture, timing: Self.fastTiming(maxAttempts: 1, progressReset: 5))
        let model = harness.model

        model.startOrResume()
        #expect(await harness.waitFor { model.phase == .completed })
        #expect(harness.icloudpdLaunches == 6)
        #expect(fixture.files(withExtension: "JPG").count == 60)
        await harness.tearDown()
    }

    @Test @MainActor func cancellingSigningOutOrChangingFolderStopsTheWait() async throws {
        let fixture = try Fixture(icloudpd: ["--total", "1000", "--rate", "0", "--throttle-after", "5"])
        let harness = ModelHarness(fixture: fixture, timing: Self.slowTiming)
        let model = harness.model

        func failAndWait() async {
            model.startOrResume()
            #expect(await harness.waitFor { model.autoResume != nil && !model.isEngineRunning })
        }

        // Don't Resume.
        await failAndWait()
        model.cancelAutoResume()
        #expect(model.autoResume == nil)

        // Cancel.
        await failAndWait()
        model.cancel()
        #expect(model.autoResume == nil)

        // Starting another export replaces it (it's throttled again, so a new one is scheduled).
        await failAndWait()
        let launches = harness.icloudpdLaunches
        model.startOrResume()
        #expect(await harness.waitFor { harness.icloudpdLaunches == launches + 1 && model.autoResume != nil && !model.isEngineRunning })
        #expect(model.autoResume?.attempt == 1)

        // Signed out by the time it's due: it doesn't run.
        ICloudAccount.appleID = nil
        harness.clock.override = Date() + 7200
        model.resumeNow()
        #expect(model.autoResume == nil)
        #expect(!model.isExporting)
        ICloudAccount.appleID = fixture.appleID

        // Choosing another folder.
        await failAndWait()
        let other = fixture.root.appending(path: "other", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        model.chooseDestination(.success(other))
        #expect(model.autoResume == nil)

        let total = harness.icloudpdLaunches
        try await Task.sleep(for: .milliseconds(300))
        #expect(harness.icloudpdLaunches == total)
        await harness.tearDown()
    }

    @Test @MainActor func wakingAfterTheResumeTimeResumes() async throws {
        let state = Self.throttleState()
        defer { try? FileManager.default.removeItem(atPath: state) }
        let fixture = try Fixture(icloudpd: ["--total", "50", "--rate", "0", "--throttle-after", "20",
                                             "--throttle-runs", "1", "--throttle-state", state])
        let harness = ModelHarness(fixture: fixture, timing: Self.slowTiming)
        let model = harness.model

        model.startOrResume()
        #expect(await harness.waitFor { model.autoResume != nil && !model.isEngineRunning })
        // Not due yet: a wake does nothing.
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: NSWorkspace.shared)
        try await Task.sleep(for: .milliseconds(300))
        #expect(harness.icloudpdLaunches == 1)
        #expect(model.autoResume != nil)

        // The Mac slept past the resume time, then wakes.
        harness.clock.override = Date() + 2 * 3600
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: NSWorkspace.shared)
        #expect(await harness.waitFor { model.phase == .completed })
        #expect(harness.icloudpdLaunches == 2)
        #expect(model.autoResume == nil)
        await harness.tearDown()
    }

    @Test @MainActor func aFailureThatIsNotRetryableIsNotResumed() async throws {
        let fixture = try Fixture(icloudpd: ["--total", "100", "--rate", "0", "--throttle-after", "5",
                                             "--throttle-level", "ERROR", "--throttle-message", "Something unexpected happened"])
        let harness = ModelHarness(fixture: fixture, timing: Self.fastTiming())
        let model = harness.model

        model.startOrResume()
        #expect(await harness.waitFor { if case .failed = model.phase { !model.isEngineRunning } else { false } })
        #expect(model.autoResume == nil)
        try await Task.sleep(for: .milliseconds(500))
        #expect(harness.icloudpdLaunches == 1)
        #expect(model.autoResume == nil)
        await harness.tearDown()
    }
}
