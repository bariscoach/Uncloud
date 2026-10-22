import Foundation
import os

/// The process-wide local catalogs, one per Apple ID's library zone (R12c).
enum ICloudCatalogStore {
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Uncloud", category: "catalog")
    private static let lock = NSLock()
    nonisolated(unsafe) private static var catalogs: [String: ICloudCatalog] = [:]

    /// The catalog of an Apple ID, opened on first use. Nil when it can't be opened: the callers then keep their
    /// network paths.
    static func shared(appleID: String) -> ICloudCatalog? {
        let account = ExportSession.accountHash(appleID: appleID)
        return lock.withLock {
            if let catalog = catalogs[account] {
                return catalog
            }
            do {
                let catalog = try ICloudCatalog.open(account: account)
                catalogs[account] = catalog
                return catalog
            } catch {
                logger.error("catalog: could not open (\(String(describing: error), privacy: .public))")
                return nil
            }
        }
    }
}

/// Catalog rows for a page of listed items (R12c).
enum CatalogRows {
    /// The rows for `items`, which start at `offset` (rank 0 is the newest). `libraryCount` is the count the page was
    /// read against, and is never below the rank the page reaches.
    static func rows(for items: [ICloudAsset], offset: Int, libraryCount: Int) -> [ICloudCatalog.Row] {
        let rankCount = max(libraryCount, offset + items.count)
        let seenAt = Date()
        return items.enumerated().map { index, asset in
            row(asset, rank: offset + index, rankCount: rankCount, seenAt: seenAt)
        }
    }

    /// The rows for bridge items that carry their ranks (a `stats` page). Items without a rank are left out.
    static func rows(for items: [ICloudBridgeMessage.Item], libraryCount: Int) -> [ICloudCatalog.Row] {
        let seenAt = Date()
        return items.compactMap { item in
            guard let rank = item.rank else { return nil }
            return row(item.asset, rank: rank, rankCount: max(libraryCount, rank + 1), seenAt: seenAt)
        }
    }

    static func row(_ asset: ICloudAsset, rank: Int, rankCount: Int, seenAt: Date) -> ICloudCatalog.Row {
        ICloudCatalog.Row(
            id: asset.id,
            master: asset.master,
            added: asset.added,
            created: asset.created,
            filename: asset.filename,
            isVideo: asset.isVideo,
            size: nil,
            bytes: asset.bytes,
            latitude: asset.latitude,
            longitude: asset.longitude,
            timeZoneOffset: asset.timeZoneOffset,
            rank: rank,
            rankCount: rankCount,
            seenAt: seenAt
        )
    }
}

/// Wraps the bridge's page fetcher so that every page it returns is also written to the local catalog (R12c). The pages
/// pass through unchanged. A catalog error is logged and ignored, so the catalog never fails a page. Recently Deleted is
/// never fed: wrap only the library.
struct CatalogFeedingFetcher: ICloudPageFetching {
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Uncloud", category: "catalog")

    let base: any ICloudPageFetching
    /// Nil when the catalog couldn't be opened: pages then pass through as before.
    let catalog: ICloudCatalog?

    func count() async throws -> Int {
        let count = try await base.count()
        if let catalog {
            do {
                // Keep the unlisted count the catalog already has: this call doesn't know it.
                let unlisted = try await catalog.status().unlistedCount
                try await catalog.noteLibraryCount(count, unlisted: unlisted)
            } catch {
                Self.logger.error("catalog: count not kept (\(String(describing: error), privacy: .public))")
            }
        }
        return count
    }

    func assets(offset: Int, limit: Int) async throws -> [ICloudAsset] {
        let items = try await base.assets(offset: offset, limit: limit)
        guard let catalog, !items.isEmpty else { return items }
        do {
            let libraryCount = try await catalog.status().libraryCount ?? 0
            try await catalog.upsert(CatalogRows.rows(for: items, offset: offset, libraryCount: libraryCount))
        } catch {
            Self.logger.error("catalog: page at \(offset) not kept (\(String(describing: error), privacy: .public))")
        }
        return items
    }
}
