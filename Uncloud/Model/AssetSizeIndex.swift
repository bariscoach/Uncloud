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

    /// Sizes the browser has seen, for items the table doesn't have.
    func addSamples(_ sizes: [String: Int64]) {
        guard !table.isComplete, !sizes.isEmpty else { return }
        table.mergeMissing(sizes)
    }

    func estimate(for selection: LibrarySelection, libraryCount: Int?) -> StorageEstimate? {
        table.estimate(for: selection, libraryCount: libraryCount ?? table.libraryCount)
    }

    // MARK: - Scanning

    /// Where a scan should start for a library of `libraryCount` items, or nil when the table is up to date.
    ///
    /// A walk in progress resumes where it stopped, unless the library's size has changed since it
    /// started: items then sit at other offsets, so it starts over from the beginning. A library that
    /// grew since a complete walk is walked from just before its old end (new items come last in
    /// icloudpd's order); one that shrank is walked again from the start. With no walk to resume,
    /// an incomplete table is walked from the start.
    func scanStart(libraryCount: Int?) -> Int? {
        if let walk = table.walk {
            if !walk.isValid || libraryCount.map({ walk.libraryCount >= 0 && $0 != walk.libraryCount }) == true {
                return 0
            }
            if let libraryCount, table.scannedThrough >= libraryCount {
                // Stopped at the very end; walk the last page again to finish.
                return max(walk.start, libraryCount - 100)
            }
            return table.scannedThrough
        }
        guard table.isComplete else { return 0 }
        guard let libraryCount, libraryCount != table.libraryCount else { return nil }
        if libraryCount > table.libraryCount {
            return max(0, table.libraryCount - 100)
        }
        return 0
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
    static func scan(
        bridge: ICloudBridge,
        index: AssetSizeIndex,
        libraryCount: Int?,
        progressInterval: Duration = .seconds(2),
        onProgress: @escaping @Sendable () async -> Void
    ) async -> Outcome {
        guard let start = await index.scanStart(libraryCount: libraryCount) else { return .complete }
        await index.beginScan(from: start, libraryCount: libraryCount)
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
                    if lastReport.duration(to: .now) >= progressInterval {
                        lastReport = .now
                        await onProgress()
                    }
                case "stats":
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
}
