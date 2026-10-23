import Foundation
import Photos

/// Export Photos by Date: the photos taken within a date range the owner picks. The presets, the end of the range
/// and the count's wording are pure and tested. The iCloud walks are tested with a fake fetcher, and the Photos
/// library parts are thin wrappers over PhotoKit.
enum ExportSince {
    /// The most photos the iCloud walk lists before it stops and says there are more.
    static let iCloudLimit = 20_000

    /// The quick ranges the sheet offers. `custom` keeps whatever dates are set.
    enum DatePreset: CaseIterable, Sendable {
        case last7Days
        case last30Days
        case thisYear
        case custom

        var title: String {
            switch self {
            case .last7Days: "Last 7 Days"
            case .last30Days: "Last 30 Days"
            case .thisYear: "This Year"
            case .custom: "Custom"
            }
        }

        /// The first and last day the preset picks, both at the start of their day. "Last 7 Days" and "Last 30 Days"
        /// cover that many calendar days, today included. Nil for `custom`, which keeps the dates.
        func days(now: Date, calendar: Calendar = .current) -> (from: Date, to: Date)? {
            let today = calendar.startOfDay(for: now)
            switch self {
            case .last7Days:
                return (calendar.date(byAdding: .day, value: -6, to: today) ?? today, today)
            case .last30Days:
                return (calendar.date(byAdding: .day, value: -29, to: today) ?? today, today)
            case .thisYear:
                let start = calendar.date(from: calendar.dateComponents([.year], from: now)) ?? today
                return (calendar.startOfDay(for: start), today)
            case .custom:
                return nil
            }
        }
    }

    /// The last second of `day`'s calendar day (23:59:59), so a range that ends on it takes in the whole day.
    static func endOfDay(_ day: Date, calendar: Calendar = .current) -> Date {
        let start = calendar.startOfDay(for: day)
        let nextStart = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
        return nextStart.addingTimeInterval(-1)
    }

    /// The count line once a range has been counted: "312 photos to export · 4 already backed up". `toExport` are the
    /// photos in the range that aren't backed up; `backedUp` are the ones that are. `isAtLeast` means the walk stopped
    /// at `iCloudLimit`.
    static func countText(toExport: Int, backedUp: Int, isAtLeast: Bool) -> String {
        if isAtLeast {
            return "More than \(iCloudLimit.formatted()) photos"
        }
        if toExport == 0 {
            guard backedUp > 0 else { return "No photos taken in this range" }
            return "All \(photos(backedUp)) \(backedUp == 1 ? "is" : "are") already backed up"
        }
        let text = "\(photos(toExport)) to export"
        return backedUp > 0 ? "\(text) · \(backedUp.formatted()) already backed up" : text
    }

    /// "1 photo" or "312 photos".
    private static func photos(_ count: Int) -> String {
        "\(count.formatted()) \(count == 1 ? "photo" : "photos")"
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

    /// iCloud, from a trusted catalog (R12e): the items taken in `from...to`, with the rank hints as values, read from
    /// the catalog's rows. The caller has checked the catalog (`CatalogTopUp.trustedAfterTopUp`); nothing is fetched.
    static func iCloudItems(takenFrom from: Date, to: Date, catalog: ICloudCatalog,
                            limit: Int = iCloudLimit) async throws -> (items: [String: Int], isAtLeast: Bool)
    {
        let (rows, isAtLeast) = try await catalog.rows(takenFrom: from, to: to, limit: limit)
        let libraryCount = try await catalog.status().libraryCount ?? 0
        var items: [String: Int] = [:]
        for row in rows {
            items[row.id] = row.rank + max(0, libraryCount - row.rankCount)
        }
        return (items, isAtLeast)
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
}
