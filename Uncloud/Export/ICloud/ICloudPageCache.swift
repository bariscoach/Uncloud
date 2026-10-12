import CryptoKit
import Foundation

/// One item of the iCloud Photos library, as the browser sees it.
struct ICloudAsset: Sendable, Hashable, Identifiable {
    let id: String
    let filename: String
    let created: Date?
    let isVideo: Bool
    /// A signed URL for a small JPEG. It expires, after which iCloud answers 403 or 410.
    let thumbnailURL: URL?
    /// What exporting the item writes (the original plus any Live Photo movie), when known.
    var bytes: Int64? = nil
}

/// Where pages of the library come from: the bridge in the app, a fake in tests.
protocol ICloudPageFetching: Sendable {
    func count() async throws -> Int
    /// Items `offset..<offset + limit` in icloudpd's order, oldest first.
    func assets(offset: Int, limit: Int) async throws -> [ICloudAsset]
}

/// Fetches thumbnail bytes. Returns the HTTP status with the body.
protocol ICloudThumbnailFetching: Sendable {
    func data(from url: URL) async throws -> (Data, Int)
}

struct URLSessionThumbnailFetcher: ICloudThumbnailFetching {
    let session: URLSession

    init(session: URLSession = URLSessionThumbnailFetcher.defaultSession) {
        self.session = session
    }

    /// Thumbnails are cached on disk by the page cache, so the URL cache is off.
    static let defaultSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpMaximumConnectionsPerHost = 6
        configuration.timeoutIntervalForRequest = 30
        return URLSession(configuration: configuration)
    }()

    func data(from url: URL) async throws -> (Data, Int) {
        let (data, response) = try await session.data(from: url)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }
}

/// Pages the iCloud library newest first and caches thumbnails on disk.
///
/// Page `n` holds items `n * pageSize ..< (n + 1) * pageSize` counted from the newest. Each page is
/// fetched once even when many callers ask at the same time, at most `maxPages` stay in memory, and
/// a thumbnail whose signed URL has expired (403 or 410) is retried once with a freshly fetched page.
actor ICloudPageCache {
    let pageSize: Int
    let maxPages: Int
    private let fetcher: any ICloudPageFetching
    private let thumbnails: any ICloudThumbnailFetching
    private let thumbnailDirectory: URL

    private(set) var count: Int?
    private var countTask: Task<Int, Error>?
    private var pages: [Int: [ICloudAsset]] = [:]
    private var pageUse: [Int: UInt64] = [:]
    private var useClock: UInt64 = 0
    private var inFlight: [Int: Task<[ICloudAsset], Error>] = [:]
    /// Bumped by `reset()`, so a fetch that started earlier doesn't store a stale page.
    private var epoch = 0
    /// Where each item seen so far sits in icloudpd's order. A few MB for a large library; it lets
    /// a download of hand-picked items find them without walking the whole library.
    private var rankByID: [String: Int] = [:]
    /// The export size of each item seen so far, a sample for the storage estimate.
    private var bytesByID: [String: Int64] = [:]
    private var thumbnailTasks: [String: Task<Data?, Never>] = [:]

    init(
        fetcher: any ICloudPageFetching,
        thumbnails: any ICloudThumbnailFetching = URLSessionThumbnailFetcher(),
        thumbnailDirectory: URL,
        pageSize: Int = 200,
        maxPages: Int = 30
    ) {
        self.fetcher = fetcher
        self.thumbnails = thumbnails
        self.thumbnailDirectory = thumbnailDirectory
        self.pageSize = pageSize
        self.maxPages = max(1, maxPages)
    }

    // MARK: - Pages

    /// The library's size, fetched once until `reset()`.
    func loadCount() async throws -> Int {
        if let count {
            return count
        }
        if let countTask {
            return try await countTask.value
        }
        let fetcher = fetcher
        let task = Task { try await fetcher.count() }
        countTask = task
        do {
            let value = try await task.value
            if countTask == task {
                count = value
                countTask = nil
            }
            return value
        } catch {
            if countTask == task {
                countTask = nil
            }
            throw error
        }
    }

    /// Forgets the count and every page, such as after the library changed size.
    func reset() {
        epoch += 1
        count = nil
        countTask = nil
        pages = [:]
        pageUse = [:]
        inFlight = [:]
    }

    /// The page if it's in memory.
    func cachedPage(_ index: Int) -> [ICloudAsset]? {
        pages[index]
    }

    /// A page of items, newest first. Concurrent calls for the same page share one fetch.
    func page(_ index: Int) async throws -> [ICloudAsset] {
        if let page = pages[index] {
            touch(index)
            return page
        }
        if let task = inFlight[index] {
            return try await task.value
        }
        let total = try await loadCount()
        // Another caller may have started or finished it while the count loaded.
        if let page = pages[index] {
            touch(index)
            return page
        }
        if let task = inFlight[index] {
            return try await task.value
        }
        let upper = total - index * pageSize
        guard index >= 0, upper > 0 else { return [] }
        let lower = max(0, upper - pageSize)

        let fetcher = fetcher
        // The task returns the page newest first, so callers that join it get the same order.
        let task = Task { Array(try await fetcher.assets(offset: lower, limit: upper - lower).reversed()) }
        inFlight[index] = task
        let startedEpoch = epoch
        do {
            let page = try await task.value
            if inFlight[index] == task {
                inFlight[index] = nil
            }
            guard startedEpoch == epoch else { return page }
            for (position, asset) in page.enumerated() {
                rankByID[asset.id] = upper - 1 - position
                if let bytes = asset.bytes {
                    bytesByID[asset.id] = bytes
                }
            }
            store(page, at: index)
            return page
        } catch {
            if inFlight[index] == task {
                inFlight[index] = nil
            }
            throw error
        }
    }

    /// Fetches a page again, replacing the cached copy (for fresh thumbnail URLs).
    func refreshPage(_ index: Int) async throws -> [ICloudAsset] {
        pages[index] = nil
        pageUse[index] = nil
        return try await page(index)
    }

    /// The asset with this ID if its page is in memory.
    func asset(withID id: String) -> ICloudAsset? {
        for page in pages.values {
            if let asset = page.first(where: { $0.id == id }) {
                return asset
            }
        }
        return nil
    }

    /// Where these IDs were last seen in icloudpd's order, for `ICloudBridgeRequest.hints`.
    func rankHints(for ids: Set<String>) -> [String: Int] {
        var hints: [String: Int] = [:]
        for id in ids {
            if let rank = rankByID[id] {
                hints[id] = rank
            }
        }
        return hints
    }

    /// The export sizes of the items seen so far, by ID.
    func knownBytes() -> [String: Int64] {
        bytesByID
    }

    private func touch(_ index: Int) {
        useClock += 1
        pageUse[index] = useClock
    }

    private func store(_ page: [ICloudAsset], at index: Int) {
        pages[index] = page
        touch(index)
        while pages.count > maxPages,
              let oldest = pageUse.filter({ $0.key != index }).min(by: { $0.value < $1.value })?.key {
            pages[oldest] = nil
            pageUse[oldest] = nil
        }
    }

    private func pageIndex(forID id: String) -> Int? {
        guard let rank = rankByID[id], let count, rank < count else { return nil }
        return (count - 1 - rank) / pageSize
    }

    // MARK: - Thumbnails

    /// The thumbnail of an item from a page in memory, or saved on disk earlier.
    func thumbnailData(forID id: String) async -> Data? {
        if let asset = asset(withID: id) {
            return await thumbnailData(for: asset)
        }
        return try? Data(contentsOf: thumbnailFile(for: id))
    }

    /// The thumbnail's JPEG bytes, from disk or downloaded once and saved there. Nil when the item
    /// has no thumbnail or it can't be fetched.
    func thumbnailData(for asset: ICloudAsset) async -> Data? {
        let file = thumbnailFile(for: asset.id)
        if let data = try? Data(contentsOf: file) {
            return data
        }
        if let task = thumbnailTasks[asset.id] {
            return await task.value
        }
        let task = Task { await self.downloadThumbnail(for: asset, to: file) }
        thumbnailTasks[asset.id] = task
        let data = await task.value
        thumbnailTasks[asset.id] = nil
        return data
    }

    private func downloadThumbnail(for asset: ICloudAsset, to file: URL) async -> Data? {
        var url = self.asset(withID: asset.id)?.thumbnailURL ?? asset.thumbnailURL
        for attempt in 0..<2 {
            guard let current = url, !Task.isCancelled else { return nil }
            guard let (data, status) = try? await thumbnails.data(from: current) else { return nil }
            switch status {
            case 200..<300 where !data.isEmpty:
                try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? data.write(to: file, options: .atomic)
                return data
            case 403, 410:
                // The signed URL expired: fetch the item's page again for a fresh one.
                guard attempt == 0, let index = pageIndex(forID: asset.id),
                      let page = try? await refreshPage(index),
                      let fresh = page.first(where: { $0.id == asset.id })?.thumbnailURL,
                      fresh != current else { return nil }
                url = fresh
            default:
                return nil
            }
        }
        return nil
    }

    nonisolated func thumbnailFile(for id: String) -> URL {
        let digest = SHA256.hash(data: Data(id.utf8)).map { String(format: "%02x", $0) }.joined()
        return thumbnailDirectory.appending(path: "\(digest.prefix(2))/\(digest).jpg")
    }

    /// Removes the least recently modified thumbnails until the folder is under `limit` bytes.
    nonisolated static func trimDiskCache(at directory: URL, limit: Int) {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: keys) else { return }
        var files: [(url: URL, size: Int, date: Date)] = []
        var total = 0
        while let url = enumerator.nextObject() as? URL {
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            let size = values.fileSize ?? 0
            total += size
            files.append((url, size, values.contentModificationDate ?? .distantPast))
        }
        guard total > limit else { return }
        for file in files.sorted(by: { $0.date < $1.date }) {
            try? FileManager.default.removeItem(at: file.url)
            total -= file.size
            if total <= limit { break }
        }
    }
}
