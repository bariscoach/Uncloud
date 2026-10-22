import Foundation

/// Brings the local catalog up to date before a consumer answers from it (R12c; staleness rules 3 and 4 in the
/// wave 2 plan). It pages the library from rank 0 and writes what it sees, until `overlap` known items come in a row,
/// which means the catalog meets the library. Then it removes the IDs of Recently Deleted from the catalog.
enum CatalogTopUp {
    enum Result: Equatable, Sendable {
        /// The catalog meets a run of known items. `scanned` is how many items were looked at.
        case current(scanned: Int)
        /// No run of known items within `cap` items: the consumer keeps its network path.
        case tooFar
    }

    /// - fetcher: the library's pages (the bridge, not a feeding fetcher: this run writes the pages itself, after it has
    ///   checked which items were known).
    /// - recentlyDeleted: the Recently Deleted album, read for its IDs (at most 2,000 items).
    static func run(
        fetcher: any ICloudPageFetching,
        catalog: ICloudCatalog,
        recentlyDeleted: any ICloudPageFetching,
        pageSize: Int = 200,
        overlap: Int = 200,
        cap: Int = 5_000
    ) async throws -> Result {
        let libraryCount = try await fetcher.count()
        let unlisted = try await catalog.status().unlistedCount
        try await catalog.noteLibraryCount(libraryCount, unlisted: unlisted)

        var scanned = 0
        var knownInRow = 0
        var reachedCurrent = false
        while scanned < cap, !reachedCurrent {
            let limit = min(pageSize, cap - scanned)
            let items = try await fetcher.assets(offset: scanned, limit: limit)
            if items.isEmpty {
                // The end of the library: every item has been seen, so the catalog is complete.
                reachedCurrent = true
                break
            }
            let known = try await catalog.rows(ids: items.map(\.id))
            for item in items {
                if known[item.id] != nil {
                    knownInRow += 1
                    if knownInRow >= overlap {
                        reachedCurrent = true
                        break
                    }
                } else {
                    knownInRow = 0
                }
            }
            try await catalog.upsert(CatalogRows.rows(for: items, offset: scanned, libraryCount: libraryCount))
            scanned += items.count
        }

        guard reachedCurrent else {
            return .tooFar
        }
        try await removeRecentlyDeleted(from: catalog, reading: recentlyDeleted)
        try await catalog.noteTopUp(at: Date())
        return .current(scanned: scanned)
    }

    /// Deletes the IDs of Recently Deleted's items (at most 2,000) from the catalog.
    private static func removeRecentlyDeleted(from catalog: ICloudCatalog, reading album: any ICloudPageFetching) async throws {
        var ids: [String] = []
        var offset = 0
        while offset < 2_000 {
            let page = try await album.assets(offset: offset, limit: 200)
            if page.isEmpty { break }
            ids += page.map(\.id)
            offset += page.count
            if page.count < 200 { break }
        }
        try await catalog.remove(ids: ids)
    }
}
