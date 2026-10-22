import CryptoKit
import Foundation

/// Saves one iCloud size table per account in `Application Support/<bundle id>/storage-estimates/`.
/// The Apple ID is hashed in the file name. Sign-out removes them all.
struct AssetSizeStore: Sendable {
    let directory: URL

    init(directory: URL = AssetSizeStore.defaultDirectory) {
        self.directory = directory
    }

    static var defaultDirectory: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let identifier = Bundle.main.bundleIdentifier ?? "Uncloud"
        return support.appending(path: identifier).appending(path: "storage-estimates", directoryHint: .isDirectory)
    }

    func fileURL(account: String) -> URL {
        let normalized = account.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let digest = SHA256.hash(data: Data(normalized.utf8))
        return directory.appending(path: "icloud-" + digest.prefix(12).map { String(format: "%02x", $0) }.joined() + ".sizes")
    }

    func load(account: String) -> AssetSizeTable? {
        guard let data = try? Data(contentsOf: fileURL(account: account)) else { return nil }
        return AssetSizeTable(decoding: data)
    }

    func save(_ table: AssetSizeTable, account: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try table.encoded().write(to: fileURL(account: account), options: .atomic)
    }

    /// Forgets every account's sizes, for sign-out.
    func removeAll() {
        try? FileManager.default.removeItem(at: directory)
    }
}

/// The size table of the current library, off the main actor: estimates for a selection are summed
/// here, and a scan merges into it as it goes.
actor AssetSizeIndex {
    private(set) var table: AssetSizeTable
    private let store: AssetSizeStore?
    private let account: String?
    /// Checked right before saving, so a scan that ends after sign-out doesn't write its sizes back.
    private let maySave: @Sendable () -> Bool
    private var unsavedItems = 0
    /// How many newly scanned items to collect before saving again.
    private static let saveInterval = 10_000

    /// An index saved per account (iCloud), or kept only in memory when `store` is nil.
    init(
        table: AssetSizeTable,
        store: AssetSizeStore? = nil,
        account: String? = nil,
        maySave: @escaping @Sendable () -> Bool = { true }
    ) {
        self.table = table
        self.store = store
        self.account = account
        self.maySave = maySave
    }

    /// Loads the account's saved table, if there is one.
    func loadSaved() {
        guard let store, let account, let saved = store.load(account: account), saved.kind == table.kind else { return }
        let samples = table
        table = saved
        // Keep sizes learned before the file was read.
        for (id, size) in samples.sizesSnapshot where table.size(of: id) == nil {
            table.set(size, for: id)
        }
    }

    func replace(with table: AssetSizeTable) {
        self.table = table
    }

    var isComplete: Bool { table.isComplete }
    var libraryCount: Int { table.libraryCount }

    /// Makes the table complete for `libraryCount` from the local catalog's sizes (R12d). Items without a size stay
    /// unknown. The table is saved, as a finished scan's would be.
    func replaceFromCatalog(sizes: [String: Int64], libraryCount: Int) {
        var fresh = AssetSizeTable(kind: table.kind)
        fresh.reserveCapacity(sizes.count)
        fresh.merge(sizes)
        fresh.libraryCount = libraryCount
        fresh.scannedThrough = libraryCount
        fresh.isComplete = true
        table = fresh
        save()
    }

    /// Sizes the browser has seen, for items the table doesn't have.
    func addSamples(_ sizes: [String: Int64]) {
        guard !table.isComplete, !sizes.isEmpty else { return }
        table.mergeMissing(sizes)
    }

    func estimate(for selection: LibrarySelection, libraryCount: Int?) -> StorageEstimate? {
        table.estimate(for: selection, libraryCount: libraryCount ?? table.libraryCount)
    }

    // MARK: - Scanning

    /// The kinds of scan a size table can need.
    enum ScanPlan: Equatable, Sendable {
        /// Nothing to do: the table is complete and the library's size is unknown.
        case upToDate
        /// Walk the library from this offset.
        case walk(from: Int)
        /// Size only the items added since the table was complete (new items are inserted at rank 0).
        case topUp
    }

    /// What a scan should do for a library of `libraryCount` items.
    ///
    /// A walk in progress resumes where it stopped, unless the library's size has changed since it
    /// started: items then sit at other offsets, so it starts over from the beginning. A complete
    /// table whose library grew or kept its size gets a top-up, since new items are inserted at rank
    /// 0 and the top-up catches a library that gained one item and lost another. One that shrank is
    /// walked again from the start. With no walk to resume, an incomplete table is walked from the start.
    func scanPlan(libraryCount: Int?) -> ScanPlan {
        if let walk = table.walk {
            if !walk.isValid || libraryCount.map({ walk.libraryCount >= 0 && $0 != walk.libraryCount }) == true {
                return .walk(from: 0)
            }
            if let libraryCount, table.scannedThrough >= libraryCount {
                // Stopped at the very end; walk the last page again to finish.
                return .walk(from: max(walk.start, libraryCount - 100))
            }
            return .walk(from: table.scannedThrough)
        }
        guard table.isComplete else { return .walk(from: 0) }
        guard let libraryCount else { return .upToDate }
        if libraryCount < table.libraryCount {
            return .walk(from: 0)
        }
        return .topUp
    }

    /// Sizes the items added to a complete table: pages from the newest item down, until a run of
    /// `overlap` items the table already has shows where the new ones end. Returns true when that
    /// happens or the library ends; the table is then complete for `libraryCount`. Returns false
    /// after `cap` items without such a run; the table is then incomplete, with a walk from the
    /// start to finish it.
    func topUp(fetcher: any ICloudPageFetching, libraryCount: Int, overlap: Int = 200, cap: Int = 5_000) async throws -> Bool {
        let pageSize = 200
        var offset = 0
        var scanned = 0
        var run = 0
        while scanned < cap {
            let limit = min(pageSize, cap - scanned)
            let page = try await fetcher.assets(offset: offset, limit: limit)
            for asset in page {
                scanned += 1
                run = table.size(of: asset.id) == nil ? 0 : run + 1
                if let bytes = asset.bytes {
                    table.set(bytes, for: asset.id)
                }
                if run >= overlap {
                    return finishTopUp(libraryCount: libraryCount)
                }
            }
            offset += page.count
            if page.count < limit || offset >= libraryCount {
                return finishTopUp(libraryCount: libraryCount)
            }
        }
        table.isComplete = false
        table.scannedThrough = 0
        table.walk = AssetSizeTable.Walk(start: 0, libraryCount: libraryCount)
        save()
        return false
    }

    private func finishTopUp(libraryCount: Int) -> Bool {
        table.libraryCount = libraryCount
        table.scannedThrough = libraryCount
        table.isComplete = true
        save()
        return true
    }

    /// Starts walking from `start`: resumes the walk in progress when `start` continues it, and
    /// begins a new one (forgetting what the old one saw) otherwise.
    func beginScan(from start: Int, libraryCount: Int? = nil) {
        let resumes = table.walk.map { walk in
            walk.isValid && start >= walk.start && start <= table.scannedThrough
                && (libraryCount == nil || walk.libraryCount < 0 || libraryCount == walk.libraryCount)
        } ?? false
        if !resumes {
            table.walk = AssetSizeTable.Walk(start: start, libraryCount: libraryCount ?? -1)
        }
        table.isComplete = false
        table.scannedThrough = start
    }

    /// Records a page of the walk: the sizes of its items, the IDs of its items without a size, how
    /// far the walk has come, and the library's size as the bridge reported it.
    func recordScan(sizes: [String: Int64], unsized: [String] = [], scannedThrough: Int, libraryCount: Int?) {
        table.merge(sizes)
        table.scannedThrough = scannedThrough
        if let libraryCount {
            table.libraryCount = libraryCount
            noteWalkLibraryCount(libraryCount)
        }
        table.walk?.seen.formUnion(sizes.keys)
        table.walk?.seen.formUnion(unsized)
        unsavedItems += sizes.count + unsized.count
        if unsavedItems >= Self.saveInterval {
            save()
        }
    }

    /// Ends a scan; `complete` when the bridge reached the end of the library. Returns whether the
    /// table is now complete. A walk that reached the end completes the table only if the library
    /// kept its size throughout and, for a walk from the start, every item was seen; it then drops
    /// items the walk didn't see (deleted since). Otherwise the next scan starts over. An unfinished
    /// walk is kept, with what it has seen, for the next scan to resume.
    @discardableResult
    func endScan(complete: Bool, libraryCount: Int?) -> Bool {
        if let libraryCount {
            noteWalkLibraryCount(libraryCount)
        }
        if complete, let walk = table.walk {
            let count = walk.libraryCount >= 0 ? walk.libraryCount : (libraryCount ?? table.libraryCount)
            if walk.isValid, walk.start > 0 || walk.seen.count >= count {
                if walk.start == 0 {
                    table.keepOnly(walk.seen)
                }
                table.libraryCount = count
                table.scannedThrough = count
                table.isComplete = true
                table.walk = nil
            } else {
                // The library changed under the walk: start over from the beginning next time.
                table.walk = nil
                table.scannedThrough = 0
            }
        }
        save()
        return table.isComplete
    }

    /// A walk whose pages report a different library size than it started with may have skipped items.
    private func noteWalkLibraryCount(_ count: Int) {
        guard var walk = table.walk else { return }
        if walk.libraryCount < 0 {
            walk.libraryCount = count
        } else if walk.libraryCount != count {
            walk.isValid = false
        }
        table.walk = walk
    }

    func save() {
        unsavedItems = 0
        guard let store, let account, maySave() else { return }
        try? store.save(table, account: account)
    }
}

extension AssetSizeTable {
    /// The sizes by ID, for merging into another table.
    var sizesSnapshot: [String: Int64] { sizes }
}

/// Fills an `AssetSizeIndex` from the bridge's `stats` walk.
enum ICloudSizeScanner {
    enum Outcome: Sendable {
        /// The table is up to date.
        case complete
        /// The walk stopped early: cancelled, or the bridge yielded to a download. Resume later.
        case interrupted
        case failed(Error)
    }

    /// Scans from where the table left off. `onProgress` is called at most every `progressInterval`.
    /// With a `catalog` (R12d), a trusted catalog answers first, with no `stats` walk. Otherwise the walk feeds the
    /// catalog as it goes, and a walk from the start that completes marks a full walk in the catalog.
    static func scan(
        bridge: ICloudBridge,
        index: AssetSizeIndex,
        libraryCount: Int?,
        catalog: ICloudCatalog? = nil,
        progressInterval: Duration = .seconds(2),
        onProgress: @escaping @Sendable () async -> Void
    ) async -> Outcome {
        if let catalog, let libraryCount,
           let sizes = await trustedCatalogSizes(bridge: bridge, catalog: catalog) {
            await index.replaceFromCatalog(sizes: sizes, libraryCount: libraryCount)
            return .complete
        }
        let start: Int
        switch await index.scanPlan(libraryCount: libraryCount) {
        case .upToDate:
            return .complete
        case .walk(let from):
            start = from
        case .topUp:
            guard let libraryCount else { return .complete }
            do {
                if try await index.topUp(fetcher: ICloudBridgeFetcher(bridge: bridge), libraryCount: libraryCount) {
                    return .complete
                }
            } catch {
                return error is CancellationError || (error as? ICloudError) == .interrupted ? .interrupted : .failed(error)
            }
            // Too many new items to top up: walk the whole library, as an incomplete table does.
            start = 0
        }
        await index.beginScan(from: start, libraryCount: libraryCount)
        let walkStart = Date()
        if start == 0, let catalog {
            try? await catalog.beginFullWalk(at: walkStart)
        }
        var lastReport = ContinuousClock.now
        do {
            for try await message in try await bridge.stats(offset: start) {
                switch message.event {
                case "statsProgress":
                    await index.recordScan(
                        sizes: message.sizes ?? [:],
                        unsized: message.unsized ?? [],
                        scannedThrough: start + (message.done ?? 0),
                        libraryCount: message.total
                    )
                    if let catalog {
                        await feed(catalog: catalog, message: message)
                    }
                    if lastReport.duration(to: .now) >= progressInterval {
                        lastReport = .now
                        await onProgress()
                    }
                case "stats":
                    if start == 0, message.complete == true, let catalog {
                        await completeCatalogWalk(catalog: catalog, startedAt: walkStart, libraryCount: message.total)
                    }
                    // A walk the library changed under ends incomplete, and the next one starts over.
                    let complete = await index.endScan(complete: message.complete == true, libraryCount: message.total)
                    return complete ? .complete : .interrupted
                default:
                    break
                }
            }
            await index.endScan(complete: false, libraryCount: nil)
            return .interrupted
        } catch {
            await index.endScan(complete: false, libraryCount: nil)
            return error is CancellationError || (error as? ICloudError) == .interrupted ? .interrupted : .failed(error)
        }
    }

    /// The catalog's sizes when the catalog is trusted for this library (R12d), after a top-up in this call. Nil when it
    /// isn't, or when the top-up or the check fails: the caller then walks as before.
    private static func trustedCatalogSizes(bridge: ICloudBridge, catalog: ICloudCatalog) async -> [String: Int64]? {
        do {
            let trusted = try await CatalogTopUp.trustedAfterTopUp(
                fetcher: ICloudBridgeFetcher(bridge: bridge),
                catalog: catalog,
                recentlyDeleted: ICloudBridgeFetcher(bridge: bridge, album: .recentlyDeleted)
            )
            guard trusted else { return nil }
            return try await catalog.sizes().sizes
        } catch {
            return nil
        }
    }

    /// Feeds one `stats` page to the catalog: the export sizes of its items, and the items themselves (R12d). Catalog
    /// errors are ignored: they never stop the walk.
    private static func feed(catalog: ICloudCatalog, message: ICloudBridgeMessage) async {
        try? await catalog.updateBytes(message.sizes ?? [:])
        let items = message.items ?? []
        if !items.isEmpty {
            try? await catalog.upsert(CatalogRows.rows(for: items, libraryCount: message.total ?? 0))
        }
    }

    /// A `stats` walk from the start that reached the end: prunes what it didn't see, if it saw enough (R12d).
    private static func completeCatalogWalk(catalog: ICloudCatalog, startedAt: Date, libraryCount: Int?) async {
        guard let libraryCount, let status = try? await catalog.status() else { return }
        _ = try? await catalog.completeFullWalk(
            startedAt: startedAt, libraryCount: libraryCount, unlistedCount: status.unlistedCount
        )
    }
}
