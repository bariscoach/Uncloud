import Foundation
import Photos

/// Export New Photos from a date: the photos added to the library since the date the owner picks, and the date of the
/// newest photo already in the backup, which the sheet suggests. The iCloud walks are pure and tested with a fake
/// fetcher. The Photos library parts are thin wrappers over PhotoKit.
enum ExportSince {
    /// The most photos the iCloud walk lists before it stops and says there are more.
    static let iCloudLimit = 20_000

    /// iCloud: walks pages newest-first from rank 0. Returns the ids (with ranks, for rank hints) of items whose
    /// `added ?? created` is >= `date`. Stops at the first item whose `added` is earlier than `date` (the walk is in
    /// added order). Items with nil `added` use `created` for the comparison and don't stop the walk.
    /// `limit` caps the result: past it, `isAtLeast` is true.
    static func iCloudItems(since date: Date, fetcher: any ICloudPageFetching, pageSize: Int = 200, limit: Int = iCloudLimit)
        async throws -> (items: [String: Int], isAtLeast: Bool)
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
                if let added = asset.added, added < date {
                    return (items, false)
                }
                guard let when = asset.added ?? asset.created, when >= date else {
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

    /// Photos library: the assets created on or after `date`, keyed by local identifier. The value is always 0, as
    /// the Photos library has no ranks.
    static func photosLibraryItems(since date: Date) -> [String: Int] {
        let options = BackupFiles.libraryFetchOptions()
        options.predicate = NSPredicate(format: "creationDate >= %@", date as NSDate)
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
}
