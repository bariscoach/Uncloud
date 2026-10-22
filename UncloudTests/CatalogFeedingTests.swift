import Foundation
import Testing
@testable import Uncloud

/// A library of `total` items with IDs "item-0" (newest, at offset 0) ... "item-(total-1)" (oldest), and a Recently
/// Deleted album of `deleted` IDs.
private actor CatalogFakeLibrary: ICloudPageFetching {
    let total: Int
    let deleted: [String]

    init(total: Int, deleted: [String] = []) {
        self.total = total
        self.deleted = deleted
    }

    func count() async throws -> Int {
        total
    }

    func assets(offset: Int, limit: Int) async throws -> [ICloudAsset] {
        (max(0, offset)..<min(total, offset + limit)).map { index in
            ICloudAsset(
                id: "item-\(index)",
                filename: "IMG_\(index).HEIC",
                created: nil,
                isVideo: false,
                thumbnailURL: nil,
                bytes: Int64(index + 1),
                master: "master-\(index)",
                latitude: 51.5,
                longitude: -0.12,
                timeZoneOffset: 3600
            )
        }
    }

    /// Recently Deleted: the deleted IDs, as items.
    func trash(offset: Int, limit: Int) -> [ICloudAsset] {
        (max(0, offset)..<min(deleted.count, offset + limit)).map { index in
            ICloudAsset(id: deleted[index], filename: deleted[index], created: nil, isVideo: false, thumbnailURL: nil)
        }
    }
}

/// Serves the Recently Deleted album of a `CatalogFakeLibrary`.
private struct CatalogFakeTrash: ICloudPageFetching {
    let library: CatalogFakeLibrary

    func count() async throws -> Int {
        0
    }

    func assets(offset: Int, limit: Int) async throws -> [ICloudAsset] {
        await library.trash(offset: offset, limit: limit)
    }
}

private func temporaryCatalog() throws -> (catalog: ICloudCatalog, directory: URL) {
    let directory = FileManager.default.temporaryDirectory.appending(path: "catalog-feeding-\(UUID().uuidString)")
    let catalog = try ICloudCatalog.open(account: "feed1234feed5678", directory: directory)
    return (catalog, directory)
}

/// Writes the first `count` items of `library` into `catalog`, as a listing would have.
private func seed(_ catalog: ICloudCatalog, library: CatalogFakeLibrary, count: Int) async throws {
    let items = try await library.assets(offset: 0, limit: count)
    try await catalog.upsert(CatalogRows.rows(for: items, offset: 0, libraryCount: await library.total))
}

@Suite("Catalog feeding (R12c)")
struct CatalogFeedingTests {
    @Test("Pages pass through unchanged and land in the catalog with their ranks")
    func pagesPassThroughAndFeedTheCatalog() async throws {
        let (catalog, directory) = try temporaryCatalog()
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = CatalogFakeLibrary(total: 450)
        let fetcher = CatalogFeedingFetcher(base: library, catalog: catalog)

        let count = try await fetcher.count()
        #expect(count == 450)
        let first = try await fetcher.assets(offset: 0, limit: 200)
        let second = try await fetcher.assets(offset: 200, limit: 200)
        let expectedFirst = try await library.assets(offset: 0, limit: 200)
        let expectedSecond = try await library.assets(offset: 200, limit: 200)
        #expect(first == expectedFirst)
        #expect(second == expectedSecond)

        let rows = try await catalog.rows(ids: ["item-0", "item-250"])
        #expect(rows["item-0"]?.rank == 0)
        #expect(rows["item-250"]?.rank == 250)
        #expect(rows["item-250"]?.rankCount == 450)
        #expect(rows["item-250"]?.master == "master-250")
        #expect(rows["item-250"]?.latitude == 51.5)
        #expect(rows["item-250"]?.timeZoneOffset == 3600)
        #expect(try await catalog.status().libraryCount == 450)
    }

    @Test("Without a catalog the pages come back as the bridge sent them")
    func pagesPassThroughWithoutACatalog() async throws {
        let library = CatalogFakeLibrary(total: 30)
        let fetcher = CatalogFeedingFetcher(base: library, catalog: nil)
        let count = try await fetcher.count()
        #expect(count == 30)
        let page = try await fetcher.assets(offset: 5, limit: 10)
        let expected = try await library.assets(offset: 5, limit: 10)
        #expect(page == expected)
    }

    @Test("The top-up stops once 200 known items come in a row")
    func topUpStopsAfterTwoHundredKnownItems() async throws {
        let (catalog, directory) = try temporaryCatalog()
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = CatalogFakeLibrary(total: 1_000)
        try await seed(catalog, library: library, count: 600)

        let result = try await CatalogTopUp.run(
            fetcher: library, catalog: catalog, recentlyDeleted: CatalogFakeTrash(library: library)
        )
        #expect(result == .current(scanned: 200))
        #expect(try await catalog.status().topUpAt != nil)
    }

    @Test("A library with new items at the top is written as it is scanned")
    func topUpWritesNewItems() async throws {
        let (catalog, directory) = try temporaryCatalog()
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = CatalogFakeLibrary(total: 300)

        // Nothing known yet: the scan reaches the end of the library, which makes the catalog complete.
        let result = try await CatalogTopUp.run(
            fetcher: library, catalog: catalog, recentlyDeleted: CatalogFakeTrash(library: library)
        )
        #expect(result == .current(scanned: 300))
        #expect(try await catalog.status().rowCount == 300)
    }

    @Test("Recently Deleted IDs are removed from the catalog")
    func recentlyDeletedIDsAreRemoved() async throws {
        let (catalog, directory) = try temporaryCatalog()
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = CatalogFakeLibrary(total: 300, deleted: ["item-3", "item-7"])
        try await seed(catalog, library: library, count: 300)

        let result = try await CatalogTopUp.run(
            fetcher: library, catalog: catalog, recentlyDeleted: CatalogFakeTrash(library: library)
        )
        #expect(result == .current(scanned: 200))
        let left = try await catalog.rows(ids: ["item-3", "item-7", "item-8"])
        #expect(Set(left.keys) == ["item-8"])
    }

    @Test("Hitting the cap without a run of known items reports tooFar")
    func hittingTheCapReportsTooFar() async throws {
        let (catalog, directory) = try temporaryCatalog()
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = CatalogFakeLibrary(total: 10_000)

        let result = try await CatalogTopUp.run(
            fetcher: library, catalog: catalog, recentlyDeleted: CatalogFakeTrash(library: library), cap: 600
        )
        #expect(result == .tooFar)
        #expect(try await catalog.status().topUpAt == nil)
    }
}

private final class CatalogBundleToken {}

/// R12d: the storage estimate's scan answers from a trusted catalog, and walks (feeding the catalog) otherwise. Runs
/// through the fake bridge, whose launch log records each `stats` request.
@Suite("Catalog sizes (R12d)")
struct CatalogSizesTests {
    private static let total = 500

    private static func fakeBridge(root: URL, appleID: String, log: URL) throws -> ICloudBridge {
        let python = try #require(ICloudAccount.helperURL ?? ICloudAccount.helperOverride?.executableURL)
        let fake = try #require(Bundle(for: CatalogBundleToken.self).url(forResource: "fake_bridge", withExtension: "py"))
        return ICloudBridge(
            appleID: appleID,
            executableURL: python,
            arguments: ["-I", "-B", fake.path(percentEncoded: false), "--total", "\(total)",
                        "--launch-log", log.path(percentEncoded: false), "--",
                        "-u", appleID, "--cookie-directory", root.path(percentEncoded: false)]
        )
    }

    private static func openCatalog(root: URL) throws -> ICloudCatalog {
        try ICloudCatalog.open(account: "feed1234feed5678", directory: root.appending(path: "catalog"))
    }

    private static func tempRoot() throws -> URL {
        FileManager.default.temporaryDirectory.appending(path: "catalog-sizes-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    @Test(.timeLimit(.minutes(1))) func aTrustedCatalogAnswersWithoutAStatsWalk() async throws {
        let root = try Self.tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let appleID = "fake-trusted@example.invalid"
        let log = root.appending(path: "launch.log")
        let bridge = try Self.fakeBridge(root: root, appleID: appleID, log: log)
        defer { bridge.terminate() }

        let catalog = try Self.openCatalog(root: root)
        let started = Date().addingTimeInterval(-60)
        try await catalog.beginFullWalk(at: started)
        let items = (0..<Self.total).map { index in
            ICloudAsset(id: "asset-\(index)", filename: "IMG_\(index).JPG", created: nil, isVideo: false,
                        thumbnailURL: nil, bytes: Int64(1000 + index))
        }
        try await catalog.upsert(CatalogRows.rows(for: items, offset: 0, libraryCount: Self.total))
        _ = try await catalog.completeFullWalk(startedAt: started, libraryCount: Self.total, unlistedCount: nil)

        let index = AssetSizeIndex(table: AssetSizeTable(kind: .measured))
        let outcome = await ICloudSizeScanner.scan(
            bridge: bridge, index: index, libraryCount: Self.total, catalog: catalog, onProgress: {}
        )
        guard case .complete = outcome else {
            Issue.record("The scan didn't complete: \(outcome)")
            return
        }
        let expected = Int64((0..<Self.total).reduce(0) { $0 + 1000 + $1 })
        #expect(await index.estimate(for: .everything, libraryCount: Self.total)?.bytes == expected)
        let launches = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
        #expect(!launches.contains("stats offset="), Comment(rawValue: launches))
    }

    @Test(.timeLimit(.minutes(1))) func anUntrustedCatalogWalksAndFeedsItself() async throws {
        let root = try Self.tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let appleID = "fake-untrusted@example.invalid"
        let log = root.appending(path: "launch.log")
        let bridge = try Self.fakeBridge(root: root, appleID: appleID, log: log)
        defer { bridge.terminate() }

        let catalog = try Self.openCatalog(root: root)
        let index = AssetSizeIndex(table: AssetSizeTable(kind: .measured))
        let outcome = await ICloudSizeScanner.scan(
            bridge: bridge, index: index, libraryCount: Self.total, catalog: catalog, onProgress: {}
        )
        guard case .complete = outcome else {
            Issue.record("The scan didn't complete: \(outcome)")
            return
        }
        let expected = Int64((0..<Self.total).reduce(0) { $0 + 1000 + $1 })
        #expect(await index.estimate(for: .everything, libraryCount: Self.total)?.bytes == expected)
        let launches = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
        #expect(launches.contains("stats offset=0"))
        // The walk fed the catalog and marked a full walk as ended.
        #expect(try await catalog.status().rowCount == Self.total)
        #expect(try await catalog.status().fullWalkEndedAt != nil)
    }
}
