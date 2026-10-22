import AppKit
import Foundation
import os
import Photos
import Testing
@testable import Uncloud

/// The storage estimate: selection maths on the size table, the Photos heuristic, the free-space
/// warning, and a scan through the fake bridge. No Apple account, no network, no real library.
struct StorageEstimateTests {
    private static func table(_ sizes: [String: Int64], kind: AssetSizeTable.Kind = .measured, complete: Bool = true) -> AssetSizeTable {
        var table = AssetSizeTable(kind: kind)
        table.merge(sizes)
        table.libraryCount = sizes.count
        table.isComplete = complete
        return table
    }

    // MARK: - Selection maths

    @Test func everythingIsTheTotal() {
        let table = Self.table(["a": 100, "b": 200, "c": 300])
        #expect(table.total == 600)
        let estimate = table.estimate(for: .everything, libraryCount: 3)
        #expect(estimate == StorageEstimate(bytes: 600, isExact: true, basis: .scanned))
    }

    @Test func allExceptSubtractsTheExcluded() {
        let table = Self.table(["a": 100, "b": 200, "c": 300])
        let sum = table.sum(for: .allExcept(["b"]), libraryCount: 3)
        #expect(sum == AssetSizeTable.Sum(bytes: 400, known: 2, unknown: 0))
        // An excluded ID the library no longer has changes nothing.
        #expect(table.sum(for: .allExcept(["gone"]), libraryCount: 3).bytes == 600)
    }

    @Test func onlySumsTheIncluded() {
        let table = Self.table(["a": 100, "b": 200, "c": 300])
        #expect(table.sum(for: .only(["a", "c"]), libraryCount: 3) == AssetSizeTable.Sum(bytes: 400, known: 2, unknown: 0))
        #expect(table.estimate(for: .only([]), libraryCount: 3)?.bytes == 0)
    }

    @Test func unknownItemsCountAtTheAverage() {
        // A partial scan: 2 of 5 items known, averaging 150.
        let table = Self.table(["a": 100, "b": 200], complete: false)
        let estimate = table.estimate(for: .everything, libraryCount: 5)
        #expect(estimate == StorageEstimate(bytes: 300 + 3 * 150, isExact: false, basis: .sampled(2)))
        let only = table.estimate(for: .only(["a", "x"]), libraryCount: 5)
        #expect(only == StorageEstimate(bytes: 100 + 150, isExact: false, basis: .sampled(2)))
        // Nothing known yet: no estimate rather than zero.
        #expect(AssetSizeTable(kind: .measured).estimate(for: .everything, libraryCount: 5) == nil)
        // New items since a complete scan: still the scan's basis, but no longer exact.
        let grown = Self.table(["a": 100, "b": 200]).estimate(for: .everything, libraryCount: 3)
        #expect(grown == StorageEstimate(bytes: 450, isExact: false, basis: .scanned))
    }

    @Test func heuristicTablesAreNeverExact() {
        let table = Self.table(["a": 100], kind: .heuristic)
        #expect(table.estimate(for: .everything, libraryCount: 1) == StorageEstimate(bytes: 100, isExact: false, basis: .heuristic))
    }

    @Test func replacingAndPruningKeepTheTotal() {
        var table = Self.table(["a": 100, "b": 200, "c": 300])
        table.set(50, for: "a")
        #expect(table.total == 550)
        table.mergeMissing(["a": 999, "d": 1])
        #expect(table.size(of: "a") == 50)
        #expect(table.total == 551)
        table.keepOnly(["a", "d"])
        #expect(table.total == 51)
        #expect(table.knownCount == 2)
    }

    @Test func tableSurvivesEncoding() throws {
        var table = Self.table(["Aa+/=1": 1_234_567_890_123, "b": 0, "c": 7], complete: false)
        table.scannedThrough = 3
        table.libraryCount = 10
        let decoded = try #require(AssetSizeTable(decoding: table.encoded()))
        #expect(decoded == table)
        #expect(AssetSizeTable(decoding: Data("nonsense".utf8)) == nil)

        // A walk in progress keeps what it has seen, including items without a size.
        table.walk = AssetSizeTable.Walk(start: 0, libraryCount: 10, seen: ["b", "no-size"], isValid: false)
        #expect(AssetSizeTable(decoding: table.encoded()) == table)

        // Version 1 files still load.
        let version1 = "uncloud-sizes 1 measured 10 3 0\n5\ta\n6\tb\n"
        let old = try #require(AssetSizeTable(decoding: Data(version1.utf8)))
        #expect(old.total == 11)
        #expect(old.walk == nil)
        #expect(old.scannedThrough == 3)
    }

    // MARK: - Walks the library changes under

    private static func page(_ ids: [String]) -> [String: Int64] {
        Dictionary(uniqueKeysWithValues: ids.map { ($0, Int64(100)) })
    }

    @Test func anInterruptedWalkFromTheStartStillDropsDeletedItems() async throws {
        try await withTemporaryDirectoryAsync { root in
            let store = AssetSizeStore(directory: root.appending(path: "sizes", directoryHint: .isDirectory))
            // Complete for a library of a, b, c, d; then d was deleted.
            try store.save(Self.table(Self.page(["a", "b", "c", "d"])), account: "x")
            let index = AssetSizeIndex(table: AssetSizeTable(kind: .measured), store: store, account: "x")
            await index.loadSaved()
            #expect(await index.scanPlan(libraryCount: 3) == .walk(from: 0))
            await index.beginScan(from: 0, libraryCount: 3)
            await index.recordScan(sizes: Self.page(["a"]), unsized: ["b"], scannedThrough: 2, libraryCount: 3)
            #expect(await index.endScan(complete: false, libraryCount: nil) == false)

            // After a relaunch: the walk resumes where it stopped, with what it had seen.
            let resumed = AssetSizeIndex(table: AssetSizeTable(kind: .measured), store: store, account: "x")
            await resumed.loadSaved()
            #expect(await resumed.scanPlan(libraryCount: 3) == .walk(from: 2))
            await resumed.beginScan(from: 2, libraryCount: 3)
            await resumed.recordScan(sizes: Self.page(["c"]), scannedThrough: 3, libraryCount: 3)
            #expect(await resumed.endScan(complete: true, libraryCount: 3))
            let table = await resumed.table
            // d is gone; b, seen without a size this time, keeps the size it had.
            #expect(table.size(of: "d") == nil)
            #expect(table.size(of: "b") == 100)
            #expect(table.total == 300)
            #expect(table.isComplete)
            #expect(await resumed.estimate(for: .everything, libraryCount: 3) == StorageEstimate(bytes: 300, isExact: true, basis: .scanned))
        }
    }

    @Test func aWalkTheLibraryShrankUnderStartsOverInsteadOfCompleting() async throws {
        let index = AssetSizeIndex(table: AssetSizeTable(kind: .measured))
        // Walking a library of a, b, c, d: interrupted after a and b.
        await index.beginScan(from: 0, libraryCount: 4)
        await index.recordScan(sizes: Self.page(["a", "b"]), scannedThrough: 2, libraryCount: 4)
        await index.endScan(complete: false, libraryCount: nil)
        // a was deleted, so c and d moved to offsets 1 and 2: resuming at 2 would skip c.
        #expect(await index.scanPlan(libraryCount: 3) == .walk(from: 0))

        // Resumed without knowing the size, the walk learns it changed and doesn't complete.
        await index.beginScan(from: 2, libraryCount: nil)
        await index.recordScan(sizes: Self.page(["d"]), scannedThrough: 3, libraryCount: 3)
        #expect(await index.endScan(complete: true, libraryCount: 3) == false)
        #expect(await index.table.isComplete == false)
        #expect(await index.scanPlan(libraryCount: 3) == .walk(from: 0))

        // The walk from the start completes, and a is gone.
        await index.beginScan(from: 0, libraryCount: 3)
        await index.recordScan(sizes: Self.page(["b", "c", "d"]), scannedThrough: 3, libraryCount: 3)
        #expect(await index.endScan(complete: true, libraryCount: 3))
        #expect(await index.table.size(of: "a") == nil)
        #expect(await index.table.total == 300)
        #expect(await index.scanPlan(libraryCount: 3) == .topUp)
    }

    // MARK: - Walks and exports

    /// Scans that each run until the test releases them, ignoring cancellation like a walk whose
    /// bridge is slow to answer.
    private final class ScriptedScans: Sendable {
        private struct State {
            var started = 0
            var waiting: [Int: CheckedContinuation<ICloudSizeScanner.Outcome, Never>] = [:]
            var released: [Int: ICloudSizeScanner.Outcome] = [:]
        }

        private let state = OSAllocatedUnfairLock(uncheckedState: State())

        var started: Int { state.withLockUnchecked { $0.started } }

        func run() async -> ICloudSizeScanner.Outcome {
            await withCheckedContinuation { continuation in
                let outcome = state.withLockUnchecked { state -> ICloudSizeScanner.Outcome? in
                    state.started += 1
                    if let outcome = state.released[state.started] {
                        return outcome
                    }
                    state.waiting[state.started] = continuation
                    return nil
                }
                if let outcome {
                    continuation.resume(returning: outcome)
                }
            }
        }

        func release(_ number: Int, with outcome: ICloudSizeScanner.Outcome) {
            let continuation = state.withLockUnchecked { state in
                state.released[number] = outcome
                return state.waiting.removeValue(forKey: number)
            }
            continuation?.resume(returning: outcome)
        }
    }

    @MainActor
    private final class EmptyBackend: LibraryBrowserBackend {
        func loadCount() async throws -> Int { 0 }
        func loadPage(_ index: Int, pageSize: Int) async throws -> [Uncloud.LibraryItem] { [] }
        func thumbnail(for item: Uncloud.LibraryItem, pixelSize: CGSize) async -> NSImage? { nil }
        func rankHints(for ids: Set<String>) async -> [String: Int] { [:] }
        func knownBytes() async -> [String: Int64] { [:] }
        func reset() async {}
    }

    @Test(.timeLimit(.minutes(1))) @MainActor func aCancelledWalkThatEndsLateLeavesTheNewerWalkAlone() async throws {
        try await withTemporaryDirectoryAsync { root in
            let scans = ScriptedScans()
            let estimator = StorageEstimator(
                store: AssetSizeStore(directory: root.appending(path: "sizes", directoryHint: .isDirectory)),
                allowsScanning: true,
                resumeDelay: .milliseconds(20),
                scan: { _, _, _, _ in await scans.run() }
            )
            let browser = LibraryBrowser(source: .iCloud, backend: EmptyBackend())
            estimator.configure(source: .iCloud, account: "fake@example.invalid", browser: browser, selection: .everything)
            try await Self.waitUntil { scans.started == 1 }

            // An export stops walk 1, which goes on until its bridge answers; the export finishes
            // and walk 2 starts.
            estimator.exportDidStart()
            estimator.exportDidFinish()
            try await Self.waitUntil { scans.started == 2 }

            // Walk 1 ends late: walk 2 is still the current walk, and no third one starts.
            scans.release(1, with: .interrupted)
            try await Task.sleep(for: .milliseconds(300))
            #expect(scans.started == 2)
            #expect(estimator.isScanRunning)

            scans.release(2, with: .complete)
            try await Self.waitUntil { !estimator.isScanRunning }
            try await Task.sleep(for: .milliseconds(100))
            #expect(scans.started == 2)
        }
    }

    @MainActor
    private static func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !condition() {
            guard ContinuousClock.now < deadline else {
                Issue.record("Timed out")
                return
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    @Test func scanPlanResumesTopsUpOrRestarts() async {
        var partial = Self.table(["a": 1], complete: false)
        partial.scannedThrough = 400
        partial.walk = AssetSizeTable.Walk(start: 0, libraryCount: 1000, seen: ["a"])
        #expect(await AssetSizeIndex(table: partial).scanPlan(libraryCount: 1000) == .walk(from: 400))
        // The library changed size since the walk started: items moved, so it starts over.
        #expect(await AssetSizeIndex(table: partial).scanPlan(libraryCount: 400) == .walk(from: 0))
        partial.walk?.libraryCount = 400
        partial.scannedThrough = 400
        #expect(await AssetSizeIndex(table: partial).scanPlan(libraryCount: 400) == .walk(from: 300))
        // An incomplete table with no walk to resume (such as one saved before walks were kept).
        partial.walk = nil
        #expect(await AssetSizeIndex(table: partial).scanPlan(libraryCount: 1000) == .walk(from: 0))

        var complete = Self.table(["a": 1])
        complete.libraryCount = 1000
        // Unchanged or grown: new items sit at rank 0, so a top-up sizes them.
        #expect(await AssetSizeIndex(table: complete).scanPlan(libraryCount: 1000) == .topUp)
        #expect(await AssetSizeIndex(table: complete).scanPlan(libraryCount: 1050) == .topUp)
        #expect(await AssetSizeIndex(table: complete).scanPlan(libraryCount: 990) == .walk(from: 0))
        // Only a library whose size is unknown is up to date.
        #expect(await AssetSizeIndex(table: complete).scanPlan(libraryCount: nil) == .upToDate)
    }

    // MARK: - Top-ups

    /// A library newest first: `ids[0]` is at offset 0. Sizes come from `sizes`, and an ID without one
    /// has no size in the bridge's answer.
    private actor NewestFirstLibrary: ICloudPageFetching {
        let ids: [String]
        let sizes: [String: Int64]
        private(set) var pagesFetched = 0

        init(ids: [String], sizes: [String: Int64]) {
            self.ids = ids
            self.sizes = sizes
        }

        func count() async throws -> Int {
            ids.count
        }

        func assets(offset: Int, limit: Int) async throws -> [ICloudAsset] {
            pagesFetched += 1
            let upper = min(ids.count, offset + limit)
            guard offset < upper else { return [] }
            return ids[offset..<upper].map { id in
                ICloudAsset(id: id, filename: id, created: nil, isVideo: false, thumbnailURL: nil, bytes: sizes[id])
            }
        }
    }

    /// Items "old-0" ... "old-(count-1)", each 100 bytes, as a complete table of a library of `count`.
    private static func completeTable(oldCount count: Int) -> AssetSizeTable {
        var table = AssetSizeTable(kind: .measured)
        table.merge(Dictionary(uniqueKeysWithValues: (0..<count).map { ("old-\($0)", Int64(100)) }))
        table.libraryCount = count
        table.scannedThrough = count
        table.isComplete = true
        return table
    }

    @Test func aGrownLibraryIsToppedUpWithItsNewItemsOnly() async throws {
        let newIDs = (0..<50).map { "new-\($0)" }
        let oldIDs = (0..<1000).map { "old-\($0)" }
        let sizes = Dictionary(uniqueKeysWithValues: (newIDs.map { ($0, Int64(7)) }) + oldIDs.map { ($0, Int64(100)) })
        let library = NewestFirstLibrary(ids: newIDs + oldIDs, sizes: sizes)
        let index = AssetSizeIndex(table: Self.completeTable(oldCount: 1000))

        #expect(await index.scanPlan(libraryCount: 1050) == .topUp)
        let grew = try await index.topUp(fetcher: library, libraryCount: 1050)
        #expect(grew)
        // The new items are sized and the old ones are left alone; two pages cover the run of old items.
        #expect(await index.table.knownCount == 1050)
        #expect(await index.table.size(of: "new-0") == 7)
        #expect(await index.table.size(of: "new-49") == 7)
        #expect(await index.table.size(of: "old-0") == 100)
        #expect(await index.table.total == 50 * 7 + 1000 * 100)
        #expect(await library.pagesFetched <= 2)
        #expect(await index.isComplete)
        #expect(await index.libraryCount == 1050)
        #expect(await index.scanPlan(libraryCount: 1050) == .topUp)
    }

    @Test func aTopUpSizesANewItemWhenTheCountDidNotChange() async throws {
        // One item was added at the top and the oldest was deleted: the count is still 1000.
        let oldIDs = (0..<999).map { "old-\($0)" }
        let sizes = Dictionary(uniqueKeysWithValues: oldIDs.map { ($0, Int64(100)) } + [("fresh", Int64(5))])
        let library = NewestFirstLibrary(ids: ["fresh"] + oldIDs, sizes: sizes)
        let index = AssetSizeIndex(table: Self.completeTable(oldCount: 1000))

        let unchanged = try await index.topUp(fetcher: library, libraryCount: 1000)
        #expect(unchanged)
        #expect(await index.table.size(of: "fresh") == 5)
        #expect(await index.isComplete)
    }

    @Test func aTopUpGivesUpAfterTheCapAndWalksFromTheStart() async throws {
        let newIDs = (0..<6000).map { "new-\($0)" }
        let oldIDs = (0..<1000).map { "old-\($0)" }
        let library = NewestFirstLibrary(ids: newIDs + oldIDs, sizes: [:])
        let index = AssetSizeIndex(table: Self.completeTable(oldCount: 1000))

        let capped = try await index.topUp(fetcher: library, libraryCount: 7000, cap: 5_000)
        #expect(capped == false)
        #expect(await index.isComplete == false)
        #expect(await index.scanPlan(libraryCount: 7000) == .walk(from: 0))
    }

    // MARK: - Photos heuristic

    private static let megabyte: Int64 = 1_000_000

    @Test func photoEstimatesStayInRealisticBounds() {
        // A 12 MP iPhone photo is about 1.5–5 MB as HEIC or JPEG.
        let photo = PhotoSizeHeuristic.estimatedBytes(mediaType: .image, pixelWidth: 4032, pixelHeight: 3024, duration: 0, isLivePhoto: false, hasAdjustments: false)
        #expect(photo >= 2 * Self.megabyte && photo <= 8 * Self.megabyte)
        // A Live Photo adds its movie; an edited one is exported twice.
        let live = PhotoSizeHeuristic.estimatedBytes(mediaType: .image, pixelWidth: 4032, pixelHeight: 3024, duration: 0, isLivePhoto: true, hasAdjustments: false)
        #expect(live - photo >= 2 * Self.megabyte && live - photo <= 6 * Self.megabyte)
        let edited = PhotoSizeHeuristic.estimatedBytes(mediaType: .image, pixelWidth: 4032, pixelHeight: 3024, duration: 0, isLivePhoto: false, hasAdjustments: true)
        #expect(edited == 2 * photo)
        // A tiny image still counts as a file.
        let tiny = PhotoSizeHeuristic.estimatedBytes(mediaType: .image, pixelWidth: 10, pixelHeight: 10, duration: 0, isLivePhoto: false, hasAdjustments: false)
        #expect(tiny == PhotoSizeHeuristic.minimumPhotoBytes)
    }

    @Test func videoEstimatesScaleWithLengthAndResolution() {
        // A minute of 4K is about 170–400 MB from an iPhone.
        let fourK = PhotoSizeHeuristic.estimatedBytes(mediaType: .video, pixelWidth: 3840, pixelHeight: 2160, duration: 60, isLivePhoto: false, hasAdjustments: false)
        #expect(fourK >= 170 * Self.megabyte && fourK <= 500 * Self.megabyte)
        // A minute of 1080p is about 60–130 MB.
        let hd = PhotoSizeHeuristic.estimatedBytes(mediaType: .video, pixelWidth: 1920, pixelHeight: 1080, duration: 60, isLivePhoto: false, hasAdjustments: false)
        #expect(hd >= 60 * Self.megabyte && hd <= 200 * Self.megabyte)
        #expect(hd < fourK)
        let twice = PhotoSizeHeuristic.estimatedBytes(mediaType: .video, pixelWidth: 1920, pixelHeight: 1080, duration: 120, isLivePhoto: false, hasAdjustments: false)
        #expect(twice == 2 * hd)
        let broken = PhotoSizeHeuristic.estimatedBytes(mediaType: .video, pixelWidth: 0, pixelHeight: 0, duration: .nan, isLivePhoto: false, hasAdjustments: false)
        #expect(broken == PhotoSizeHeuristic.minimumVideoBytes)
        let audio = PhotoSizeHeuristic.estimatedBytes(mediaType: .audio, pixelWidth: 0, pixelHeight: 0, duration: 60, isLivePhoto: false, hasAdjustments: false)
        #expect(audio > 1 * Self.megabyte && audio < 3 * Self.megabyte)
    }

    // MARK: - Free space

    @Test func warnsOnlyWhenItDoesNotFit() {
        let gigabyte: Int64 = 1_000_000_000
        #expect(StorageCheck.warning(needed: 100 * gigabyte, isExact: false, free: 200 * gigabyte, destinationName: "Drive") == nil)
        #expect(StorageCheck.warning(needed: nil, isExact: false, free: 1, destinationName: "Drive") == nil)
        #expect(StorageCheck.warning(needed: 5, isExact: false, free: nil, destinationName: "Drive") == nil)
        let warning = StorageCheck.warning(needed: 412 * gigabyte, isExact: false, free: 220 * gigabyte, destinationName: "Backup Drive")
        #expect(warning == "This needs about \(StorageEstimate.format(412 * gigabyte)), but “Backup Drive” has \(StorageEstimate.format(220 * gigabyte)) free.")
        let exact = StorageCheck.warning(needed: 3 * gigabyte, isExact: true, free: gigabyte, destinationName: "USB")
        #expect(exact?.hasPrefix("This needs \(StorageEstimate.format(3 * gigabyte)),") == true)
    }

    @Test func itemsAlreadyExportedAreLeftOut() {
        let estimate = StorageEstimate(bytes: 1000, isExact: true, basis: .scanned)
        #expect(StorageCheck.remainingBytes(of: estimate, selected: 10, exported: 0) == 1000)
        #expect(StorageCheck.remainingBytes(of: estimate, selected: 10, exported: 4) == 600)
        #expect(StorageCheck.remainingBytes(of: estimate, selected: 10, exported: 10) == 0)
        #expect(StorageCheck.remainingBytes(of: estimate, selected: 0, exported: 0) == 1000)
    }

    @Test func spaceRowSaysWhatIsLeftToExport() {
        let gigabyte: Int64 = 1_000_000_000
        // A first export: the whole selection is what's needed.
        #expect(SpaceRowText.value(estimateText: "about 412 GB", hasEstimate: true, backedUp: false, needed: nil, free: 220 * gigabyte)
            == "About 412 GB needed · \(StorageEstimate.format(220 * gigabyte)) free")
        // Backed-up photos: only what's still to go.
        #expect(SpaceRowText.value(estimateText: "about 3.92 TB", hasEstimate: true, backedUp: true, needed: 1000 * gigabyte, free: 2000 * gigabyte)
            == "About \(StorageEstimate.format(1000 * gigabyte)) to export · \(StorageEstimate.format(2000 * gigabyte)) free")
        // Nothing left to export.
        #expect(SpaceRowText.value(estimateText: "about 3.92 TB", hasEstimate: true, backedUp: true, needed: 0, free: nil) == "Nothing to export")
        // No estimate yet, and no free space without a destination.
        #expect(SpaceRowText.value(estimateText: "estimating…", hasEstimate: false, backedUp: false, needed: nil, free: nil) == "Estimating…")
        #expect(SpaceRowText.value(estimateText: nil, hasEstimate: false, backedUp: true, needed: nil, free: 5) == nil)
    }

    @Test func readsFreeSpaceOfATemporaryFolder() throws {
        try withTemporaryDirectory { folder in
            let free = try #require(StorageCheck.freeBytes(at: folder))
            #expect(free > 0)
        }
    }

    // MARK: - Scanning through the fake bridge

    private final class BundleToken {}

    @Test(.timeLimit(.minutes(1))) func scanThroughTheFakeBridgeGivesTheExactTotal() async throws {
        let python = try #require(ICloudAccount.helperURL ?? ICloudAccount.helperOverride?.executableURL)
        let fake = try #require(Bundle(for: BundleToken.self).url(forResource: "fake_bridge", withExtension: "py"))
        try await withTemporaryDirectoryAsync { root in
            let total = 1234
            let appleID = "fake-\(UUID().uuidString.prefix(8))@example.invalid"
            let bridge = ICloudBridge(
                appleID: appleID,
                executableURL: python,
                arguments: ["-I", "-B", fake.path(percentEncoded: false), "--total", "\(total)", "--",
                            "-u", appleID, "--cookie-directory", root.path(percentEncoded: false)]
            )
            defer { bridge.terminate() }
            let store = AssetSizeStore(directory: root.appending(path: "sizes", directoryHint: .isDirectory))
            let index = AssetSizeIndex(table: AssetSizeTable(kind: .measured), store: store, account: appleID)

            let outcome = await ICloudSizeScanner.scan(bridge: bridge, index: index, libraryCount: total, onProgress: {})
            guard case .complete = outcome else {
                Issue.record("The scan didn't complete: \(outcome)")
                return
            }
            // fake_bridge.py: item i is 1000 + i bytes.
            let expected = Int64((0..<total).reduce(0) { $0 + 1000 + $1 })
            let estimate = await index.estimate(for: .everything, libraryCount: total)
            #expect(estimate == StorageEstimate(bytes: expected, isExact: true, basis: .scanned))
            #expect(await index.estimate(for: .only(["asset-0", "asset-10"]), libraryCount: total)?.bytes == 2010)
            #expect(await index.estimate(for: .allExcept(["asset-0"]), libraryCount: total)?.bytes == expected - 1000)
            #expect(await index.scanPlan(libraryCount: total) == .topUp)

            // Saved for the account, so the next launch needs no scan.
            let saved = try #require(store.load(account: appleID))
            #expect(saved.isComplete)
            #expect(saved.total == expected)
            let reloaded = AssetSizeIndex(table: AssetSizeTable(kind: .measured), store: store, account: appleID)
            await reloaded.loadSaved()
            #expect(await reloaded.estimate(for: .everything, libraryCount: total)?.isExact == true)
        }
    }

    @Test(.timeLimit(.minutes(1))) func cancelledScanResumesWhereItStopped() async throws {
        let python = try #require(ICloudAccount.helperURL ?? ICloudAccount.helperOverride?.executableURL)
        let fake = try #require(Bundle(for: BundleToken.self).url(forResource: "fake_bridge", withExtension: "py"))
        try await withTemporaryDirectoryAsync { root in
            let total = 2000
            let appleID = "fake-\(UUID().uuidString.prefix(8))@example.invalid"
            let bridge = ICloudBridge(
                appleID: appleID,
                executableURL: python,
                arguments: ["-I", "-B", fake.path(percentEncoded: false), "--total", "\(total)", "--stats-delay", "0.05", "--",
                            "-u", appleID, "--cookie-directory", root.path(percentEncoded: false)]
            )
            defer { bridge.terminate() }
            let index = AssetSizeIndex(table: AssetSizeTable(kind: .measured))
            let scan = Task {
                await ICloudSizeScanner.scan(bridge: bridge, index: index, libraryCount: total, onProgress: {})
            }
            // Wait for a few pages, then stop, as an export starting does.
            while await index.table.knownCount < 300 {
                try await Task.sleep(for: .milliseconds(10))
            }
            scan.cancel()
            guard case .interrupted = await scan.value else {
                Issue.record("A cancelled scan should be interrupted")
                return
            }
            let stoppedAt = await index.table.scannedThrough
            #expect(stoppedAt >= 300 && stoppedAt < total)
            #expect(await index.estimate(for: .everything, libraryCount: total)?.isExact == false)

            let outcome = await ICloudSizeScanner.scan(bridge: bridge, index: index, libraryCount: total, onProgress: {})
            guard case .complete = outcome else {
                Issue.record("The resumed scan didn't complete: \(outcome)")
                return
            }
            let expected = Int64((0..<total).reduce(0) { $0 + 1000 + $1 })
            #expect(await index.estimate(for: .everything, libraryCount: total) == StorageEstimate(bytes: expected, isExact: true, basis: .scanned))
        }
    }

    @Test func sizeTablesStayPerAccountAndSignOutForgetsThemAll() throws {
        try withTemporaryDirectory { root in
            let store = AssetSizeStore(directory: root.appending(path: "sizes", directoryHint: .isDirectory))
            var first = AssetSizeTable(kind: .measured)
            first.set(111, for: "asset-1")
            var second = AssetSizeTable(kind: .measured)
            second.set(222, for: "asset-2")

            // The Apple ID never appears in the file name; the case of the ID doesn't change its file.
            #expect(!store.fileURL(account: "Someone@Example.com").lastPathComponent.contains("someone"))
            #expect(store.fileURL(account: "Someone@Example.com") == store.fileURL(account: " someone@example.com "))
            #expect(store.fileURL(account: "a@example.com") != store.fileURL(account: "b@example.com"))

            try store.save(first, account: "a@example.com")
            try store.save(second, account: "b@example.com")
            #expect(store.load(account: "a@example.com")?.size(of: "asset-1") == 111)
            #expect(store.load(account: "a@example.com")?.size(of: "asset-2") == nil)
            #expect(store.load(account: "b@example.com")?.size(of: "asset-2") == 222)

            // Sign-out removes every account's sizes.
            store.removeAll()
            #expect(store.load(account: "a@example.com") == nil)
            #expect(store.load(account: "b@example.com") == nil)
        }
    }
}
