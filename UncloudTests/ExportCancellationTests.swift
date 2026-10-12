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
        let python: URL
        let fakeBridge: URL
        let appleID = "fake-\(UUID().uuidString.prefix(8))@example.invalid"

        init(icloudpd: [String] = [], bridge: [String] = []) throws {
            guard let python = ICloudAccount.helperURL ?? ICloudAccount.helperOverride?.executableURL else {
                throw CancellationError()
            }
            let bundle = Bundle(for: BundleToken.self)
            let fakeICloudpd = try #require(bundle.url(forResource: "fake_icloudpd", withExtension: "py"))
            let fakeBridge = try #require(bundle.url(forResource: "fake_bridge", withExtension: "py"))
            self.python = python
            self.fakeBridge = fakeBridge
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

        func engine(
            selection: LibrarySelection = .everything,
            gate: PauseGate = PauseGate(),
            destination: URL? = nil
        ) -> ICloudExportEngine {
            ICloudExportEngine(
                destination: destination ?? self.destination,
                layout: .month,
                writesSidecars: false,
                appleID: appleID,
                gate: gate,
                selection: selection
            )
        }

        /// A bridge of its own (not the shared one) running the fake with `options`.
        func bridge(_ options: [String], timing: ICloudBridge.Timing) -> ICloudBridge {
            ICloudBridge(
                appleID: appleID,
                executableURL: python,
                arguments: ["-I", "-B", fakeBridge.path(percentEncoded: false), "--launch-log", launchLog.path(percentEncoded: false)]
                    + options + ["--", "-u", appleID, "--cookie-directory", root.path(percentEncoded: false)],
                timing: timing
            )
        }

        /// The launch log's lines.
        var launchLines: [String] {
            ((try? String(contentsOf: launchLog, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
        }

        /// Files under `folder` (default: the destination) with the given extension, as relative paths.
        func files(withExtension pathExtension: String, in folder: URL? = nil) -> [String] {
            let folder = folder ?? destination
            let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil)
            var found: [String] = []
            while let url = enumerator?.nextObject() as? URL {
                if url.pathExtension == pathExtension {
                    found.append(url.lastPathComponent)
                }
            }
            return found
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

    /// Whether the process is stopped (SIGSTOP), from the kernel's process table.
    private static func isStopped(_ pid: pid_t) -> Bool {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return false }
        return Int32(info.kp_proc.p_stat) == SSTOP
    }

    /// Polls until `condition` holds; returns how long that took, or nil after `timeout`.
    @discardableResult
    private static func wait(
        timeout: Duration,
        isolation: isolated (any Actor)? = #isolation,
        _ condition: () -> Bool
    ) async -> Duration? {
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

    // MARK: - Bridge lifecycle

    @Test func slowCancelledDownloadKeepsTheBridgeServingAndTheNextExportCompletes() async throws {
        // Each file takes 2.5 s, longer than the bridge's abandon grace, so it's pinged mid-file.
        let fixture = try Fixture(bridge: ["--total", "2000", "--rate", "0", "--chunks", "1", "--chunk-delay", "2.5"])
        defer { fixture.tearDown() }
        let ids = Set((0..<10).map { "asset-\($0)" })
        let run = fixture.engine(selection: .only(ids)).start()
        let collector = Collector()
        _ = collector.read(run)
        #expect(await Self.wait(timeout: .seconds(10)) { !fixture.files(withExtension: "part").isEmpty } != nil)
        let bridge = ICloudBridge.shared(appleID: fixture.appleID)
        let bridgePID = try #require(fixture.pids("bridge").first)

        // Browsing asked for while the cancelled file is still downloading.
        async let page = bridge.page(offset: 0, limit: 10)
        let latency = try #require(await Self.cancel(run, collector))
        // The run ends once the bridge has stopped the file, after its chunk in progress.
        #expect(latency < .seconds(4))
        #expect(collector.snapshot.error is CancellationError)
        #expect(fixture.files(withExtension: "part").isEmpty)
        #expect(fixture.files(withExtension: "JPG").isEmpty)
        let pageItems = try await page
        #expect(pageItems.count == 10)

        // Past the abandon grace and a ping: still the same bridge, serving pages and stats.
        try await Task.sleep(for: .milliseconds(2500))
        #expect(Self.isRunning(bridgePID))
        #expect(fixture.pids("bridge") == [bridgePID])
        #expect(try await bridge.page(offset: 100, limit: 5).count == 5)
        var statsComplete: Bool?
        for try await message in try await bridge.stats(offset: 1900) where message.event == "stats" {
            statsComplete = message.complete
        }
        #expect(statsComplete == true)

        // The next export completes, rather than ending as cancelled.
        let next = fixture.engine(selection: .only(["asset-1500"])).start()
        let nextCollector = Collector()
        await nextCollector.read(next).value
        #expect(nextCollector.snapshot.error == nil)
        #expect(nextCollector.snapshot.exported == 1)
        #expect(fixture.pids("bridge") == [bridgePID])
    }

    @Test func aStuckBridgeIsRestartedAndItsRequestsFailAsInterrupted() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        let bridge = fixture.bridge(
            ["--total", "500", "--rate", "0", "--chunks", "1000", "--chunk-delay", "0.05", "--stuck"],
            timing: .init(abandonGrace: .milliseconds(200), pingTimeout: .milliseconds(800), pingInterval: .milliseconds(200))
        )
        defer { bridge.terminate() }
        let dest = fixture.destination.path(percentEncoded: false)
        let stuck = try await bridge.download(ICloudBridgeRequest(cmd: "download", mode: "only", ids: ["asset-1"], dest: dest))
        let reader = Task {
            for try await _ in stuck.messages {}
        }
        #expect(await Self.wait(timeout: .seconds(10)) { !fixture.files(withExtension: "part").isEmpty } != nil)
        let firstPID = try #require(fixture.pids("bridge").first)
        reader.cancel()

        // A newer download and a page wait behind the stuck one; once the bridge is stopped they fail
        // as interrupted (Resume, or the browser's retry), never as cancelled.
        let newer = try await bridge.download(ICloudBridgeRequest(cmd: "download", mode: "only", ids: ["asset-2"], dest: dest))
        async let page = bridge.page(offset: 0, limit: 5)
        var newerError: Error?
        do {
            for try await _ in newer.messages {}
        } catch {
            newerError = error
        }
        #expect((newerError as? ICloudError) == .interrupted)
        var pageError: Error?
        do {
            _ = try await page
        } catch {
            pageError = error
        }
        #expect((pageError as? ICloudError) == .interrupted)
        #expect(await Self.wait(timeout: .seconds(7)) { !Self.isRunning(firstPID) } != nil)

        // The next request starts a fresh bridge.
        #expect(try await bridge.page(offset: 0, limit: 5).count == 5)
        #expect(fixture.pids("bridge").count == 2)
    }

    @Test @MainActor func theNextExportStartsOnlyAfterTheCancelledHelperHasExited() async throws {
        // icloudpd takes 3 s to exit after SIGTERM: longer than the export screen waits before it
        // shows the export as cancelled (ExportModel.cancelTimeout).
        let fixture = try Fixture(icloudpd: ["--total", "100000", "--rate", "200", "--term-delay", "3"])
        defer { fixture.tearDown() }
        let tracker = EngineTracker()
        let first = fixture.engine().start()
        let collector = Collector()
        _ = collector.read(first)
        tracker.track(first.task)
        #expect(await Self.wait(timeout: .seconds(10)) { collector.snapshot.exported >= 20 } != nil)
        let firstPID = try #require(fixture.pids("icloudpd").first)

        first.task.cancel()
        try await Task.sleep(for: ExportModel.cancelTimeout + .milliseconds(200))
        // The export may show as cancelled by now, but the engine still waits for icloudpd: no new
        // export can start yet ("Finishing up…").
        #expect(Self.isRunning(firstPID))
        #expect(tracker.isRunning)

        // Start again as soon as the model would allow it.
        #expect(await Self.wait(timeout: .seconds(10)) { !tracker.isRunning } != nil)
        #expect(!Self.isRunning(firstPID))
        let second = fixture.engine().start()
        let secondCollector = Collector()
        _ = secondCollector.read(second)
        #expect(await Self.wait(timeout: .seconds(10)) { fixture.pids("icloudpd").count == 2 } != nil)
        // The first helper's exit is logged before the second one's launch.
        let lines = fixture.launchLines
        let exited = try #require(lines.firstIndex(of: "\(firstPID) exited"))
        let secondPID = try #require(fixture.pids("icloudpd").last)
        let launched = try #require(lines.firstIndex { $0.hasPrefix("\(secondPID) icloudpd") })
        #expect(exited < launched)

        second.task.cancel()
        #expect(await Self.wait(timeout: .seconds(10)) { secondCollector.snapshot.ended } != nil)
    }

    @Test func shutdownStopsRunningAndPausedHelpersAndBridgesAndTheRunResumes() async throws {
        let fixture = try Fixture(icloudpd: ["--total", "400", "--rate", "100"], bridge: ["--total", "100"])
        defer { fixture.tearDown() }
        let otherDestination = fixture.root.appending(path: "paused", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: otherDestination, withIntermediateDirectories: true)

        let running = fixture.engine().start()
        let runningCollector = Collector()
        _ = runningCollector.read(running)
        let pausedGate = PauseGate()
        let paused = fixture.engine(gate: pausedGate, destination: otherDestination).start()
        let pausedCollector = Collector()
        _ = pausedCollector.read(paused)
        _ = try await ICloudBridge.shared(appleID: fixture.appleID).ready()
        #expect(await Self.wait(timeout: .seconds(10)) {
            runningCollector.snapshot.exported >= 20 && pausedCollector.snapshot.exported >= 20
        } != nil)
        pausedGate.pause()
        let helperPIDs = fixture.pids("icloudpd")
        #expect(helperPIDs.count == 2)
        #expect(await Self.wait(timeout: .seconds(5)) { helperPIDs.contains(where: Self.isStopped) } != nil)

        // What quitting runs: every helper and bridge the app has running.
        let helpers = ICloudHelperProcess.runningHelpers.filter { helperPIDs.contains($0.processIdentifier ?? -1) }
        let bridges = ICloudBridge.runningBridges.filter { $0.appleID == fixture.appleID }
        #expect(helpers.count == 2)
        #expect(bridges.count == 1)
        let start = ContinuousClock.now
        await ICloudProcesses.shutDown(helpers: helpers, bridges: bridges)
        #expect(start.duration(to: .now) < .seconds(4))
        let all = helperPIDs + fixture.pids("bridge")
        #expect(!all.contains(where: Self.isRunning))
        #expect(await Self.wait(timeout: .seconds(5)) { runningCollector.snapshot.ended && pausedCollector.snapshot.ended } != nil)
        pausedGate.resume()

        // The run stays unfinished in the manifest, and resuming it after "relaunch" completes it.
        #expect(ExportManifest.hasIncompleteRun(in: fixture.destination))
        let downloaded = runningCollector.snapshot.exported
        let resumed = fixture.engine().start()
        let resumedCollector = Collector()
        await resumedCollector.read(resumed).value
        #expect(resumedCollector.snapshot.error == nil)
        #expect(resumedCollector.snapshot.processed == 400)
        #expect(resumedCollector.snapshot.exported <= 400 - downloaded)
        #expect(!ExportManifest.hasIncompleteRun(in: fixture.destination))
    }

    @Test func aFailedBridgeRunEndsOnlyAfterItsDownloadHasStopped() async throws {
        // The destination disappears at the second item: the run fails with destinationUnavailable while
        // the next item is already being written in 1 s chunks.
        let fixture = try Fixture(bridge: ["--total", "2000", "--rate", "0", "--chunk-delay", "1", "--remove-dest-at", "1"])
        defer { fixture.tearDown() }
        let ids = Set((0..<10).map { "asset-\($0)" })
        let run = fixture.engine(selection: .only(ids)).start()
        let collector = Collector()
        _ = collector.read(run)
        #expect(await Self.wait(timeout: .seconds(15)) { collector.snapshot.ended } != nil)

        // Read the moment the run reported its end: the bridge must already have stopped the download
        // (its partial file removed and its end logged), or a new export could overlap it.
        let downloadEnded = fixture.launchLines.contains { $0.contains(" download-ended ") }
        #expect(downloadEnded)
        #expect(fixture.files(withExtension: "part").isEmpty)
        if case .destinationUnavailable? = collector.snapshot.error as? ExportError {} else {
            Issue.record("expected destinationUnavailable, got \(String(describing: collector.snapshot.error))")
        }
    }

    @Test func pauseAtTheEndOfABridgeRunLeavesNothingStopped() async throws {
        let fixture = try Fixture(bridge: ["--total", "2000", "--rate", "0"])
        defer { fixture.tearDown() }
        let gate = PauseGate()
        let ids = Set((0..<30).map { "asset-\($0)" })
        let run = fixture.engine(selection: .only(ids), gate: gate).start()
        let collector = Collector()
        _ = collector.read(run)
        // Pause the moment the last item is in, racing the run's end.
        let pauser = Task.detached {
            while !collector.snapshot.ended {
                if collector.snapshot.processed >= ids.count {
                    gate.pause()
                    return
                }
                await Task.yield()
            }
        }
        #expect(await Self.wait(timeout: .seconds(10)) { collector.snapshot.ended } != nil)
        await pauser.value
        #expect(collector.snapshot.error == nil)
        let bridgePID = try #require(fixture.pids("bridge").first)
        #expect(!Self.isStopped(bridgePID))
        let bridge = ICloudBridge.shared(appleID: fixture.appleID)
        let started = ContinuousClock.now
        #expect(try await bridge.page(offset: 0, limit: 5).count == 5)
        #expect(started.duration(to: .now) < .seconds(2))
        gate.resume()
    }

    @Test func pausingABridgeExportHoldsItWhileBrowsingGoesOn() async throws {
        let fixture = try Fixture(bridge: ["--total", "2000", "--rate", "0", "--chunks", "4", "--chunk-delay", "0.02"])
        defer { fixture.tearDown() }
        let gate = PauseGate()
        let ids = Set((0..<40).map { "asset-\($0)" })
        let run = fixture.engine(selection: .only(ids), gate: gate).start()
        let collector = Collector()
        _ = collector.read(run)
        #expect(await Self.wait(timeout: .seconds(10)) { collector.snapshot.exported >= 5 } != nil)

        gate.pause()
        try await Task.sleep(for: .milliseconds(300))
        let held = collector.snapshot.processed
        try await Task.sleep(for: .milliseconds(500))
        #expect(collector.snapshot.processed == held)
        #expect(held < ids.count)

        // The bridge isn't stopped: browsing is answered while the export holds.
        let bridge = ICloudBridge.shared(appleID: fixture.appleID)
        let bridgePID = try #require(fixture.pids("bridge").first)
        #expect(!Self.isStopped(bridgePID))
        let started = ContinuousClock.now
        #expect(try await bridge.page(offset: 200, limit: 50).count == 50)
        #expect(try await bridge.count() == 2000)
        #expect(started.duration(to: .now) < .seconds(1))
        #expect(collector.snapshot.processed == held)

        gate.resume()
        #expect(await Self.wait(timeout: .seconds(20)) { collector.snapshot.ended } != nil)
        let counts = collector.snapshot
        #expect(counts.error == nil)
        #expect(counts.processed == ids.count)
        #expect(counts.exported == ids.count)
        #expect(fixture.files(withExtension: "JPG").count == ids.count)
        #expect(fixture.files(withExtension: "part").isEmpty)
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
