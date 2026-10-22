import AppKit
import ImageIO
import Observation
import Photos

/// One item in the library browser, newest first.
struct LibraryItem: Identifiable, Hashable, Sendable {
    /// `PHAsset.localIdentifier`, or the iCloud asset ID; the same IDs `LibrarySelection` uses.
    let id: String
    let filename: String
    let created: Date?
    let isVideo: Bool
    /// From the local catalog, shown while the live page loads (R12f). A placeholder can't be selected.
    var isPlaceholder = false
}

/// Browses the whole library of the current source, newest first, a page at a time.
///
/// `item(at:)` answers from memory and starts loading the item's page when it isn't there yet,
/// so a lazy grid can ask for any index as it scrolls. Pages hold 200 items, each page is
/// requested once at a time, and only the most recently used pages stay in memory.
@MainActor
@Observable
final class LibraryBrowser {
    enum State: Equatable {
        case loading
        case ready
        case failed(String)
        case signInRequired
    }

    static let pageSize = 200
    /// Pages kept in memory: 6,000 items.
    static let maxPages = 30
    /// How long a page that failed to load waits before `item(at:)` tries it again.
    private static let retryDelay: Duration = .seconds(5)
    /// How often a load the bridge dropped (it was stopped mid-request) is tried again by itself.
    private static let interruptedRetries = 3
    private static let interruptedRetryDelay: Duration = .seconds(1)
    static let interruptedMessage = "The connection to iCloud was interrupted."

    let source: LibrarySource
    /// The number of items, once known.
    private(set) var count: Int?
    private(set) var state: State = .loading

    /// True while Apple is still indexing the library. The app checks again on its own; see `LibraryView`.
    var isWaitingForIndexing: Bool {
        if case let .failed(message) = state {
            return message == ICloudFailure.libraryIndexing.message
        }
        return false
    }

    private var pages: [Int: [LibraryItem]] = [:]
    /// Pages that hold catalog placeholders until their live page arrives (R12f).
    @ObservationIgnored private var placeholderPageIndices: Set<Int> = []
    @ObservationIgnored private var pageUse: [Int: UInt64] = [:]
    @ObservationIgnored private var useClock: UInt64 = 0
    @ObservationIgnored private var loadingPages: Set<Int> = []
    @ObservationIgnored private var failedPages: [Int: ContinuousClock.Instant] = [:]
    @ObservationIgnored private var countTask: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private let backend: any LibraryBrowserBackend

    /// A browser of the Photos library on this Mac.
    convenience init() {
        self.init(source: .photosLibrary, backend: PhotoKitBrowserBackend())
    }

    /// A browser of an iCloud Photos library, through the account's bridge: the library itself, or Recently Deleted.
    convenience init(appleID: String, album: ICloudBridgeAlbum = .library) {
        self.init(source: .iCloud, backend: ICloudBrowserBackend(appleID: appleID, album: album))
    }

    init(source: LibrarySource, backend: any LibraryBrowserBackend) {
        self.source = source
        self.backend = backend
    }

    // MARK: - Loading

    /// Counts the library if that hasn't happened yet. `item(at:)` calls it too.
    func load() {
        guard count == nil, countTask == nil else { return }
        startCounting(resettingBackend: false)
    }

    /// Forgets everything and counts again, such as after the library changed or after signing in.
    func reload() {
        generation += 1
        countTask?.cancel()
        countTask = nil
        count = nil
        pages = [:]
        placeholderPageIndices = []
        pageUse = [:]
        loadingPages = []
        failedPages = [:]
        startCounting(resettingBackend: true)
    }

    private func startCounting(resettingBackend: Bool) {
        state = .loading
        let generation = generation
        let backend = backend
        countTask = Task {
            if resettingBackend {
                await backend.reset()
            }
            // The catalog's count shows at once; the live count replaces it when it arrives, whatever it is (R12f).
            if let placeholder = await backend.placeholderCount(), generation == self.generation, count == nil {
                count = placeholder
                state = .ready
            }
            var attempt = 0
            while true {
                do {
                    let total = try await backend.loadCount()
                    guard generation == self.generation else { return }
                    count = total
                    state = .ready
                } catch where Self.isInterruption(error) && !Task.isCancelled && attempt < Self.interruptedRetries {
                    // The bridge stopped while counting (it signs in again on the next request).
                    attempt += 1
                    try? await Task.sleep(for: Self.interruptedRetryDelay)
                    guard generation == self.generation, !Task.isCancelled else { return }
                    continue
                } catch {
                    guard generation == self.generation else { return }
                    state = Self.state(for: error)
                }
                break
            }
            if generation == self.generation {
                countTask = nil
            }
        }
    }

    /// The item at `index` (0 is the newest), or nil while its page loads. Asking starts the load.
    func item(at index: Int) -> LibraryItem? {
        guard let count else {
            load()
            return nil
        }
        guard index >= 0, index < count else { return nil }
        let pageIndex = index / Self.pageSize
        if let page = pages[pageIndex] {
            useClock += 1
            pageUse[pageIndex] = useClock
            // A placeholder page keeps asking for its live page until that arrives.
            if placeholderPageIndices.contains(pageIndex) {
                loadPage(pageIndex)
            }
            let offset = index - pageIndex * Self.pageSize
            return offset < page.count ? page[offset] : nil
        }
        loadPage(pageIndex)
        return nil
    }

    /// The item at `index` when it can be selected: nil while its page loads, and for a catalog placeholder, which
    /// becomes selectable when its live page arrives (R12f).
    func selectableItem(at index: Int) -> LibraryItem? {
        guard let item = item(at: index), !item.isPlaceholder else { return nil }
        return item
    }

    /// Loads a page ahead of need, such as the one after the visible rows.
    func prefetch(around index: Int) {
        guard let count, index >= 0, index < count else { return }
        let pageIndex = index / Self.pageSize
        if pages[pageIndex] == nil || placeholderPageIndices.contains(pageIndex) {
            loadPage(pageIndex)
        }
    }

    private func loadPage(_ pageIndex: Int, interruptedRetries: Int = LibraryBrowser.interruptedRetries) {
        guard !loadingPages.contains(pageIndex) else { return }
        if let failedAt = failedPages[pageIndex], ContinuousClock.now - failedAt < Self.retryDelay {
            return
        }
        loadingPages.insert(pageIndex)
        let generation = generation
        Task {
            // Until the live page arrives, the catalog's page shows (R12f).
            if pages[pageIndex] == nil,
               let placeholder = await backend.placeholderPage(pageIndex, pageSize: Self.pageSize),
               generation == self.generation, pages[pageIndex] == nil {
                store(placeholder, at: pageIndex, isPlaceholder: true)
            }
            do {
                let items = try await backend.loadPage(pageIndex, pageSize: Self.pageSize)
                guard generation == self.generation else { return }
                loadingPages.remove(pageIndex)
                failedPages[pageIndex] = nil
                store(items, at: pageIndex)
            } catch {
                guard generation == self.generation else { return }
                loadingPages.remove(pageIndex)
                failedPages[pageIndex] = .now
                if case .signInRequired = Self.state(for: error) {
                    state = .signInRequired
                } else if Self.isInterruption(error), interruptedRetries > 0 {
                    // The bridge stopped mid-request. Nothing redraws the tiles that wait for this
                    // page, so try again without waiting for them to ask.
                    try? await Task.sleep(for: Self.interruptedRetryDelay)
                    guard generation == self.generation, pages[pageIndex] == nil else { return }
                    failedPages[pageIndex] = nil
                    loadPage(pageIndex, interruptedRetries: interruptedRetries - 1)
                }
            }
        }
    }

    private func store(_ items: [LibraryItem], at pageIndex: Int, isPlaceholder: Bool = false) {
        pages[pageIndex] = isPlaceholder
            ? items.map { item in
                var placeholder = item
                placeholder.isPlaceholder = true
                return placeholder
            }
            : items
        if isPlaceholder {
            placeholderPageIndices.insert(pageIndex)
        } else {
            placeholderPageIndices.remove(pageIndex)
        }
        useClock += 1
        pageUse[pageIndex] = useClock
        while pages.count > Self.maxPages,
              let oldest = pageUse.filter({ $0.key != pageIndex && pages[$0.key] != nil })
                  .min(by: { $0.value < $1.value })?.key {
            pages[oldest] = nil
            pageUse[oldest] = nil
        }
    }

    private static func state(for error: Error) -> State {
        if let error = error as? ICloudError, error == .signInRequired {
            return .signInRequired
        }
        if isInterruption(error) {
            return .failed(interruptedMessage)
        }
        return .failed(error.localizedDescription)
    }

    /// The bridge stopped mid-request, by sign-out or because it stopped answering and was
    /// restarted; the request can simply be made again.
    private static func isInterruption(_ error: Error) -> Bool {
        error is CancellationError || (error as? ICloudError) == .interrupted
    }

    // MARK: - Thumbnails and export support

    /// A thumbnail at about `pixelSize`, or nil when there's none.
    func thumbnail(for item: LibraryItem, pixelSize: CGSize) async -> NSImage? {
        await backend.thumbnail(for: item, pixelSize: pixelSize)
    }

    /// Where the given iCloud IDs were last seen, so an export of hand-picked items can find them quickly.
    func rankHints(for ids: Set<String>) async -> [String: Int] {
        await backend.rankHints(for: ids)
    }

    /// The export sizes of the items loaded so far, by ID, when the source reports them (iCloud).
    func knownBytes() async -> [String: Int64] {
        await backend.knownBytes()
    }
}

// MARK: - Backends

/// What a source provides to `LibraryBrowser`.
@MainActor
protocol LibraryBrowserBackend: AnyObject {
    func loadCount() async throws -> Int
    /// Items `index * pageSize ..< (index + 1) * pageSize`, newest first.
    func loadPage(_ index: Int, pageSize: Int) async throws -> [LibraryItem]
    func thumbnail(for item: LibraryItem, pixelSize: CGSize) async -> NSImage?
    func rankHints(for ids: Set<String>) async -> [String: Int]
    /// The export sizes of the items loaded so far, by ID; empty when the source has none.
    func knownBytes() async -> [String: Int64]
    /// Forgets cached pages and the count.
    func reset() async
    /// The library's count from a local catalog, shown before the live count loads (R12f). Nil when there is none.
    func placeholderCount() async -> Int?
    /// A page from a local catalog, shown while the live page loads (R12f). Nil when there is none.
    func placeholderPage(_ index: Int, pageSize: Int) async -> [LibraryItem]?
}

extension LibraryBrowserBackend {
    func placeholderCount() async -> Int? { nil }
    func placeholderPage(_ index: Int, pageSize: Int) async -> [LibraryItem]? { nil }
}

/// Carries Photos objects that are safe to read from any thread but aren't marked Sendable.
private struct PhotosBox<Value>: @unchecked Sendable {
    let value: Value
}

/// The Photos library on this Mac, through a newest-first fetch result.
@MainActor
final class PhotoKitBrowserBackend: LibraryBrowserBackend {
    private var assets: PHFetchResult<PHAsset>?
    private let imageManager = PHCachingImageManager()
    /// Assets of recently loaded pages, for thumbnails.
    private var assetsByID: [String: PHAsset] = [:]
    private static let maxRememberedAssets = LibraryBrowser.pageSize * LibraryBrowser.maxPages
    private let options: PHImageRequestOptions = {
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = false
        return options
    }()

    func loadCount() async throws -> Int {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .authorized || status == .limited else {
            throw PhotoKitBrowserError.noAccess
        }
        let assets = PhotoLibrary.allAssets(newestFirst: true)
        self.assets = assets
        return assets.count
    }

    func loadPage(_ index: Int, pageSize: Int) async throws -> [LibraryItem] {
        if assets == nil {
            _ = try await loadCount()
        }
        guard let assets else { return [] }
        let lower = index * pageSize
        let upper = min(assets.count, lower + pageSize)
        guard lower < upper else { return [] }
        let box = PhotosBox(value: assets)
        // Reading resource names takes a moment per item, so do it off the main actor.
        let loaded = await Task.detached(priority: .userInitiated) {
            (lower..<upper).map { position -> PhotosBox<(LibraryItem, PHAsset)> in
                let asset = box.value.object(at: position)
                return PhotosBox(value: (Self.item(for: asset), asset))
            }
        }.value
        if assetsByID.count > Self.maxRememberedAssets {
            assetsByID = [:]
        }
        for entry in loaded {
            assetsByID[entry.value.0.id] = entry.value.1
        }
        return loaded.map(\.value.0)
    }

    nonisolated private static func item(for asset: PHAsset) -> LibraryItem {
        let resources = PHAssetResource.assetResources(for: asset)
        let primary = resources.first { [.photo, .video, .audio].contains($0.type) } ?? resources.first
        return LibraryItem(
            id: asset.localIdentifier,
            filename: primary?.originalFilename ?? "Untitled",
            created: asset.creationDate,
            isVideo: asset.mediaType == .video
        )
    }

    func thumbnail(for item: LibraryItem, pixelSize: CGSize) async -> NSImage? {
        var asset = assetsByID[item.id]
        if asset == nil {
            asset = PHAsset.fetchAssets(withLocalIdentifiers: [item.id], options: nil).firstObject
        }
        guard let asset else { return nil }
        let manager = imageManager
        let options = options
        return await withCheckedContinuation { (continuation: CheckedContinuation<PhotosBox<NSImage?>, Never>) in
            manager.requestImage(for: asset, targetSize: pixelSize, contentMode: .aspectFill, options: options) { image, _ in
                // High-quality delivery calls this exactly once.
                continuation.resume(returning: PhotosBox(value: image))
            }
        }.value
    }

    func rankHints(for ids: Set<String>) async -> [String: Int] {
        [:]
    }

    func knownBytes() async -> [String: Int64] {
        [:]
    }

    func reset() async {
        assets = nil
        assetsByID = [:]
        imageManager.stopCachingImagesForAllAssets()
    }
}

enum PhotoKitBrowserError: LocalizedError {
    case noAccess

    var errorDescription: String? {
        "Uncloud doesn’t have access to Photos."
    }
}

/// The iCloud Photos library (or its Recently Deleted album), through the account's bridge and a page cache of its
/// own. Thumbnails are shared between the two albums, since an item's thumbnail is the same in both.
@MainActor
final class ICloudBrowserBackend: LibraryBrowserBackend {
    private let cache: ICloudPageCache
    /// The library's local catalog, for placeholders (R12f). Nil for Recently Deleted.
    private let catalog: ICloudCatalog?

    init(appleID: String, album: ICloudBridgeAlbum = .library) {
        let directory = ICloudLibrary.browserThumbnailDirectory
        // The library's pages feed the local catalog (R12c); Recently Deleted never does.
        let bridgeFetcher = ICloudBridgeFetcher(bridge: .shared(appleID: appleID), album: album)
        let catalog = album == .library ? ICloudCatalogStore.shared(appleID: appleID) : nil
        self.catalog = catalog
        cache = ICloudPageCache(
            fetcher: album == .library
                ? CatalogFeedingFetcher(base: bridgeFetcher, catalog: catalog)
                : bridgeFetcher,
            thumbnailDirectory: directory,
            pageSize: LibraryBrowser.pageSize,
            maxPages: LibraryBrowser.maxPages
        )
        if album == .library {
            Task.detached(priority: .background) {
                ICloudPageCache.trimDiskCache(at: directory, limit: 500 * 1024 * 1024)
            }
        }
    }

    func loadCount() async throws -> Int {
        try await cache.loadCount()
    }

    func loadPage(_ index: Int, pageSize: Int) async throws -> [LibraryItem] {
        try await cache.page(index).map {
            LibraryItem(id: $0.id, filename: $0.filename, created: $0.created, isVideo: $0.isVideo)
        }
    }

    func placeholderCount() async -> Int? {
        guard let catalog, let status = try? await catalog.status() else { return nil }
        return status.libraryCount
    }

    /// The catalog's page at `index`, in the library's order (rank hints). Nil without a catalog or a known count.
    func placeholderPage(_ index: Int, pageSize: Int) async -> [LibraryItem]? {
        guard let catalog, index >= 0, let count = await placeholderCount(),
              let rows = try? await catalog.page(offset: index * pageSize, limit: pageSize, libraryCount: count)
        else { return nil }
        return rows.map { LibraryItem(id: $0.id, filename: $0.filename, created: $0.created, isVideo: $0.isVideo) }
    }

    func thumbnail(for item: LibraryItem, pixelSize: CGSize) async -> NSImage? {
        guard let data = await cache.thumbnailData(forID: item.id) else { return nil }
        return await Task.detached(priority: .userInitiated) {
            PhotosBox(value: Self.image(from: data, maxPixels: max(pixelSize.width, pixelSize.height)))
        }.value.value
    }

    /// Decodes a JPEG at no more than `maxPixels` on its longer side.
    nonisolated private static func image(from data: Data, maxPixels: CGFloat) -> NSImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, Int(maxPixels.rounded(.up))),
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }

    func rankHints(for ids: Set<String>) async -> [String: Int] {
        await cache.rankHints(for: ids)
    }

    func knownBytes() async -> [String: Int64] {
        await cache.knownBytes()
    }

    func reset() async {
        await cache.reset()
    }
}
