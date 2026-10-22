import Foundation
import Photos

/// Export New Photos from a date range: the photos taken within it, which the owner picks, plus what the sheet
/// shows about the backup: when the last export ran and the newest photo it wrote. The iCloud walks are pure and
/// tested with a fake fetcher. The Photos library parts are thin wrappers over PhotoKit.
enum ExportSince {
    /// The most photos the iCloud walk lists before it stops and says there are more.
    static let iCloudLimit = 20_000

    /// The newest photo the backup wrote: its file name and when it was taken (the file's modification date).
    struct ExportedPhoto: Equatable, Sendable {
        let fileName: String
        let taken: Date
    }

    /// iCloud: walks pages newest-first by `added` from rank 0. Returns the ids (with ranks, for rank hints) of items
    /// taken in `from...to`, by `created ?? added`. Stops at the first item whose `added` is earlier than `from`: a
    /// photo can't be taken after it was added, so nothing later in the walk was taken in range. Items with nil
    /// `added` don't stop the walk. `limit` caps the result: past it, `isAtLeast` is true.
    static func iCloudItems(takenFrom from: Date, to: Date, fetcher: any ICloudPageFetching, pageSize: Int = 200,
                            limit: Int = iCloudLimit) async throws -> (items: [String: Int], isAtLeast: Bool)
    {
        var items: [String: Int] = [:]
        var offset = 0
        while true {
            try Task.checkCancellation()
            let page = try await fetcher.assets(offset: offset, limit: pageSize)
            if page.isEmpty {
                return (items, false)
            }
            for (index, asset) in page.enumerated() {
                if let added = asset.added, added < from {
                    return (items, false)
                }
                guard let when = asset.created ?? asset.added, when >= from, when <= to else {
                    continue
                }
                // The item past the limit proves there are more than `limit` of them.
                if items.count == limit {
                    return (items, true)
                }
                items[asset.id] = offset + index
            }
            offset += page.count
        }
    }

    /// iCloud: the newest backed-up item's date: walks from rank 0 until the first id in `known`; returns its
    /// `added ?? created`. Gives up (nil) after `scanLimit` items.
    static func iCloudSuggestedDate(known: Set<String>, fetcher: any ICloudPageFetching, pageSize: Int = 200,
                                    scanLimit: Int = 5_000) async throws -> Date? {
        var offset = 0
        while offset < scanLimit {
            try Task.checkCancellation()
            let page = try await fetcher.assets(offset: offset, limit: pageSize)
            if page.isEmpty {
                return nil
            }
            for (index, asset) in page.enumerated() where offset + index < scanLimit {
                if known.contains(asset.id), let when = asset.added ?? asset.created {
                    return when
                }
            }
            offset += page.count
        }
        return nil
    }

    /// Photos library: the assets taken in `from...to`, keyed by local identifier. The value is always 0, as the
    /// Photos library has no ranks.
    static func photosLibraryItems(takenFrom from: Date, to: Date) -> [String: Int] {
        let options = BackupFiles.libraryFetchOptions()
        options.predicate = NSPredicate(format: "creationDate >= %@ AND creationDate <= %@", from as NSDate, to as NSDate)
        var items: [String: Int] = [:]
        PHAsset.fetchAssets(with: options).enumerateObjects { asset, _, _ in
            items[asset.localIdentifier] = 0
        }
        return items
    }

    /// Photos library: the creation date of the newest asset already in the backup. Gives up (nil) after `scanLimit`.
    static func photosLibrarySuggestedDate(exported: Set<String>, scanLimit: Int = 5_000) -> Date? {
        let options = BackupFiles.libraryFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        let assets = PHAsset.fetchAssets(with: options)
        for index in 0..<min(assets.count, scanLimit) {
            let asset = assets.object(at: index)
            if exported.contains(asset.localIdentifier) {
                return asset.creationDate
            }
        }
        return nil
    }

    /// When the last export ran: the end of the newest session that exported files and didn't stop while running.
    /// Completed, completed with failures, cancelled and interrupted sessions all count. Nil when there is none.
    static func lastExport(in store: SessionStore) -> Date? {
        let finished: Set<ExportSession.Status> = [.completed, .completedWithFailures, .cancelled, .interrupted]
        return store.list()
            .filter { $0.counts.exported > 0 && finished.contains($0.result.status) }
            .map { $0.endedAt ?? $0.updatedAt }
            .max()
    }

    /// The newest photo the backup wrote: among the last `limit` records of the manifest (the journal is append-only,
    /// so its tail holds the latest exports), the file with the newest modification date. icloudpd and the PhotoKit
    /// export set that date to when the photo was taken. Nil when no recorded file can be read.
    static func newestExportedPhoto(in destination: URL, limit: Int = 500) -> ExportedPhoto? {
        let records = ExportManifest.recentRecords(in: destination, limit: limit)
        // Each folder is listed once, in one bulk pass, for the modification dates. A lookup per file is slow on exFAT.
        var datesByFolder: [String: [String: Double]] = [:]
        for record in records {
            for path in record.paths where ExportManifest.isSafeRelativePath(path) {
                let folder = (path as NSString).deletingLastPathComponent
                if datesByFolder[folder] == nil {
                    datesByFolder[folder] = modificationDates(inFolder: folder, in: destination)
                }
            }
        }

        var newest: ExportedPhoto?
        for record in records {
            for path in record.paths where ExportManifest.isSafeRelativePath(path) {
                let folder = (path as NSString).deletingLastPathComponent
                let name = (path as NSString).lastPathComponent
                guard let modified = datesByFolder[folder]?[name] else { continue }
                let taken = Date(timeIntervalSince1970: modified)
                if let current = newest, current.taken >= taken {
                    continue
                }
                newest = ExportedPhoto(fileName: name, taken: taken)
            }
        }
        return newest
    }

    /// The modification time of each entry in `folder` (a relative path, `""` for the destination), by name. Empty
    /// when the folder can't be listed, so its files are skipped as missing.
    private static func modificationDates(inFolder folder: String, in destination: URL) -> [String: Double] {
        let url = folder.isEmpty ? destination : destination.appending(path: folder, directoryHint: .isDirectory)
        guard let entries = try? BulkDirectoryLister.list(url) else { return [:] }
        return Dictionary(entries.map { ($0.name, $0.modified) }, uniquingKeysWith: { first, _ in first })
    }
}
