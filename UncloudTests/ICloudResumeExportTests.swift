import Foundation
import Testing
@testable import Uncloud

/// Whole-library iCloud exports through the bridge, end to end: an ExportModel against the fake bridge, whose
/// library (newest first, rank 0 the newest) is kept in a state file across launches so it can change between
/// sessions. Part of ExportCancellationTests, so it never runs alongside the other suites that swap the helpers.
extension ExportCancellationTests {
    private static let holdResumes = AutoResumeTiming(delays: [.seconds(3600)], recheckInterval: .seconds(3600))

    private static func temporaryPath(_ name: String) -> String {
        FileManager.default.temporaryDirectory.appending(path: "uncloud-\(name)-\(UUID().uuidString)").path(percentEncoded: false)
    }

    /// The bridge downloads the fake was asked for: start rank, mode, layout and where a closing walk stops,
    /// oldest request first.
    private struct DownloadStart: Equatable, CustomStringConvertible {
        var startRank: Int
        var mode: String
        var layout: String
        var stopAt: String? = nil
        /// How many IDs the request carried (not compared).
        var ids = 0
        var description: String { "\(mode)@\(startRank)/\(layout)" + (stopAt.map { " stopAt=\($0)" } ?? "") }

        static func == (a: Self, b: Self) -> Bool {
            (a.startRank, a.mode, a.layout, a.stopAt) == (b.startRank, b.mode, b.layout, b.stopAt)
        }
    }

    private static func downloadStarts(_ fixture: Fixture, after mark: Int = 0) -> [DownloadStart] {
        fixture.launchLines.dropFirst(mark).compactMap { line in
            guard line.contains(" download-start ") else { return nil }
            var fields: [String: String] = [:]
            for part in line.split(separator: " ") {
                let pair = part.split(separator: "=", maxSplits: 1)
                if pair.count == 2 { fields[String(pair[0])] = String(pair[1]) }
            }
            return DownloadStart(startRank: Int(fields["startRank"] ?? "") ?? -1, mode: fields["mode"] ?? "", layout: fields["layout"] ?? "",
                                 stopAt: fields["stopAt"], ids: Int(fields["ids"] ?? "") ?? -1)
        }
    }

    /// Stops the shared bridge, so the next request launches the fake again with `options` (the library in the
    /// state file changes with `--insert-at`/`--delete-at` as it starts).
    private static func relaunchBridge(_ fixture: Fixture, _ options: [String]) {
        ICloudBridge.shutDownAll()
        let icloudpd = ICloudAccount.helperOverride?.icloudpdArguments ?? []
        ICloudAccount.helperOverride = .init(
            executableURL: fixture.python,
            icloudpdArguments: icloudpd,
            bridgeArguments: ["-I", "-B", fixture.fakeBridge.path(percentEncoded: false),
                              "--launch-log", fixture.launchLog.path(percentEncoded: false)] + options + ["--"]
        )
    }

    /// The fake library's IDs, rank 0 first, from its state file.
    private static func libraryIDs(state: String) throws -> [String] {
        let data = try Data(contentsOf: URL(filePath: state))
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let order = try #require(json["order"] as? [[Any]])
        return order.compactMap { $0.first as? String }
    }

    /// Changes the fake library in its state file (rank 0 first), for changes the launch options can't make at
    /// once. New items get item numbers from `next` on.
    private static func editLibrary(state: String, _ change: (_ order: inout [(id: String, number: Int)], _ next: inout Int) -> Void) throws {
        let url = URL(filePath: state)
        let json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        var order = try #require(json["order"] as? [[Any]]).map { (id: $0[0] as! String, number: $0[1] as! Int) }
        var next = try #require(json["next"] as? Int)
        change(&order, &next)
        let data = try JSONSerialization.data(withJSONObject: ["order": order.map { [$0.id, $0.number] as [Any] }, "next": next])
        try data.write(to: url)
    }

    /// Inserts new items at `rank`.
    private static func insert(_ count: Int, at rank: Int, into order: inout [(id: String, number: Int)], next: inout Int) -> [String] {
        let added = (0..<count).map { (id: "asset-\(next + $0)", number: next + $0) }
        next += count
        order.insert(contentsOf: added, at: rank)
        return added.map(\.id)
    }

    /// Keeps the cached library size (which the bridge updates) from leaking into other tests.
    @MainActor
    private static func keepingLibraryCount<T>(_ body: () async throws -> T) async rethrows -> T {
        let key = "icloudLibraryCount"
        let old = UserDefaults.standard.object(forKey: key)
        defer { UserDefaults.standard.set(old, forKey: key) }
        return try await body()
    }

    /// Starts an export and waits until it has ended, by its session (the phase may already read completed).
    /// `fullCheck` (the default, for the walk tests below) starts it as Check Whole Library; otherwise it's a
    /// routine export, which is a quick update when a full check was recent enough.
    @MainActor
    private static func export(
        _ harness: ModelHarness, until status: Set<ExportSession.Status> = [.completed], fullCheck: Bool = true
    ) async -> ExportSession? {
        let model = harness.model
        let before = model.sessions.count { $0.kind == .export }
        if fullCheck {
            model.checkWholeLibrary()
        } else {
            model.startOrResume()
        }
        let ended = await harness.waitFor(.seconds(40)) {
            let sessions = model.sessions.filter { $0.kind == .export }
            guard sessions.count > before, let last = sessions.last, last.isFinished else { return false }
            return !model.isEngineRunning
        }
        guard ended else {
            Issue.record("No export ended: phase \(model.phase), canStart \(model.canStart), engine \(model.isEngineRunning), warning \(String(describing: model.storageWarning)), issue \(String(describing: model.destinationIssue)), ready \(model.isSourceReady), activity \(model.activity.suffix(4).map(\.message))")
            return nil
        }
        return model.sessions.last { $0.kind == .export }
    }

    // MARK: - Routine exports: new photos only

    @Test @MainActor func aRoutineExportOnlyLooksForNewPhotosAndLeavesTheResumePointAlone() async throws {
        let state = Self.temporaryPath("state")
        defer { try? FileManager.default.removeItem(atPath: state) }
        let fixture = try Fixture(bridge: ["--total", "1000", "--rate", "0", "--state", state])
        let harness = ModelHarness(fixture: fixture, timing: Self.holdResumes)
        let model = harness.model
        try await Self.keepingLibraryCount {
            let first = try #require(await Self.export(harness))
            #expect(first.continuation == .init(strategy: .fullWalk, startRank: 0, fallbackReason: nil))
            let point = try #require(ICloudResumePoint.load(in: fixture.destination))

            // Three photos taken since: only they are fetched, by ID, and nothing is walked.
            Self.relaunchBridge(fixture, ["--rate", "0", "--state", state, "--insert-at", "0", "--insert-count", "3"])
            let mark = fixture.launchLines.count
            let second = try #require(await Self.export(harness, fullCheck: false))
            Self.relaunchBridge(fixture, ["--rate", "0", "--state", state])
            #expect(Self.downloadStarts(fixture, after: mark) == [.init(startRank: 0, mode: "only", layout: "month")])
            #expect(second.continuation == .init(strategy: .quick, startRank: nil, fallbackReason: nil))
            #expect(second.counts.exported == 3)
            #expect(second.result.status == .completed)
            #expect(fixture.files(withExtension: "JPG").count == 1003)
            #expect(ExportManifest.iCloudItems(in: fixture.destination).count == 1003)
            #expect(model.processedCount == 1003 && model.totalCount == 1003)
            #expect(model.activity.contains { $0.message.hasPrefix("Looking for new photos only") })
            // The point is the full check's, unchanged, so the next full check continues from the same anchor.
            let after = try #require(ICloudResumePoint.load(in: fixture.destination))
            #expect(after.anchor == point.anchor && after.coveredThrough == point.coveredThrough)
            #expect(after.lastFullWalkAt == point.lastFullWalkAt)

            // Nothing new since: no download at all.
            let quietMark = fixture.launchLines.count
            let third = try #require(await Self.export(harness, fullCheck: false))
            #expect(Self.downloadStarts(fixture, after: quietMark).isEmpty)
            #expect(third.continuation?.strategy == .quick)
            #expect(third.counts.exported == 0)
            #expect(model.activity.contains { $0.message == "No new photos since your last export." })
        }
        await harness.tearDown()
    }

    @Test @MainActor func aRoutineExportAfterAStaleFullCheckChecksTheWholeLibraryAndSaysWhy() async throws {
        let state = Self.temporaryPath("state")
        defer { try? FileManager.default.removeItem(atPath: state) }
        let fixture = try Fixture(bridge: ["--total", "1000", "--rate", "0", "--state", state])
        let harness = ModelHarness(fixture: fixture, timing: Self.holdResumes)
        let model = harness.model
        try await Self.keepingLibraryCount {
            #expect(await Self.export(harness)?.result.status == .completed)
            // The last full check was over a month ago, so the routine export can't stand in for one.
            var point = try #require(ICloudResumePoint.load(in: fixture.destination))
            point.lastFullWalkAt = Date().addingTimeInterval(-31 * 24 * 60 * 60)
            try point.save(in: fixture.destination)

            Self.relaunchBridge(fixture, ["--rate", "0", "--state", state, "--insert-at", "0", "--insert-count", "3"])
            let mark = fixture.launchLines.count
            let second = try #require(await Self.export(harness, fullCheck: false))
            Self.relaunchBridge(fixture, ["--rate", "0", "--state", state])
            #expect(Self.downloadStarts(fixture, after: mark) == [
                .init(startRank: 0, mode: "only", layout: "month"),
                .init(startRank: 0, mode: "allExcept", layout: "month", stopAt: "asset-999"),
            ])
            #expect(second.continuation == .init(strategy: .fromRank, startRank: 1003, fallbackReason: nil))
            #expect(second.counts.exported == 3)
            #expect(model.activity.contains { $0.message == ICloudQuickUpdate.reasonDue })
            let again = try #require(ICloudResumePoint.load(in: fixture.destination))
            #expect(try #require(again.lastFullWalkAt) > point.lastFullWalkAt!)
        }
        await harness.tearDown()
    }

    // MARK: - Continuing from the anchor

    @Test @MainActor func aSecondExportContinuesFromTheAnchorAndClosesWithAWalkFromTheTop() async throws {
        let state = Self.temporaryPath("state")
        defer { try? FileManager.default.removeItem(atPath: state) }
        let fixture = try Fixture(bridge: ["--total", "1000", "--rate", "0", "--state", state])
        let harness = ModelHarness(fixture: fixture, timing: Self.holdResumes)
        let model = harness.model
        try await Self.keepingLibraryCount {
            let first = try #require(await Self.export(harness))
            #expect(first.result.status == .completed)
            #expect(first.continuation == .init(strategy: .fullWalk, startRank: 0, fallbackReason: nil))
            #expect(Self.downloadStarts(fixture) == [.init(startRank: 0, mode: "allExcept", layout: "month")])
            #expect(fixture.files(withExtension: "JPG").count == 1000)
            #expect(fixture.pids("icloudpd").isEmpty)
            let point = try #require(ICloudResumePoint.load(in: fixture.destination))
            #expect(point.coveredThrough == 1000)
            #expect(point.anchor == .init(id: "asset-999", rank: 999))
            #expect(point.lastFullWalkAt != nil)
            #expect(ExportManifest.iCloudItems(in: fixture.destination).count == 1000)
            #expect(ExportManifest.checksums(in: fixture.destination)["2001/01/IMG_000000.JPG"] != nil)

            // Nothing new. The anchor is the last item, so there's no walk past it, and the request with every
            // known ID isn't sent for it (QC defect 4); the closing walk from the top still goes through it all.
            let mark = fixture.launchLines.count
            let second = try #require(await Self.export(harness))
            #expect(Self.downloadStarts(fixture, after: mark) == [.init(startRank: 0, mode: "allExcept", layout: "month", stopAt: "asset-999")])
            #expect(second.continuation == .init(strategy: .fromRank, startRank: 1000, fallbackReason: nil))
            #expect(second.counts.exported == 0 && second.counts.skipped == 0)
            #expect(second.result.status == .completed)
            #expect(model.processedCount == 1000 && model.totalCount == 1000)
            #expect(model.activity.contains { $0.message.hasPrefix("Continuing from photo \(1000.formatted()) of \(1000.formatted())") })
            let again = try #require(ICloudResumePoint.load(in: fixture.destination))
            #expect(try #require(again.lastFullWalkAt) > point.lastFullWalkAt!)
        }
        await harness.tearDown()
    }

    @Test @MainActor func itemsPrependedBetweenSessionsDownloadFirstThenTheWalkContinuesFromTheShiftedAnchor() async throws {
        let state = Self.temporaryPath("state")
        defer { try? FileManager.default.removeItem(atPath: state) }
        let fixture = try Fixture(bridge: ["--total", "1000", "--rate", "0", "--state", state])
        let harness = ModelHarness(fixture: fixture, timing: Self.holdResumes)
        try await Self.keepingLibraryCount {
            #expect(await Self.export(harness)?.result.status == .completed)

            // Five photos taken since: they're the newest, at ranks 0-4, and every older rank moved by five.
            Self.relaunchBridge(fixture, ["--rate", "0", "--state", state, "--insert-at", "0", "--insert-count", "5"])
            let mark = fixture.launchLines.count
            let second = try #require(await Self.export(harness))
            Self.relaunchBridge(fixture, ["--rate", "0", "--state", state])
            #expect(Self.downloadStarts(fixture, after: mark) == [
                .init(startRank: 0, mode: "only", layout: "month"),
                .init(startRank: 0, mode: "allExcept", layout: "month", stopAt: "asset-999"),
            ])
            #expect(second.continuation == .init(strategy: .fromRank, startRank: 1005, fallbackReason: nil))
            #expect(second.counts.exported == 5)
            #expect(fixture.files(withExtension: "JPG").count == 1005)
            let ids = try Self.libraryIDs(state: state)
            #expect(Array(ids.prefix(5)) == (1000..<1005).map { "asset-\($0)" })
            #expect(Set(ExportManifest.iCloudItems(in: fixture.destination).keys) == Set(ids))
            let point = try #require(ICloudResumePoint.load(in: fixture.destination))
            #expect(point.anchor == .init(id: "asset-999", rank: 1004))
            #expect(point.libraryCount == 1005)
            #expect(harness.model.activity.contains { $0.message.contains("after 5 new photos") })
        }
        await harness.tearDown()
    }

    @Test @MainActor func anInsertAmongExportedItemsIsFoundAndADeletionNeedsNoFullWalk() async throws {
        let state = Self.temporaryPath("state")
        defer { try? FileManager.default.removeItem(atPath: state) }
        let fixture = try Fixture(bridge: ["--total", "1000", "--rate", "0", "--state", state])
        let harness = ModelHarness(fixture: fixture, timing: Self.holdResumes)
        try await Self.keepingLibraryCount {
            #expect(await Self.export(harness)?.result.status == .completed)

            // A back-dated item lands among the exported ones: the top scan finds it and fetches it first.
            Self.relaunchBridge(fixture, ["--rate", "0", "--state", state, "--insert-at", "300"])
            var mark = fixture.launchLines.count
            let inserted = try #require(await Self.export(harness))
            Self.relaunchBridge(fixture, ["--rate", "0", "--state", state])
            #expect(inserted.continuation?.strategy == .fromRank)
            #expect(Self.downloadStarts(fixture, after: mark).map(\.mode) == ["only", "allExcept"])
            #expect(inserted.counts.exported == 1)
            #expect(Set(ExportManifest.iCloudItems(in: fixture.destination).keys).isSuperset(of: try Self.libraryIDs(state: state)))

            // A deletion among the exported items moves the anchor up by one. The run continues from it; the
            // closing walk goes through everything above it, so nothing can hide behind the deletion.
            Self.relaunchBridge(fixture, ["--rate", "0", "--state", state, "--delete-at", "100"])
            mark = fixture.launchLines.count
            let deleted = try #require(await Self.export(harness))
            Self.relaunchBridge(fixture, ["--rate", "0", "--state", state])
            #expect(deleted.continuation == .init(strategy: .fromRank, startRank: 1000, fallbackReason: nil))
            #expect(Self.downloadStarts(fixture, after: mark) == [.init(startRank: 0, mode: "allExcept", layout: "month", stopAt: "asset-999")])
            #expect(deleted.result.status == .completed)
            let ids = try Self.libraryIDs(state: state)
            #expect(ids.count == 1000)
            #expect(Set(ExportManifest.iCloudItems(in: fixture.destination).keys).isSuperset(of: ids))
            #expect(ICloudResumePoint.load(in: fixture.destination)?.coveredThrough == 1000)
        }
        await harness.tearDown()
    }

    /// QC P1: since the last export, an exported photo was deleted and an old photo (a scan, a saved
    /// attachment) was added deep among the exported ones. The anchor hasn't moved and the top scan stops after
    /// 200 items already on the drive, so before the closing walk the new photo waited for the weekly sweep.
    @Test @MainActor func aDeletionAndABackDatedInsertDeepAmongExportedItemsAreNotSkipped() async throws {
        let state = Self.temporaryPath("state")
        defer { try? FileManager.default.removeItem(atPath: state) }
        let fixture = try Fixture(bridge: ["--total", "1000", "--rate", "0", "--state", state])
        let harness = ModelHarness(fixture: fixture, timing: Self.holdResumes)
        try await Self.keepingLibraryCount {
            #expect(await Self.export(harness)?.result.status == .completed)
            Self.relaunchBridge(fixture, ["--rate", "0", "--state", state, "--delete-at", "100", "--insert-at", "600"])
            let session = try #require(await Self.export(harness))
            Self.relaunchBridge(fixture, ["--rate", "0", "--state", state])
            #expect(session.continuation?.strategy == .fromRank)
            #expect(session.result.status == .completed)
            #expect(session.counts.exported == 1)
            #expect(ExportManifest.iCloudItems(in: fixture.destination)["asset-1000"] != nil)
            #expect(Set(ExportManifest.iCloudItems(in: fixture.destination).keys).isSuperset(of: try Self.libraryIDs(state: state)))
        }
        await harness.tearDown()
    }

    /// QC P2: photos taken since (prepended), plus a deletion and an old photo added deep down. The top scan
    /// finds as many new items as the anchor moved by, then stops: the deep one used to be skipped.
    @Test @MainActor func prependsADeletionAndADeepInsertAreAllDownloaded() async throws {
        let state = Self.temporaryPath("state")
        defer { try? FileManager.default.removeItem(atPath: state) }
        let fixture = try Fixture(bridge: ["--total", "1000", "--rate", "0", "--state", state])
        let harness = ModelHarness(fixture: fixture, timing: Self.holdResumes)
        try await Self.keepingLibraryCount {
            #expect(await Self.export(harness)?.result.status == .completed)
            var added: [String] = []
            try Self.editLibrary(state: state) { order, next in
                order.remove(at: 300)
                added += Self.insert(1, at: 700, into: &order, next: &next)
                added += Self.insert(3, at: 0, into: &order, next: &next)
            }
            // A bridge started meanwhile (for browsing) still has the old library: start it again.
            Self.relaunchBridge(fixture, ["--rate", "0", "--state", state])
            #expect(ICloudResumePoint.load(in: fixture.destination) != nil, "point before the second export")
            let mark = fixture.launchLines.count
            let session = try #require(await Self.export(harness))
            #expect(session.continuation?.strategy == .fromRank, "\(String(describing: session.continuation)) \(harness.model.driveCheckState) \((try? FileManager.default.contentsOfDirectory(atPath: fixture.destination.appending(path: ".photo-export").path(percentEncoded: false))) ?? [])")
            #expect(session.result.status == .completed)
            #expect(session.counts.exported == 4)
            // The prepended ones first, by ID; the deep one in the closing walk.
            #expect(Self.downloadStarts(fixture, after: mark).map(\.mode) == ["only", "allExcept"])
            let items = ExportManifest.iCloudItems(in: fixture.destination)
            #expect(added.allSatisfy { items[$0] != nil })
            #expect(Set(items.keys).isSuperset(of: try Self.libraryIDs(state: state)))
        }
        await harness.tearDown()
    }

    /// QC5: an item forgotten after the point was saved, by something that didn't invalidate the point (an
    /// older version, or a manifest edited by hand), isn't `known` any more. It's above the anchor and deeper
    /// than the top scan, and the export's own check doesn't list it: the closing walk downloads it again.
    @Test @MainActor func anItemForgottenWithoutInvalidatingThePointIsDownloadedAgain() async throws {
        let state = Self.temporaryPath("state")
        defer { try? FileManager.default.removeItem(atPath: state) }
        let fixture = try Fixture(bridge: ["--total", "1000", "--rate", "0", "--state", state])
        let harness = ModelHarness(fixture: fixture, timing: Self.holdResumes)
        try await Self.keepingLibraryCount {
            #expect(await Self.export(harness)?.result.status == .completed)
            let point = try #require(ICloudResumePoint.load(in: fixture.destination))
            let file = fixture.destination.appending(path: "2001/06/IMG_000500.JPG")
            try FileManager.default.removeItem(at: file)
            try ExportManifest.forget(["icloud-id:asset-500"], in: fixture.destination)
            try point.save(in: fixture.destination)
            let session = try #require(await Self.export(harness))
            #expect(session.continuation?.strategy == .fromRank)
            #expect(session.counts.exported == 1)
            #expect(FileManager.default.fileExists(atPath: file.path(percentEncoded: false)))
            #expect(ExportManifest.iCloudItems(in: fixture.destination)["asset-500"] != nil)
        }
        await harness.tearDown()
    }

    @Test @MainActor func aThrottledExportResumesAutomaticallyFromTheNewResumePointEvenAfterADeletionBelowIt() async throws {
        let state = Self.temporaryPath("state")
        defer { try? FileManager.default.removeItem(atPath: state) }
        let fixture = try Fixture(bridge: ["--total", "1000", "--rate", "0", "--state", state, "--throttle-after", "600"])
        let harness = ModelHarness(fixture: fixture, timing: Self.holdResumes)
        let model = harness.model
        try await Self.keepingLibraryCount {
            model.startOrResume()
            #expect(await harness.waitFor(.seconds(40)) { model.autoResume != nil && !model.isEngineRunning })
            let point = try #require(ICloudResumePoint.load(in: fixture.destination))
            #expect(point.coveredThrough == 600)
            #expect(point.anchor == .init(id: "asset-599", rank: 599))
            #expect(point.lastFullWalkAt == nil)
            let first = try #require(model.sessions.last)
            #expect(first.result.retryable == true)

            // Apple lets up; meanwhile an item that wasn't exported yet was deleted, which moves the ranks past
            // the resume point but not the anchor.
            Self.relaunchBridge(fixture, ["--rate", "0", "--state", state, "--delete-at", "800"])
            let mark = fixture.launchLines.count
            model.resumeNow()
            #expect(await harness.waitFor(.seconds(40)) {
                model.phase == .completed && !model.isEngineRunning && model.sessions.last?.isFinished == true
            })
            Self.relaunchBridge(fixture, ["--rate", "0", "--state", state])
            #expect(Self.downloadStarts(fixture, after: mark) == [
                .init(startRank: 600, mode: "allExcept", layout: "month"),
                .init(startRank: 0, mode: "allExcept", layout: "month", stopAt: "asset-599"),
            ])
            let second = try #require(model.sessions.last)
            #expect(second.trigger == .autoResume)
            #expect(second.chainID == first.chainID)
            #expect(second.continuation == .init(strategy: .fromRank, startRank: 600, fallbackReason: nil))
            #expect(second.counts.exported == 399)
            let ids = try Self.libraryIDs(state: state)
            #expect(Set(ExportManifest.iCloudItems(in: fixture.destination).keys) == Set(ids))
            // Progress started from the 600 already on the drive and ended at the library's size.
            #expect(model.processedCount == 999 && model.totalCount == 999)
            let done = try #require(ICloudResumePoint.load(in: fixture.destination))
            #expect(done.coveredThrough == 999)
            // The second attempt went through every rank: its walk and the closing walk from the top.
            #expect(done.lastFullWalkAt != nil)
        }
        await harness.tearDown()
    }

    @Test @MainActor func aHalfDoneLivePhotoStopsTheResumePointThereAndTheNextExportRetriesIt() async throws {
        let state = Self.temporaryPath("state")
        defer { try? FileManager.default.removeItem(atPath: state) }
        let fixture = try Fixture(bridge: ["--total", "1000", "--rate", "0", "--state", state, "--live-every", "100", "--movie-fails-at", "700"])
        let harness = ModelHarness(fixture: fixture, timing: Self.holdResumes)
        try await Self.keepingLibraryCount {
            let first = try #require(await Self.export(harness))
            #expect(first.result.status == .completedWithFailures)
            #expect(first.counts.failed == 1)
            // Items past the failed one were downloaded, but R never passes it.
            #expect(fixture.files(withExtension: "JPG").count == 1000)
            let point = try #require(ICloudResumePoint.load(in: fixture.destination))
            #expect(point.coveredThrough == 700)
            #expect(point.anchor.id == "asset-699")
            #expect(ExportManifest.records(in: fixture.destination)["icloud-partial:asset-700"] != nil)

            Self.relaunchBridge(fixture, ["--rate", "0", "--state", state, "--live-every", "100"])
            let mark = fixture.launchLines.count
            let second = try #require(await Self.export(harness))
            #expect(Self.downloadStarts(fixture, after: mark) == [
                .init(startRank: 700, mode: "allExcept", layout: "month"),
                .init(startRank: 0, mode: "allExcept", layout: "month", stopAt: "asset-699"),
            ])
            #expect(second.result.status == .completed)
            #expect(second.counts.exported == 1)
            #expect(ExportManifest.iCloudItems(in: fixture.destination)["asset-700"] == ["2001/08/IMG_000700.JPG", "2001/08/IMG_000700.MOV"])
            #expect(ICloudResumePoint.load(in: fixture.destination)?.coveredThrough == 1000)
        }
        await harness.tearDown()
    }

    /// QC P3: an item that fails every time at rank 700 (≥ 500) keeps R at 700 forever. That used to keep the
    /// walk "under way", so the weekly sweep never ran and the part above the anchor was never gone through
    /// again. Now each run retries the item, downloads everything else, and goes through the top in its closing
    /// walk, so a photo hidden behind a deletion up there is still downloaded.
    @Test @MainActor func aPermanentlyFailingItemNeitherBlocksTheRestNorHidesChangesAboveIt() async throws {
        let state = Self.temporaryPath("state")
        defer { try? FileManager.default.removeItem(atPath: state) }
        let failing = ["--rate", "0", "--state", state, "--live-every", "100", "--movie-fails-at", "700"]
        let fixture = try Fixture(bridge: ["--total", "1000"] + failing)
        let harness = ModelHarness(fixture: fixture, timing: Self.holdResumes)
        try await Self.keepingLibraryCount {
            #expect(await Self.export(harness)?.result.status == .completedWithFailures)
            #expect(ICloudResumePoint.load(in: fixture.destination)?.coveredThrough == 700)

            // A month later: a deletion and a back-dated insert above the failed item, and new items below it.
            var added: [String] = []
            try Self.editLibrary(state: state) { order, next in
                order.remove(at: 50)
                added += Self.insert(1, at: 400, into: &order, next: &next)
                added += Self.insert(2, at: order.count, into: &order, next: &next)
            }
            var stale = try #require(ICloudResumePoint.load(in: fixture.destination))
            stale.lastFullWalkAt = Date().addingTimeInterval(-30 * 24 * 3600)
            try stale.save(in: fixture.destination)
            Self.relaunchBridge(fixture, failing)
            let mark = fixture.launchLines.count
            let session = try #require(await Self.export(harness))
            #expect(session.result.status == .completedWithFailures)
            #expect(session.counts.failed == 1)
            #expect(session.counts.exported == 3)
            #expect(Self.downloadStarts(fixture, after: mark) == [
                .init(startRank: 700, mode: "allExcept", layout: "month"),
                .init(startRank: 0, mode: "allExcept", layout: "month", stopAt: "asset-699"),
            ])
            let items = ExportManifest.iCloudItems(in: fixture.destination)
            #expect(added.allSatisfy { items[$0] != nil })
            // The half-done Live Photo never counts toward R.
            let point = try #require(ICloudResumePoint.load(in: fixture.destination))
            #expect(point.anchor.id == "asset-699" && point.coveredThrough == 700)
            #expect(items["asset-700"] == nil)
        }
        await harness.tearDown()
    }

    // MARK: - All in One Folder

    @Test @MainActor func allInOneFolderSavesIcloudpdsNamesAndNeverRecordsTheUsersOwnFiles() async throws {
        let options = ["--total", "40", "--rate", "0", "--same-name-every", "2"]
        let fixture = try Fixture(icloudpd: options, bridge: options)
        let harness = ModelHarness(fixture: fixture, timing: Self.holdResumes)
        let model = harness.model
        let destination = fixture.destination
        try writeFile("my CV", to: "Resume.pdf", in: destination)
        try writeFile("not from iCloud", to: "IMG_9999.HEIC", in: destination)
        try await Self.keepingLibraryCount {
            // Asked anyway until the folder has been read; then a folder without exports needs no question.
            #expect(await harness.waitFor { model.knowsICloudItemsByLayout })
            #expect(model.layoutChangeConfirmation(to: .flat) == nil)
            model.requestLayoutChange(to: .flat)
            #expect(model.layout == .flat)
            #expect(await harness.waitFor { model.flatFolderWarning != nil })
            #expect(model.flatFolderWarning == "This folder has other files. Uncloud leaves them alone, but a folder of its own is tidier. A file with the same name and size as a photo counts as backed up.")

            let first = try #require(await Self.export(harness))
            #expect(first.result.status == .completed)
            #expect(first.layout == .flat)
            #expect(Self.downloadStarts(fixture) == [.init(startRank: 0, mode: "allExcept", layout: "none")])
            let names = Set((try FileManager.default.contentsOfDirectory(atPath: destination.path(percentEncoded: false)))
                .filter { !$0.hasPrefix(".") })
            #expect(names.count == 42)
            // Two items named IMG_000000.JPG: the second gets its size added, as icloudpd does.
            #expect(names.contains("IMG_000000.JPG") && names.contains("IMG_000000-1001.JPG"))
            #expect(!names.contains { $0.contains("/") })
            let items = ExportManifest.iCloudItems(in: destination)
            #expect(items.count == 40)
            #expect(items["asset-1"] == ["IMG_000000-1001.JPG"])
            let records = ExportManifest.records(in: destination)
            let recordedPaths = Set(records.values.flatMap { $0 })
            #expect(!recordedPaths.contains("Resume.pdf") && !recordedPaths.contains("IMG_9999.HEIC"))
            #expect(!records.keys.contains { $0.contains("Resume") || $0.contains("IMG_9999") })
            let checksums = ExportManifest.checksums(in: destination)
            #expect(checksums["Resume.pdf"] == nil && checksums["IMG_9999.HEIC"] == nil)
            #expect(checksums["IMG_000000-1001.JPG"] != nil)

            // A plain icloudpd run into the same folder finds everything already there.
            UserDefaults.standard.set(false, forKey: ICloudExportEngine.fullExportsUseBridgeKey)
            let second = try #require(await Self.export(harness))
            #expect(second.result.status == .completed)
            #expect(second.counts.exported == 0)
            #expect(second.continuation?.strategy == .fullWalk)
            let launch = try #require(fixture.launchLines.first { $0.contains(" icloudpd ") })
            #expect(launch.contains("--folder-structure none"))
            let after = Set((try FileManager.default.contentsOfDirectory(atPath: destination.path(percentEncoded: false)))
                .filter { !$0.hasPrefix(".") })
            #expect(after == names)
            #expect(model.processedCount == 40)
            // Still nothing of the user's recorded.
            #expect(!Set(ExportManifest.records(in: destination).values.flatMap { $0 }).contains("Resume.pdf"))
        }
        await harness.tearDown()
    }

    // MARK: - Switching layouts (D5)

    @Test @MainActor func switchingLayoutOnAFolderWithICloudExportsAsksFirst() async throws {
        let fixture = try Fixture(bridge: ["--total", "30", "--rate", "0"])
        let harness = ModelHarness(fixture: fixture, timing: Self.holdResumes)
        let model = harness.model
        let other = fixture.root.appending(path: "other", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try await Self.keepingLibraryCount {
            #expect(await Self.export(harness)?.result.status == .completed)
            #expect(await harness.waitFor { model.iCloudItemsByLayout[.month] == 30 })
            #expect(model.layoutSwitchNotice == nil)

            model.requestLayoutChange(to: .flat)
            let question = try #require(model.pendingLayoutChange)
            #expect(model.layout == .month)
            #expect(question.from == .month && question.to == .flat && question.itemsSaved == 30)
            #expect(question.title == "Export Everything Again?")
            #expect(question.message.contains("already has 30 photos organized by month"))
            #expect(question.message.contains("Switching to All in One Folder exports your whole library again"))

            model.resolveLayoutChange(.cancel)
            #expect(model.pendingLayoutChange == nil && model.layout == .month)

            model.requestLayoutChange(to: .flat)
            model.resolveLayoutChange(.downloadAgainHere)
            #expect(model.layout == .flat)
            #expect(await harness.waitFor { model.layoutSwitchNotice != nil })
            #expect(model.layoutSwitchNotice?.contains("exports everything again") == true)
            // Nothing in one folder yet, so it counts as nothing on the drive.
            #expect(await harness.waitFor { model.processedCount == 0 })

            // Back to by month: those items are still there, so no question.
            model.requestLayoutChange(to: .month)
            #expect(model.pendingLayoutChange == nil && model.layout == .month)

            // Choose New Folder…: the layout changes with the new folder, not before.
            model.requestLayoutChange(to: .flat)
            model.resolveLayoutChange(.chooseNewFolder)
            #expect(model.isChoosingDestination)
            #expect(model.layout == .month)
            model.chooseDestination(.success(other))
            #expect(model.destination?.url.standardizedFileURL == other.standardizedFileURL)
            // Applied once the new folder has been read and found to hold no other layout's items.
            #expect(await harness.waitFor { model.layout == .flat })
            #expect(model.pendingLayoutChange == nil)
            #expect(model.layoutChangeConfirmation(to: .month) == nil)
        }
        await harness.tearDown()
    }

    @Test @MainActor func changingTheLayoutCancelsAPendingAutomaticResume() async throws {
        let fixture = try Fixture(bridge: ["--total", "100", "--rate", "0", "--throttle-after", "5"])
        let harness = ModelHarness(fixture: fixture, timing: Self.holdResumes)
        let model = harness.model
        await Self.keepingLibraryCount {
            model.startOrResume()
            #expect(await harness.waitFor { model.autoResume != nil && !model.isEngineRunning })
            #expect(await harness.waitFor { model.iCloudItemsByLayout[.month] == 5 })
            model.requestLayoutChange(to: .album)
            #expect(model.pendingLayoutChange != nil)
            #expect(model.autoResume != nil)
            model.resolveLayoutChange(.downloadAgainHere)
            #expect(model.layout == .album)
            #expect(model.autoResume == nil)
            #expect(model.activity.contains { $0.message == "Automatic resume cancelled because the folder layout changed." })
            model.requestLayoutChange(to: .month)
            model.resolveLayoutChange(.downloadAgainHere)
        }
        await harness.tearDown()
    }

    // MARK: - The switch

    @Test @MainActor func withTheSwitchOffWholeLibraryExportsRunIcloudpd() async throws {
        let fixture = try Fixture(icloudpd: ["--total", "50", "--rate", "0"], bridge: ["--total", "50", "--rate", "0"],
                                  bridgeForEverything: false)
        let harness = ModelHarness(fixture: fixture, timing: Self.holdResumes)
        let session = try #require(await Self.export(harness))
        #expect(session.result.status == .completed)
        #expect(session.continuation == .init(strategy: .fullWalk, startRank: nil, fallbackReason: nil))
        #expect(fixture.pids("icloudpd").count == 1)
        #expect(Self.downloadStarts(fixture).isEmpty)
        #expect(fixture.files(withExtension: "JPG").count == 50)
        #expect(ICloudResumePoint.load(in: fixture.destination) == nil)
        await harness.tearDown()
    }
}
