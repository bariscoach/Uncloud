import Foundation
import Testing
@testable import Uncloud

/// A library of `total` items with IDs "item-0" (newest, at offset 0) ... "item-(total-1)" (oldest).
private actor FakeLibrary: ICloudPageFetching {
    let total: Int
    private(set) var fetchCount = 0
    private(set) var fetchedRanges: [Range<Int>] = []
    private var thumbnailSuffix = 1

    init(total: Int) {
        self.total = total
    }

    func count() async throws -> Int {
        total
    }

    func assets(offset: Int, limit: Int) async throws -> [ICloudAsset] {
        fetchCount += 1
        fetchedRanges.append(offset..<(offset + limit))
        // Give concurrent callers a chance to join the same in-flight fetch.
        try await Task.sleep(for: .milliseconds(20))
        return (offset..<min(total, offset + limit)).map { index in
            ICloudAsset(
                id: "item-\(index)",
                filename: "IMG_\(index).HEIC",
                created: nil,
                isVideo: false,
                thumbnailURL: URL(string: "https://example.invalid/\(index)?v=\(thumbnailSuffix)"),
                previewURL: URL(string: "https://example.invalid/\(index)/preview?v=\(thumbnailSuffix)"),
                previewExtension: "heic"
            )
        }
    }

    /// Makes the next thumbnail URLs different, as after Apple expires them.
    func renewURLs() {
        thumbnailSuffix += 1
    }
}

/// Answers thumbnail requests from a script: each URL gets a queue of responses.
private actor FakeThumbnails: ICloudThumbnailFetching {
    private var responses: [String: [(Data, Int)]] = [:]
    private(set) var requested: [URL] = []

    func script(_ url: String, _ responses: [(Data, Int)]) {
        self.responses[url] = responses
    }

    func data(from url: URL) async throws -> (Data, Int) {
        requested.append(url)
        var queue = responses[url.absoluteString] ?? []
        guard !queue.isEmpty else { return (Data(), 404) }
        let next = queue.removeFirst()
        responses[url.absoluteString] = queue
        return next
    }
}

private func makeCache(
    library: FakeLibrary,
    thumbnails: FakeThumbnails = FakeThumbnails(),
    directory: URL,
    pageSize: Int = 3,
    maxPages: Int = 30
) -> ICloudPageCache {
    ICloudPageCache(
        fetcher: library,
        thumbnails: thumbnails,
        thumbnailDirectory: directory,
        previewDirectory: directory.appending(path: "previews", directoryHint: .isDirectory),
        pageSize: pageSize,
        maxPages: maxPages
    )
}

@Suite("ICloudPageCache")
struct ICloudPageCacheTests {
    @Test func pagesAreNewestFirst() async throws {
        try await withTemporaryDirectoryAsync { folder in
            let cache = makeCache(library: FakeLibrary(total: 7), directory: folder)
            let count = try await cache.loadCount()
            let first = try await cache.page(0).map(\.id)
            let second = try await cache.page(1).map(\.id)
            let third = try await cache.page(2).map(\.id)
            let beyond = try await cache.page(3)
            #expect(count == 7)
            #expect(first == ["item-0", "item-1", "item-2"])
            #expect(second == ["item-3", "item-4", "item-5"])
            #expect(third == ["item-6"])
            #expect(beyond.isEmpty)
        }
    }

    @Test func pagesCoverTheLibraryInRanges() async throws {
        try await withTemporaryDirectoryAsync { folder in
            let library = FakeLibrary(total: 7)
            let cache = makeCache(library: library, directory: folder)
            _ = try await cache.page(0)
            _ = try await cache.page(1)
            _ = try await cache.page(2)
            #expect(await library.fetchedRanges == [0..<3, 3..<6, 6..<7])
        }
    }

    @Test func concurrentRequestsForOnePageShareOneFetch() async throws {
        try await withTemporaryDirectoryAsync { folder in
            let library = FakeLibrary(total: 9)
            let cache = makeCache(library: library, directory: folder)
            let pages = try await withThrowingTaskGroup(of: [ICloudAsset].self) { group in
                for _ in 0..<8 {
                    group.addTask { try await cache.page(1) }
                }
                return try await group.reduce(into: []) { $0.append($1) }
            }
            #expect(pages.allSatisfy { $0.map(\.id) == ["item-3", "item-4", "item-5"] })
            #expect(await library.fetchCount == 1)
        }
    }

    @Test func cachedPagesAreNotFetchedAgain() async throws {
        try await withTemporaryDirectoryAsync { folder in
            let library = FakeLibrary(total: 6)
            let cache = makeCache(library: library, directory: folder)
            _ = try await cache.page(0)
            _ = try await cache.page(0)
            #expect(await library.fetchCount == 1)
        }
    }

    @Test func leastRecentlyUsedPagesAreEvictedPastTheLimit() async throws {
        try await withTemporaryDirectoryAsync { folder in
            let cache = makeCache(library: FakeLibrary(total: 12), directory: folder, pageSize: 3, maxPages: 2)
            _ = try await cache.page(0)
            _ = try await cache.page(1)
            _ = try await cache.page(0) // page 0 is now more recent than page 1
            _ = try await cache.page(2)
            #expect(await cache.cachedPage(0) != nil)
            #expect(await cache.cachedPage(1) == nil)
            #expect(await cache.cachedPage(2) != nil)
        }
    }

    @Test func rankHintsFindItemsAfterTheirPageLoads() async throws {
        try await withTemporaryDirectoryAsync { folder in
            let cache = makeCache(library: FakeLibrary(total: 7), directory: folder)
            _ = try await cache.page(1)
            // Page 1 holds item-3, item-4 and item-5. Ranks count from the newest item; item-0 isn't loaded.
            #expect(await cache.rankHints(for: ["item-3", "item-4", "item-0"]) == ["item-3": 3, "item-4": 4])
        }
    }

    @Test func resetForgetsPagesAndCount() async throws {
        try await withTemporaryDirectoryAsync { folder in
            let library = FakeLibrary(total: 4)
            let cache = makeCache(library: library, directory: folder)
            _ = try await cache.page(0)
            await cache.reset()
            #expect(await cache.count == nil)
            #expect(await cache.cachedPage(0) == nil)
            _ = try await cache.page(0)
            #expect(await library.fetchCount == 2)
        }
    }

    @Test func thumbnailIsDownloadedOnceAndKeptOnDisk() async throws {
        try await withTemporaryDirectoryAsync { folder in
            let library = FakeLibrary(total: 3)
            let thumbnails = FakeThumbnails()
            await thumbnails.script("https://example.invalid/0?v=1", [(Data([1, 2, 3]), 200)])
            let cache = makeCache(library: library, thumbnails: thumbnails, directory: folder)
            let asset = try await cache.page(0)[0]
            #expect(await cache.thumbnailData(for: asset) == Data([1, 2, 3]))
            #expect(await cache.thumbnailData(for: asset) == Data([1, 2, 3]))
            #expect(await thumbnails.requested.count == 1)
            // A new cache instance reads the file from disk.
            let reopened = makeCache(library: library, thumbnails: FakeThumbnails(), directory: folder)
            #expect(await reopened.thumbnailData(forID: asset.id) == Data([1, 2, 3]))
        }
    }

    @Test func expiredThumbnailURLIsRenewedOnce() async throws {
        try await withTemporaryDirectoryAsync { folder in
            let library = FakeLibrary(total: 3)
            let thumbnails = FakeThumbnails()
            await thumbnails.script("https://example.invalid/0?v=1", [(Data(), 403)])
            await thumbnails.script("https://example.invalid/0?v=2", [(Data([9]), 200)])
            let cache = makeCache(library: library, thumbnails: thumbnails, directory: folder)
            let asset = try await cache.page(0)[0]
            await library.renewURLs()
            #expect(await cache.thumbnailData(for: asset) == Data([9]))
            #expect(await thumbnails.requested.map(\.absoluteString) == [
                "https://example.invalid/0?v=1", "https://example.invalid/0?v=2",
            ])
        }
    }

    @Test func expiredThumbnailOnALaterPageRefreshesThatPage() async throws {
        try await withTemporaryDirectoryAsync { folder in
            let library = FakeLibrary(total: 7)
            let thumbnails = FakeThumbnails()
            await thumbnails.script("https://example.invalid/3?v=1", [(Data(), 403)])
            await thumbnails.script("https://example.invalid/3?v=2", [(Data([7]), 200)])
            let cache = makeCache(library: library, thumbnails: thumbnails, directory: folder)
            // item-3 is the first item of page 1, so its expired URL sends the cache back to page 1.
            let asset = try await cache.page(1)[0]
            #expect(asset.id == "item-3")
            await library.renewURLs()
            #expect(await cache.thumbnailData(for: asset) == Data([7]))
            #expect(await library.fetchedRanges == [3..<6, 3..<6])
        }
    }

    @Test func failedThumbnailGivesNilAndIsNotSaved() async throws {
        try await withTemporaryDirectoryAsync { folder in
            let library = FakeLibrary(total: 3)
            let thumbnails = FakeThumbnails()
            await thumbnails.script("https://example.invalid/0?v=1", [(Data(), 500)])
            let cache = makeCache(library: library, thumbnails: thumbnails, directory: folder)
            let asset = try await cache.page(0)[0]
            #expect(await cache.thumbnailData(for: asset) == nil)
            #expect(!FileManager.default.fileExists(atPath: cache.thumbnailFile(for: asset.id).path(percentEncoded: false)))
        }
    }

    @Test func previewIsDownloadedOnceAndKeptInThePreviewFolder() async throws {
        try await withTemporaryDirectoryAsync { folder in
            let library = FakeLibrary(total: 3)
            let thumbnails = FakeThumbnails()
            await thumbnails.script("https://example.invalid/0/preview?v=1", [(Data([4, 5]), 200)])
            let cache = makeCache(library: library, thumbnails: thumbnails, directory: folder)
            let asset = try await cache.page(0)[0]
            let file = try #require(await cache.previewFile(for: asset))
            #expect(file.pathExtension == "heic")
            #expect(file.deletingLastPathComponent().lastPathComponent == "previews")
            #expect(try Data(contentsOf: file) == Data([4, 5]))
            #expect(await cache.previewFile(for: asset) == file)
            #expect(await thumbnails.requested.map(\.absoluteString) == ["https://example.invalid/0/preview?v=1"])
            // A new cache instance finds the file by ID, without its page in memory and without a request.
            let reopenedThumbnails = FakeThumbnails()
            let reopened = makeCache(library: library, thumbnails: reopenedThumbnails, directory: folder)
            #expect(await reopened.previewFile(forID: asset.id) == file)
            #expect(await reopenedThumbnails.requested.isEmpty)
        }
    }

    @Test func concurrentPreviewRequestsShareOneDownload() async throws {
        try await withTemporaryDirectoryAsync { folder in
            let library = FakeLibrary(total: 3)
            let thumbnails = FakeThumbnails()
            await thumbnails.script("https://example.invalid/0/preview?v=1", [(Data([1]), 200)])
            let cache = makeCache(library: library, thumbnails: thumbnails, directory: folder)
            let asset = try await cache.page(0)[0]
            let files = await withTaskGroup(of: URL?.self) { group in
                for _ in 0..<6 {
                    group.addTask { await cache.previewFile(for: asset) }
                }
                return await group.reduce(into: [URL?]()) { $0.append($1) }
            }
            let first = try #require(files.first ?? nil)
            #expect(files.allSatisfy { $0 == first })
            #expect(await thumbnails.requested.count == 1)
        }
    }

    @Test func expiredPreviewURLIsRenewedOnce() async throws {
        try await withTemporaryDirectoryAsync { folder in
            let library = FakeLibrary(total: 3)
            let thumbnails = FakeThumbnails()
            await thumbnails.script("https://example.invalid/0/preview?v=1", [(Data(), 403)])
            await thumbnails.script("https://example.invalid/0/preview?v=2", [(Data([9]), 200)])
            let cache = makeCache(library: library, thumbnails: thumbnails, directory: folder)
            let asset = try await cache.page(0)[0]
            await library.renewURLs()
            let file = try #require(await cache.previewFile(for: asset))
            #expect(try Data(contentsOf: file) == Data([9]))
            #expect(await thumbnails.requested.map(\.absoluteString) == [
                "https://example.invalid/0/preview?v=1", "https://example.invalid/0/preview?v=2",
            ])
        }
    }

    @Test func failedPreviewGivesNilAndIsNotSaved() async throws {
        try await withTemporaryDirectoryAsync { folder in
            let thumbnails = FakeThumbnails()
            await thumbnails.script("https://example.invalid/0/preview?v=1", [(Data(), 500)])
            let cache = makeCache(library: FakeLibrary(total: 3), thumbnails: thumbnails, directory: folder)
            let asset = try await cache.page(0)[0]
            #expect(await cache.previewFile(for: asset) == nil)
            let location = cache.previewFileLocation(for: asset.id, fileExtension: "heic")
            #expect(!FileManager.default.fileExists(atPath: location.path(percentEncoded: false)))
        }
    }

    @Test func anItemWithoutAPreviewHasNoFileAndIsNotFetched() async {
        await withTemporaryDirectoryAsync { folder in
            let thumbnails = FakeThumbnails()
            let cache = makeCache(library: FakeLibrary(total: 3), thumbnails: thumbnails, directory: folder)
            let bare = ICloudAsset(id: "no-preview", filename: "IMG_9.JPG", created: nil, isVideo: false, thumbnailURL: nil)
            #expect(await cache.previewFile(for: bare) == nil)
            #expect(await cache.previewFile(forID: "never-seen") == nil)
            #expect(await thumbnails.requested.isEmpty)
        }
    }

    @Test func trimDiskCacheRemovesOldestFilesFirst() throws {
        try withTemporaryDirectory { folder in
            let old = try writeFile(String(repeating: "a", count: 100), to: "old.jpg", in: folder)
            let new = try writeFile(String(repeating: "b", count: 100), to: "new.jpg", in: folder)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -3600)], ofItemAtPath: old.path(percentEncoded: false))
            ICloudPageCache.trimDiskCache(at: folder, limit: 150)
            #expect(!FileManager.default.fileExists(atPath: old.path(percentEncoded: false)))
            #expect(FileManager.default.fileExists(atPath: new.path(percentEncoded: false)))
        }
    }
}
