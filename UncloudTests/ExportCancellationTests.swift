import Foundation
import os
import Testing
@testable import Uncloud

/// Cancelling exports against fake helpers (UncloudTests/Fakes): how fast the run ends, that no
/// helper process is left, and that the shared bridge survives. No Apple account, no network.
@Suite(.serialized, .timeLimit(.minutes(1)))
struct ExportCancellationTests {
    private final class BundleToken {}

    /// Counts a run's events off the main actor, the way the export screen's batcher reads them.
    private final class Collector: Sendable {
        struct Counts {
            var prepared = false
            var processed = 0
            var exported = 0
            var ended = false
            var error: Error?
        }

        let counts = OSAllocatedUnfairLock(uncheckedState: Counts())

        func read(_ run: ExportRun) -> Task<Void, Never> {
            Task.detached { [counts] in
                do {
                    for try await event in run.events {
                        counts.withLockUnchecked { counts in
                            switch event {
                            case .prepared: counts.prepared = true
                            case .exported: counts.processed += 1; counts.exported += 1
                            case .skipped, .failed: counts.processed += 1
                            default: break
                            }
                        }
                    }
                } catch {
                    counts.withLockUnchecked { $0.error = error }
                }
                counts.withLockUnchecked { $0.ended = true }
            }
        }

        var snapshot: Counts { counts.withLockUnchecked { $0 } }
    }

    /// A fresh destination, a launch log, and the fakes in place of icloudpd and the bridge.
    private struct Fixture {
        let root: URL
        let destination: URL
        let launchLog: URL
        let appleID = "fake-\(UUID().uuidString.prefix(8))@example.invalid"

        init(icloudpd: [String] = [], bridge: [String] = []) throws {
            guard let python = ICloudAccount.helperURL ?? ICloudAccount.helperOverride?.executableURL else {
                throw CancellationError()
            }
            let bundle = Bundle(for: BundleToken.self)
            let fakeICloudpd = try #require(bundle.url(forResource: "fake_icloudpd", withExtension: "py"))
            let fakeBridge = try #require(bundle.url(forResource: "fake_bridge", withExtension: "py"))
            root = FileManager.default.temporaryDirectory
                .appending(path: "uncloud-cancel-\(UUID().uuidString)", directoryHint: .isDirectory)
            destination = root.appending(path: "dest", directoryHint: .isDirectory)
            launchLog = root.appending(path: "launches.log")
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            let log = launchLog.path(percentEncoded: false)
            ICloudAccount.helperOverride = .init(
                executableURL: python,
                icloudpdArguments: ["-I", "-B", fakeICloudpd.path(percentEncoded: false), "--launch-log", log] + icloudpd + ["--"],
                bridgeArguments: ["-I", "-B", fakeBridge.path(percentEncoded: false), "--launch-log", log] + bridge + ["--"]
            )
        }

        func engine(selection: LibrarySelection = .everything, gate: PauseGate = PauseGate()) -> ICloudExportEngine {
            ICloudExportEngine(
                destination: destination,
                layout: .month,
                writesSidecars: false,
                appleID: appleID,
                gate: gate,
                selection: selection
            )
        }

        /// Process IDs from the launch log, by role ("icloudpd", "child", "bridge").
        func pids(_ role: String) -> [pid_t] {
            let text = (try? String(contentsOf: launchLog, encoding: .utf8)) ?? ""
            return text.split(separator: "\n").compactMap { line in
                let parts = line.split(separator: " ")
                guard parts.count >= 2, parts[1] == role else { return nil }
                return pid_t(parts[0])
            }
        }

        func tearDown() {
            ICloudBridge.shared(appleID: appleID).terminate()
            ICloudAccount.helperOverride = nil
            try? FileManager.default.removeItem(at: root)
        }
    }

    private static func isRunning(_ pid: pid_t) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }

    /// Polls until `condition` holds; returns how long that took, or nil after `timeout`.
    @discardableResult
    private static func wait(timeout: Duration, _ condition: () -> Bool) async -> Duration? {
        let start = ContinuousClock.now
        while start.duration(to: .now) < timeout {
            if condition() { return start.duration(to: .now) }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return condition() ? start.duration(to: .now) : nil
    }

    /// Cancels the run and returns how long until its events finished.
    private static func cancel(_ run: ExportRun, _ collector: Collector) async -> Duration? {
        run.task.cancel()
        return await wait(timeout: .seconds(10)) { collector.snapshot.ended }
    }

    // MARK: - icloudpd

    @Test func cancelWhileRunningEndsQuicklyAndStopsTheHelperAndItsChild() async throws {
        let fixture = try Fixture(icloudpd: ["--total", "100000", "--rate", "200", "--child"])
        defer { fixture.tearDown() }
        let run = fixture.engine().start()
        let collector = Collector()
        _ = collector.read(run)
        #expect(await Self.wait(timeout: .seconds(10)) { collector.snapshot.exported >= 50 } != nil)

        let latency = try #require(await Self.cancel(run, collector))
        #expect(latency < .seconds(1))
        #expect(collector.snapshot.error is CancellationError)
        // The run ends only after icloudpd has exited; its child goes with the process group.
        let helpers = fixture.pids("icloudpd") + fixture.pids("child")
        #expect(helpers.count == 2)
        #expect(await Self.wait(timeout: .seconds(2)) { !helpers.contains(where: Self.isRunning) } != nil)
    }

    @Test func cancelWhilePausedEndsQuicklyAndStopsTheHelper() async throws {
        let fixture = try Fixture(icloudpd: ["--total", "100000", "--rate", "200", "--child"])
        defer { fixture.tearDown() }
        let gate = PauseGate()
        let run = fixture.engine(gate: gate).start()
        let collector = Collector()
        _ = collector.read(run)
        #expect(await Self.wait(timeout: .seconds(10)) { collector.snapshot.exported >= 20 } != nil)

        gate.pause()
        try await Task.sleep(for: .milliseconds(400))
        let whilePaused = collector.snapshot.processed
        try await Task.sleep(for: .milliseconds(400))
        // Stopped with SIGSTOP: nothing new arrives.
        #expect(collector.snapshot.processed == whilePaused)

        // As ExportModel.cancel() does: cancel, then let the paused engine wake.
        run.task.cancel()
        gate.resume()
        let latency = try #require(await Self.wait(timeout: .seconds(10)) { collector.snapshot.ended })
        #expect(latency < .seconds(1))
        let helpers = fixture.pids("icloudpd") + fixture.pids("child")
        #expect(await Self.wait(timeout: .seconds(2)) { !helpers.contains(where: Self.isRunning) } != nil)
    }

    @Test func cancelBeforeTheTotalArrivesEndsQuickly() async throws {
        let fixture = try Fixture(icloudpd: ["--total", "1000", "--rate", "200", "--prepare-delay", "30"])
        defer { fixture.tearDown() }
        let run = fixture.engine().start()
        let collector = Collector()
        _ = collector.read(run)
        #expect(await Self.wait(timeout: .seconds(10)) { !fixture.pids("icloudpd").isEmpty } != nil)

        let latency = try #require(await Self.cancel(run, collector))
        #expect(latency < .seconds(1))
        #expect(!collector.snapshot.prepared)
        #expect(!fixture.pids("icloudpd").contains(where: Self.isRunning))
    }

    @Test func resumeAfterCancelSkipsWhatWasDownloaded() async throws {
        let fixture = try Fixture(icloudpd: ["--total", "300", "--rate", "400"])
        defer { fixture.tearDown() }
        let first = fixture.engine().start()
        let firstCollector = Collector()
        _ = firstCollector.read(first)
        #expect(await Self.wait(timeout: .seconds(10)) { firstCollector.snapshot.exported >= 50 } != nil)
        _ = await Self.cancel(first, firstCollector)
        let downloaded = firstCollector.snapshot.exported

        let second = fixture.engine().start()
        let secondCollector = Collector()
        await secondCollector.read(second).value
        let counts = secondCollector.snapshot
        #expect(counts.error == nil)
        #expect(counts.processed == 300)
        // Everything from the first run is skipped; a file finished after its line was read counts too.
        #expect(counts.exported <= 300 - downloaded)
        #expect(counts.exported >= 300 - downloaded - 2)
    }

    // MARK: - Bridge

    @Test func cancelInBridgeModeKeepsTheSharedBridge() async throws {
        let fixture = try Fixture(bridge: ["--total", "2000", "--rate", "50"])
        defer { fixture.tearDown() }
        let ids = Set((0..<400).map { "asset-\($0)" })
        let run = fixture.engine(selection: .only(ids)).start()
        let collector = Collector()
        _ = collector.read(run)
        #expect(await Self.wait(timeout: .seconds(10)) { collector.snapshot.exported >= 10 } != nil)

        let latency = try #require(await Self.cancel(run, collector))
        #expect(latency < .seconds(1))
        // Browsing goes on with the same bridge: no restart, no second sign-in.
        let bridge = ICloudBridge.shared(appleID: fixture.appleID)
        let page = try await bridge.page(offset: 0, limit: 10)
        #expect(page.count == 10)
        #expect(fixture.pids("bridge").count == 1)
    }

    @Test func cancelWhileTheBridgeSignsInEndsQuicklyAndKeepsSigningIn() async throws {
        let fixture = try Fixture(bridge: ["--total", "2000", "--rate", "50", "--auth-delay", "2"])
        defer { fixture.tearDown() }
        let run = fixture.engine(selection: .only(["asset-1"])).start()
        let collector = Collector()
        _ = collector.read(run)
        #expect(await Self.wait(timeout: .seconds(10)) { !fixture.pids("bridge").isEmpty } != nil)
        try await Task.sleep(for: .milliseconds(200))

        let latency = try #require(await Self.cancel(run, collector))
        #expect(latency < .seconds(1))
        // The bridge wasn't stopped, so browsing gets it without signing in again.
        let count = try await ICloudBridge.shared(appleID: fixture.appleID).ready()
        #expect(count == 2000)
        #expect(fixture.pids("bridge").count == 1)
    }

    // MARK: - Batching

    @Test func batchesKeepCountsExactAtAHighEventRate() async throws {
        let (events, continuation) = AsyncThrowingStream.makeStream(of: ExportEvent.self)
        let total = 50_000
        let producer = Task.detached {
            continuation.yield(.prepared(total: total, alreadyExported: 0))
            for index in 0..<total {
                continuation.yield(index % 10 == 0 ? .exported(name: "IMG_\(index)", fileCount: 1) : .skipped)
                if index % 5_000 == 0 {
                    try? await Task.sleep(for: .milliseconds(20))
                }
            }
            continuation.finish()
        }
        let start = ContinuousClock.now
        var batches = 0
        var processed = 0
        var exported = 0
        var lastEntry: String?
        var ending: Result<Void, Error>?
        for await batch in ExportEventBatcher.batches(of: events, interval: .milliseconds(100)) {
            batches += 1
            processed += batch.processed
            exported += batch.exported
            #expect(batch.entries.count <= ExportBatch.maxEntries * 2)
            lastEntry = batch.recentEntries.last?.message ?? lastEntry
            ending = batch.ending
        }
        await producer.value
        let elapsed = start.duration(to: .now)
        #expect(processed == total)
        #expect(exported == total / 10)
        #expect(lastEntry == "Exported IMG_49990")
        #expect(ending.map { if case .success = $0 { true } else { false } } == true)
        // At most one batch per interval, plus the first and the last.
        #expect(Double(batches) <= elapsed / .milliseconds(100) + 2)
    }

    @Test func lastBatchCarriesTheError() async throws {
        let (events, continuation) = AsyncThrowingStream.makeStream(of: ExportEvent.self)
        continuation.yield(.skipped)
        continuation.finish(throwing: ExportError.destinationFull)
        var batches: [ExportBatch] = []
        for await batch in ExportEventBatcher.batches(of: events) {
            batches.append(batch)
        }
        #expect(batches.reduce(0) { $0 + $1.processed } == 1)
        guard case .failure(let error)? = batches.last?.ending else {
            Issue.record("No ending")
            return
        }
        #expect(error is ExportError)
    }

    @Test func preparedSupersedesEarlierCountsInABatch() {
        var batch = ExportBatch()
        batch.add(.skipped)
        batch.add(.prepared(total: 10, alreadyExported: 4))
        batch.add(.skipped)
        batch.add(.exported(name: "a", fileCount: 2))
        #expect(batch.prepared?.total == 10)
        #expect(batch.processed == 2)
        #expect(batch.skipped == 2)
        #expect(batch.sawSkip)
        #expect(batch.finishedSinceSkip == 1)
        #expect(batch.entries.map(\.message) == ["Skipping 4 items that were already exported.", "Exported a (2 files)"])
    }

    // MARK: - Pause gate

    /// Pausing or resuming while an observer is being cancelled used to deadlock: the gate told
    /// observers inside its lock, and the cancelled stream's termination handler took that lock.
    @Test func pauseGateSurvivesObserversCancelledDuringChanges() async {
        for _ in 0..<500 {
            let gate = PauseGate()
            let observer = Task.detached {
                for await _ in gate.changes() {}
            }
            await Task.yield()
            let toggler = Task.detached {
                gate.pause()
                gate.resume()
            }
            observer.cancel()
            await toggler.value
            await observer.value
        }
    }
}
