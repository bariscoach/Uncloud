import Foundation
import Testing
@testable import Uncloud

/// The bridge's delete events, decoded, and the Clean Up model's state machine over the fake bridge.
/// No network and no account: the fake bridge stands in for photo_bridge.py.
@Suite struct ICloudBridgeDeleteEventTests {
    private func event(_ line: String) throws -> ICloudBridgeDeleteEvent? {
        let message = try JSONDecoder().decode(ICloudBridgeMessage.self, from: Data(line.utf8))
        return ICloudBridgeDeleteEvent(message)
    }

    @Test func decodesEachDeleteEvent() throws {
        #expect(try event(#"{"id":5,"event":"deleteProgress","phase":"finding","done":3,"total":10}"#) == .finding(done: 3, total: 10))
        #expect(try event(#"{"id":5,"event":"deleteProgress","phase":"deleting","done":4,"total":10}"#) == .progress(done: 4, total: 10))
        #expect(try event(#"{"id":5,"event":"deleteTargets","ids":["a","b"]}"#) == .targets(["a", "b"]))
        #expect(try event(#"{"id":5,"event":"deleted","ids":["a"]}"#) == .deleted(["a"]))
        #expect(try event(#"{"id":5,"event":"deleteFailed","failures":[{"id":"b","reason":"No."}]}"#)
            == .failed([ICloudBridgeDeleteFailure(id: "b", reason: "No.")]))
        #expect(try event(#"{"id":5,"event":"deleteDone","deleted":2,"failed":1,"missing":0,"cancelled":false,"stopped":"throttled","message":"Apple iCloud is temporary refusing to serve icloudpd"}"#)
            == .done(deleted: 2, failed: 1, missing: 0, cancelled: false, stopped: .throttled,
                     message: "Apple iCloud is temporary refusing to serve icloudpd"))
        #expect(try event(#"{"id":5,"event":"deleteDone","deleted":0,"failed":0,"missing":0,"cancelled":false,"stopped":"changed","message":"m"}"#)
            == .done(deleted: 0, failed: 0, missing: 0, cancelled: false, stopped: .changed, message: "m"))
        #expect(try event(#"{"id":5,"event":"deleteDone","deleted":0,"failed":0,"missing":2,"cancelled":true,"stopped":null,"message":null}"#)
            == .done(deleted: 0, failed: 0, missing: 2, cancelled: true, stopped: nil, message: nil))
        #expect(try event(#"{"id":5,"event":"progress","done":1,"total":2}"#) == nil)
    }

    @Test func requestsCarryTheModeIDsHintsAndBatchSize() throws {
        let options = ICloudBridgeDeleteOptions(mode: .only, confirmedCount: 3, ids: ["a"], rankHints: ["a": 4], batchSize: 500)
        let request = options.request
        #expect(request.cmd == "delete")
        #expect(request.confirmedCount == 3)
        #expect(request.mode == "only")
        #expect(request.ids == ["a"])
        #expect(request.hints == ["a": 4])
        #expect(request.batchSize == ICloudBridgeDeleteOptions.maxBatchSize, "the batch size is capped at the bridge's limit")
    }

    @Test func restoreRequestsUseTheRestoreCommandAndTheSameFields() {
        let options = ICloudBridgeDeleteOptions(mode: .allExcept, confirmedCount: 4, action: .restore, ids: ["a"], batchSize: 50)
        let request = options.request
        #expect(request.cmd == "restore")
        #expect(request.mode == "allExcept")
        #expect(request.ids == ["a"])
        #expect(request.confirmedCount == 4)
        #expect(request.batchSize == 50)
        #expect(ICloudBridgeDeleteOptions(mode: .only, confirmedCount: 1).request.cmd == "delete", "delete is the default")
    }

    @Test func browseRequestsNameRecentlyDeletedOnlyWhenAsked() throws {
        func json(_ request: ICloudBridgeRequest) throws -> String {
            String(decoding: try JSONEncoder().encode(request), as: UTF8.self)
        }
        let trash = try json(ICloudBridgeRequest(cmd: "count", album: ICloudBridgeAlbum.recentlyDeleted.requestName))
        #expect(trash.contains(#""album":"recentlyDeleted""#))
        let library = try json(ICloudBridgeRequest(cmd: "count", album: ICloudBridgeAlbum.library.requestName))
        #expect(!library.contains("album"), "the library's requests stay as they were")
    }
}

@MainActor
@Suite struct ICloudCleanupTests {
    private final class BundleToken {}

    /// Stands in for photo_bridge.py with `options` ("--total", "--delete-throttle-after", …); one launch's log is kept in `root`.
    private func fakeBridge(root: URL, options: [String]) throws -> (ICloudBridge, URL) {
        let python = try #require(ICloudAccount.helperURL ?? ICloudAccount.helperOverride?.executableURL)
        let fake = try #require(Bundle(for: BundleToken.self).url(forResource: "fake_bridge", withExtension: "py"))
        let log = root.appending(path: "launch.log")
        let appleID = "fake-\(UUID().uuidString.prefix(8))@example.invalid"
        let bridge = ICloudBridge(
            appleID: appleID,
            executableURL: python,
            arguments: ["-I", "-B", fake.path(percentEncoded: false), "--rate", "0",
                        "--launch-log", log.path(percentEncoded: false)] + options
                + ["--", "-u", appleID, "--cookie-directory", root.path(percentEncoded: false)]
        )
        return (bridge, log)
    }

    /// Records what the model reports back, and what the test says the library holds and whether an export runs.
    private final class Probe {
        var exporting = false
        var count: Int?
        var recentlyDeletedCount: Int?
        var changes: [Set<String>] = []
        var recoveries: [Set<String>] = []
    }

    private func makeCleanup(
        bridge: ICloudBridge,
        probe: Probe,
        selection: LibrarySelection,
        retryDelays: [TimeInterval] = [0.05],
        batchSize: Int = 100
    ) -> ICloudCleanup {
        let cleanup = ICloudCleanup(
            appleID: "fake@example.invalid",
            bridge: bridge,
            environment: ICloudCleanup.Environment(
                isExportRunning: { probe.exporting },
                libraryCount: { probe.count },
                rankHints: { _ in [:] },
                libraryDidChange: { probe.changes.append($0) },
                recentlyDeletedCount: { probe.recentlyDeletedCount },
                recoveryDidChange: { probe.recoveries.append($0) }
            ),
            retryDelays: retryDelays,
            batchSize: batchSize
        )
        cleanup.selection = selection
        return cleanup
    }

    /// Waits until `condition` holds, failing the test after a few seconds.
    private func waitUntil(_ condition: () -> Bool, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        for _ in 0..<400 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("The condition never held", sourceLocation: sourceLocation)
    }

    private func launchLines(_ log: URL) -> [String] {
        ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }

    @Test(.timeLimit(.minutes(1))) func confirmedRunDeletesTheSelectionAndReportsIt() async throws {
        try await withTemporaryDirectoryAsync { root in
            let (bridge, _) = try fakeBridge(root: root, options: ["--total", "5"])
            defer { bridge.terminate() }
            let probe = Probe()
            probe.count = 5
            let cleanup = makeCleanup(bridge: bridge, probe: probe, selection: .only(["asset-1", "asset-3"]))

            cleanup.requestConfirmation()
            #expect(cleanup.state == .confirming)
            #expect(cleanup.pendingCount == 2)
            #expect(!cleanup.start(typed: "3"), "a wrong number starts nothing")
            #expect(cleanup.start(typed: "2"))
            await cleanup.waitUntilEnded()

            #expect(cleanup.state == .finished(.init(deleted: 2, failures: [], missing: 0, cancelled: false, stoppedMessage: nil)))
            #expect(probe.changes == [["asset-1", "asset-3"]])
            #expect(cleanup.selection == .only([]), "deleted items leave the selection")
            #expect(!cleanup.isRunning)
        }
    }

    @Test func confirmationNeedsTheTypedCount() {
        #expect(ICloudCleanup.typedNumberMatches("12", count: 12))
        #expect(ICloudCleanup.typedNumberMatches(" 12 ", count: 12))
        #expect(!ICloudCleanup.typedNumberMatches("1", count: 12))
        #expect(!ICloudCleanup.typedNumberMatches("012", count: 12))
        #expect(!ICloudCleanup.typedNumberMatches("", count: 12))
        #expect(!ICloudCleanup.typedNumberMatches("twelve", count: 12))
    }

    @Test(.timeLimit(.minutes(1))) func allExceptDeletesEverythingButTheExclusions() async throws {
        try await withTemporaryDirectoryAsync { root in
            let (bridge, _) = try fakeBridge(root: root, options: ["--total", "4"])
            defer { bridge.terminate() }
            let probe = Probe()
            probe.count = 4
            let cleanup = makeCleanup(bridge: bridge, probe: probe, selection: .allExcept(["asset-0"]))

            cleanup.requestConfirmation()
            #expect(cleanup.pendingCount == 3)
            #expect(cleanup.start(typed: "3"))
            await cleanup.waitUntilEnded()

            #expect(cleanup.state == .finished(.init(deleted: 3, failures: [], missing: 0, cancelled: false, stoppedMessage: nil)))
            #expect(cleanup.selection == .allExcept(["asset-0"]), "the exclusion of a kept item stays")
        }
    }

    @Test(.timeLimit(.minutes(1))) func partialFailuresAreListedInTheSummary() async throws {
        try await withTemporaryDirectoryAsync { root in
            let (bridge, _) = try fakeBridge(root: root, options: ["--total", "4", "--delete-fail-every", "2"])
            defer { bridge.terminate() }
            let probe = Probe()
            probe.count = 4
            let cleanup = makeCleanup(bridge: bridge, probe: probe, selection: .allExcept([]))

            cleanup.requestConfirmation()
            #expect(cleanup.start(typed: "4"))
            await cleanup.waitUntilEnded()

            guard case let .finished(summary) = cleanup.state else {
                Issue.record("Expected a finished run, got \(cleanup.state)")
                return
            }
            #expect(summary.deleted == 2)
            #expect(summary.failures.map(\.id) == ["asset-0", "asset-2"])
            #expect(summary.failures.allSatisfy { $0.reason == "The item couldn't be deleted." })
            #expect(probe.changes == [["asset-1", "asset-3"]])
        }
    }

    @Test(.timeLimit(.minutes(1))) func throttleThenRetryTriesOnlyTheRemainingItems() async throws {
        try await withTemporaryDirectoryAsync { root in
            // The first batch is throttled, so the run waits and then asks for the items it didn't delete.
            let (bridge, log) = try fakeBridge(root: root, options: ["--total", "3", "--delete-throttle-after", "0"])
            defer { bridge.terminate() }
            let probe = Probe()
            probe.count = 3
            let cleanup = makeCleanup(bridge: bridge, probe: probe, selection: .allExcept([]), retryDelays: [0.05])

            cleanup.requestConfirmation()
            #expect(cleanup.start(typed: "3"))
            await cleanup.waitUntilEnded()

            #expect(cleanup.state == .finished(.init(deleted: 3, failures: [], missing: 0, cancelled: false, stoppedMessage: nil)))
            let starts = launchLines(log).filter { $0.contains("delete-start") }
            #expect(starts.count == 2)
            #expect(starts.last?.contains("mode=only ids=3") == true)
        }
    }

    @Test(.timeLimit(.minutes(1))) func retryNowSkipsTheWait() async throws {
        try await withTemporaryDirectoryAsync { root in
            let (bridge, _) = try fakeBridge(root: root, options: ["--total", "2", "--delete-throttle-after", "0"])
            defer { bridge.terminate() }
            let probe = Probe()
            probe.count = 2
            let cleanup = makeCleanup(bridge: bridge, probe: probe, selection: .allExcept([]), retryDelays: [600])

            cleanup.requestConfirmation()
            #expect(cleanup.start(typed: "2"))
            try await waitUntil { if case .waitingAfterThrottle = cleanup.state { true } else { false } }
            cleanup.retryNow()
            await cleanup.waitUntilEnded()

            #expect(cleanup.state == .finished(.init(deleted: 2, failures: [], missing: 0, cancelled: false, stoppedMessage: nil)))
        }
    }

    @Test(.timeLimit(.minutes(1))) func cancelDuringTheWaitEndsTheRunWithoutRetrying() async throws {
        try await withTemporaryDirectoryAsync { root in
            let (bridge, log) = try fakeBridge(root: root, options: ["--total", "2", "--delete-throttle-after", "0"])
            defer { bridge.terminate() }
            let probe = Probe()
            probe.count = 2
            let cleanup = makeCleanup(bridge: bridge, probe: probe, selection: .allExcept([]), retryDelays: [600])

            cleanup.requestConfirmation()
            #expect(cleanup.start(typed: "2"))
            try await waitUntil { if case .waitingAfterThrottle = cleanup.state { true } else { false } }
            cleanup.cancel()
            await cleanup.waitUntilEnded()

            #expect(cleanup.state == .finished(.init(deleted: 0, failures: [], missing: 0, cancelled: true, stoppedMessage: nil)))
            #expect(launchLines(log).filter { $0.contains("delete-start") }.count == 1)
            #expect(probe.changes.isEmpty)
        }
    }

    @Test(.timeLimit(.minutes(1))) func cancelStopsBeforeTheNextBatch() async throws {
        try await withTemporaryDirectoryAsync { root in
            let (bridge, _) = try fakeBridge(root: root, options: ["--total", "6", "--delete-batch-delay", "0.3"])
            defer { bridge.terminate() }
            let probe = Probe()
            probe.count = 6
            let cleanup = makeCleanup(bridge: bridge, probe: probe, selection: .allExcept([]), batchSize: 2)

            cleanup.requestConfirmation()
            #expect(cleanup.start(typed: "6"))
            try await waitUntil { if case let .deleting(done, _, _) = cleanup.state { done >= 2 } else { false } }
            cleanup.cancel()
            #expect(cleanup.isStopping)
            await cleanup.waitUntilEnded()

            guard case let .finished(summary) = cleanup.state else {
                Issue.record("Expected a finished run, got \(cleanup.state)")
                return
            }
            #expect(summary.cancelled)
            #expect(summary.deleted >= 2 && summary.deleted < 6, "the batch in progress finishes, the rest doesn't start")
            #expect(probe.changes.count == 1)
        }
    }

    @Test(.timeLimit(.minutes(1))) func pauseHoldsBetweenBatchesAndResumeFinishes() async throws {
        try await withTemporaryDirectoryAsync { root in
            let (bridge, _) = try fakeBridge(root: root, options: ["--total", "6", "--delete-batch-delay", "0.2"])
            defer { bridge.terminate() }
            let probe = Probe()
            probe.count = 6
            let cleanup = makeCleanup(bridge: bridge, probe: probe, selection: .allExcept([]), batchSize: 2)

            cleanup.requestConfirmation()
            #expect(cleanup.start(typed: "6"))
            try await waitUntil { if case let .deleting(done, _, _) = cleanup.state { done >= 2 } else { false } }
            cleanup.setPaused(true)
            try await waitUntil { if case .deleting(_, _, true) = cleanup.state { true } else { false } }
            let held = cleanup.state
            try await Task.sleep(for: .milliseconds(600))
            #expect(cleanup.state == held, "no progress while paused")
            cleanup.setPaused(false)
            await cleanup.waitUntilEnded()

            #expect(cleanup.state == .finished(.init(deleted: 6, failures: [], missing: 0, cancelled: false, stoppedMessage: nil)))
        }
    }

    @Test(.timeLimit(.minutes(1))) func exportsAndAnotherRunBlockTheStart() async throws {
        try await withTemporaryDirectoryAsync { root in
            let (bridge, _) = try fakeBridge(root: root, options: ["--total", "2"])
            defer { bridge.terminate() }
            let probe = Probe()
            probe.count = 2
            probe.exporting = true
            let cleanup = makeCleanup(bridge: bridge, probe: probe, selection: .allExcept([]))

            #expect(!cleanup.canRequestConfirmation, "nothing is deleted while an export runs")
            cleanup.requestConfirmation()
            #expect(cleanup.state == .idle)

            probe.exporting = false
            #expect(cleanup.canRequestConfirmation)
            cleanup.requestConfirmation()
            #expect(cleanup.start(typed: "2"))
            // Nothing else can start while this run is running, and an export waits for it.
            #expect(!cleanup.canRequestConfirmation)
            #expect(!cleanup.start(typed: "2"))
            await cleanup.waitUntilEnded()
        }
    }

    @Test func deletedIDsLeaveBothKindsOfSelection() {
        #expect(LibrarySelection.only(["a", "b"]).forgetting(["a"]) == .only(["b"]))
        #expect(LibrarySelection.allExcept(["a", "c"]).forgetting(["a"]) == .allExcept(["c"]))
        // Without the deleted exclusion, the count of an all-except selection would undercount the library.
        #expect(LibrarySelection.allExcept(["a"]).forgetting(["a"]).selectedCount(total: 9) == 9)
    }

    @Test(.timeLimit(.minutes(1))) func theRequestCarriesTheTypedCount() async throws {
        try await withTemporaryDirectoryAsync { root in
            let (bridge, log) = try fakeBridge(root: root, options: ["--total", "3"])
            defer { bridge.terminate() }
            let probe = Probe()
            probe.count = 3
            let cleanup = makeCleanup(bridge: bridge, probe: probe, selection: .allExcept(["asset-0"]))

            cleanup.requestConfirmation()
            #expect(cleanup.pendingCount == 2)
            #expect(cleanup.start(typed: "2"))
            await cleanup.waitUntilEnded()

            #expect(launchLines(log).contains { $0.contains("delete-start") && $0.contains("confirmed=2") })
        }
    }

    @Test(.timeLimit(.minutes(1))) func aLibraryThatGrewIsNotDeletedAndNotRetried() async throws {
        try await withTemporaryDirectoryAsync { root in
            // The library holds three items, but the displayed count, and so the confirmation, was two.
            let (bridge, log) = try fakeBridge(root: root, options: ["--total", "3"])
            defer { bridge.terminate() }
            let probe = Probe()
            probe.count = 2
            let cleanup = makeCleanup(bridge: bridge, probe: probe, selection: .allExcept([]))

            cleanup.requestConfirmation()
            #expect(cleanup.start(typed: "2"))
            await cleanup.waitUntilEnded()

            #expect(cleanup.state == .failed("Your iCloud library changed since you confirmed, so nothing was deleted. Review your selection and try again."))
            #expect(probe.changes.isEmpty)
            #expect(launchLines(log).filter { $0.contains("delete-start") }.count == 1, "no retry")
        }
    }

    @Test(.timeLimit(.minutes(1))) func threeFailedBatchesEndTheRunWithoutARetry() async throws {
        try await withTemporaryDirectoryAsync { root in
            let (bridge, log) = try fakeBridge(root: root, options: ["--total", "6", "--delete-fail-every", "1"])
            defer { bridge.terminate() }
            let probe = Probe()
            probe.count = 6
            let cleanup = makeCleanup(bridge: bridge, probe: probe, selection: .allExcept([]), batchSize: 2)

            cleanup.requestConfirmation()
            #expect(cleanup.start(typed: "6"))
            await cleanup.waitUntilEnded()

            guard case let .finished(summary) = cleanup.state else {
                Issue.record("Expected a finished run, got \(cleanup.state)")
                return
            }
            #expect(summary.deleted == 0)
            #expect(summary.failures.count == 6)
            #expect(summary.stoppedMessage == "The item couldn't be deleted.")
            #expect(launchLines(log).filter { $0.contains("delete-start") }.count == 1, "an error is never retried")
        }
    }

    @Test(.timeLimit(.minutes(1))) func aNewModelNeverStartsWithoutConfirmation() async throws {
        try await withTemporaryDirectoryAsync { root in
            let (bridge, log) = try fakeBridge(root: root, options: ["--total", "2"])
            defer { bridge.terminate() }
            let probe = Probe()
            probe.count = 2
            let cleanup = makeCleanup(bridge: bridge, probe: probe, selection: .allExcept([]))

            // Nothing runs on creation, and a start without the confirmation does nothing.
            #expect(cleanup.state == .idle)
            #expect(!cleanup.start(typed: "2"))
            #expect(cleanup.state == .idle)
            #expect(launchLines(log).isEmpty, "the bridge isn't even started")
        }
    }

    @Test func nothingSelectedCannotAskForConfirmation() {
        let probe = Probe()
        probe.count = 10
        let cleanup = ICloudCleanup(
            appleID: "x@example.invalid",
            bridge: ICloudBridge(appleID: "x@example.invalid", executableURL: nil, arguments: []),
            environment: ICloudCleanup.Environment(
                isExportRunning: { false },
                libraryCount: { probe.count },
                rankHints: { _ in [:] },
                libraryDidChange: { _ in }
            )
        )
        #expect(cleanup.selection == .only([]), "the cleanup starts with nothing selected")
        #expect(!cleanup.canRequestConfirmation)
        cleanup.selection = .allExcept([])
        #expect(cleanup.canRequestConfirmation)
        probe.count = nil
        #expect(!cleanup.canRequestConfirmation, "not until the library's count is known")
    }

    // MARK: - Recently Deleted

    @Test(.timeLimit(.minutes(1))) func recoveryRecoversTheSelectionWithoutTyping() async throws {
        try await withTemporaryDirectoryAsync { root in
            let (bridge, log) = try fakeBridge(root: root, options: ["--total", "5", "--trash-first", "3"])
            defer { bridge.terminate() }
            let probe = Probe()
            probe.count = 2
            probe.recentlyDeletedCount = 3
            let cleanup = makeCleanup(bridge: bridge, probe: probe, selection: .only([]))

            cleanup.setMode(.recentlyDeleted)
            cleanup.selection = .only(["asset-0", "asset-2"])
            cleanup.requestConfirmation()
            #expect(cleanup.state == .confirming)
            #expect(cleanup.pendingCount == 2)
            #expect(!cleanup.start(typed: "2"), "a deletion never starts from Recently Deleted")
            #expect(cleanup.recover())
            await cleanup.waitUntilEnded()

            #expect(cleanup.state == .finished(.init(
                deleted: 2, failures: [], missing: 0, cancelled: false, stoppedMessage: nil, action: .restore
            )))
            #expect(probe.recoveries == [["asset-0", "asset-2"]])
            #expect(probe.changes.isEmpty, "a recovery doesn't change the library's export selection")
            #expect(cleanup.selection == .only([]), "recovered items leave the Recently Deleted selection")
            #expect(cleanup.selections[.library] == .only([]))
            #expect(launchLines(log).contains { $0.contains("action=restore") && $0.contains("confirmed=2") })
        }
    }

    @Test(.timeLimit(.minutes(1))) func recoveryRetriesAfterAThrottleWithOnlyTheRemainingItems() async throws {
        try await withTemporaryDirectoryAsync { root in
            let (bridge, log) = try fakeBridge(root: root, options: ["--total", "5", "--trash-first", "3", "--delete-throttle-after", "0"])
            defer { bridge.terminate() }
            let probe = Probe()
            probe.recentlyDeletedCount = 3
            let cleanup = makeCleanup(bridge: bridge, probe: probe, selection: .only([]), retryDelays: [0.05])

            cleanup.setMode(.recentlyDeleted)
            cleanup.selection = .allExcept([])
            cleanup.requestConfirmation()
            #expect(cleanup.recover())
            await cleanup.waitUntilEnded()

            #expect(cleanup.state == .finished(.init(
                deleted: 3, failures: [], missing: 0, cancelled: false, stoppedMessage: nil, action: .restore
            )))
            let starts = launchLines(log).filter { $0.contains("delete-start") }
            #expect(starts.count == 2)
            #expect(starts.allSatisfy { $0.contains("action=restore") })
            #expect(starts.last?.contains("mode=only ids=3") == true)
        }
    }

    @Test(.timeLimit(.minutes(1))) func aRecentlyDeletedListThatChangedIsNotRecoveredAndNotRetried() async throws {
        try await withTemporaryDirectoryAsync { root in
            let (bridge, log) = try fakeBridge(root: root, options: ["--total", "5", "--trash-first", "3"])
            defer { bridge.terminate() }
            let probe = Probe()
            // The model counted two items, but Recently Deleted holds three now.
            probe.recentlyDeletedCount = 2
            let cleanup = makeCleanup(bridge: bridge, probe: probe, selection: .only([]))

            cleanup.setMode(.recentlyDeleted)
            cleanup.selection = .allExcept([])
            cleanup.requestConfirmation()
            #expect(cleanup.recover())
            await cleanup.waitUntilEnded()

            #expect(cleanup.state == .failed("Your iCloud library changed since you confirmed, so nothing was recovered. Review your selection and try again."))
            #expect(probe.recoveries.isEmpty)
            #expect(launchLines(log).filter { $0.contains("delete-start") }.count == 1, "no retry")
        }
    }

    @Test(.timeLimit(.minutes(1))) func aDeletionAndARecoveryCannotOverlap() async throws {
        try await withTemporaryDirectoryAsync { root in
            let (bridge, _) = try fakeBridge(root: root, options: ["--total", "6", "--delete-batch-delay", "0.3"])
            defer { bridge.terminate() }
            let probe = Probe()
            probe.count = 6
            probe.recentlyDeletedCount = 4
            let cleanup = makeCleanup(bridge: bridge, probe: probe, selection: .allExcept([]), batchSize: 1)

            cleanup.requestConfirmation()
            #expect(cleanup.start(typed: "6"))
            try await waitUntil { if case let .deleting(done, _, _) = cleanup.state { done >= 1 } else { false } }
            // While the deletion runs, Recently Deleted can't be opened for a recovery, and nothing can be confirmed.
            cleanup.setMode(.recentlyDeleted)
            #expect(cleanup.mode == .library)
            #expect(!cleanup.canRequestConfirmation)
            cleanup.requestConfirmation()
            #expect(!cleanup.recover())
            #expect(!cleanup.start(typed: "6"), "a second deletion can't start over the first")
            cleanup.cancel()
            await cleanup.waitUntilEnded()
            #expect(!cleanup.isRunning)
        }
    }

    @Test(.timeLimit(.minutes(1))) func aRecoveryBlocksADeletion() async throws {
        try await withTemporaryDirectoryAsync { root in
            let (bridge, _) = try fakeBridge(root: root, options: ["--total", "6", "--trash-first", "4", "--delete-batch-delay", "0.3"])
            defer { bridge.terminate() }
            let probe = Probe()
            probe.count = 2
            probe.recentlyDeletedCount = 4
            let cleanup = makeCleanup(bridge: bridge, probe: probe, selection: .only([]), batchSize: 1)

            cleanup.setMode(.recentlyDeleted)
            cleanup.selection = .allExcept([])
            cleanup.requestConfirmation()
            #expect(cleanup.recover())
            try await waitUntil { if case let .deleting(done, _, _) = cleanup.state { done >= 1 } else { false } }
            cleanup.setMode(.library)
            #expect(cleanup.mode == .recentlyDeleted)
            #expect(!cleanup.canRequestConfirmation)
            cleanup.cancel()
            await cleanup.waitUntilEnded()
            guard case let .finished(summary) = cleanup.state else {
                Issue.record("Expected the recovery to end, got \(cleanup.state)")
                return
            }
            #expect(summary.cancelled && summary.action == .restore)
        }
    }

    @Test func eachModeKeepsItsOwnSelection() {
        let probe = Probe()
        probe.count = 10
        probe.recentlyDeletedCount = 4
        let cleanup = ICloudCleanup(
            appleID: "x@example.invalid",
            bridge: ICloudBridge(appleID: "x@example.invalid", executableURL: nil, arguments: []),
            environment: ICloudCleanup.Environment(
                isExportRunning: { false },
                libraryCount: { probe.count },
                rankHints: { _ in [:] },
                libraryDidChange: { _ in },
                recentlyDeletedCount: { probe.recentlyDeletedCount }
            )
        )
        cleanup.selection = .allExcept(["asset-1"])
        cleanup.setMode(.recentlyDeleted)
        #expect(cleanup.selection == .only([]), "Recently Deleted starts with nothing selected")
        #expect(cleanup.selectedCount == 0)
        cleanup.selection = .allExcept([])
        #expect(cleanup.selectedCount == 4)
        cleanup.setMode(.library)
        #expect(cleanup.selection == .allExcept(["asset-1"]), "the library keeps its own selection")
        #expect(cleanup.selectedCount == 9)
    }

    @Test(.timeLimit(.minutes(1))) func recentlyDeletedIsPagedApartFromTheLibrary() async throws {
        try await withTemporaryDirectoryAsync { root in
            let (bridge, _) = try fakeBridge(root: root, options: ["--total", "5", "--trash-first", "3"])
            defer { bridge.terminate() }
            let library = ICloudBridgeFetcher(bridge: bridge)
            let trash = ICloudBridgeFetcher(bridge: bridge, album: .recentlyDeleted)
            #expect(try await library.count() == 2)
            #expect(try await trash.count() == 3)
            #expect(try await library.assets(offset: 0, limit: 10).map(\.id) == ["asset-3", "asset-4"])
            #expect(try await trash.assets(offset: 0, limit: 10).map(\.id) == ["asset-0", "asset-1", "asset-2"])
        }
    }
}
