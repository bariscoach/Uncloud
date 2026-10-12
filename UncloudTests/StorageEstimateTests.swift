import Foundation
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
    }

    @Test func scanStartResumesExtendsOrRestarts() async {
        var partial = Self.table(["a": 1], complete: false)
        partial.scannedThrough = 400
        #expect(await AssetSizeIndex(table: partial).scanStart(libraryCount: 1000) == 400)
        #expect(await AssetSizeIndex(table: partial).scanStart(libraryCount: 400) == 300)

        var complete = Self.table(["a": 1])
        complete.libraryCount = 1000
        #expect(await AssetSizeIndex(table: complete).scanStart(libraryCount: 1000) == nil)
        #expect(await AssetSizeIndex(table: complete).scanStart(libraryCount: 1050) == 900)
        #expect(await AssetSizeIndex(table: complete).scanStart(libraryCount: 990) == 0)
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
            #expect(await index.scanStart(libraryCount: total) == nil)

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
}
