import Foundation

/// The duplicates library: every photo with more than one copy on the drive, from both kinds of drive duplicates.
/// Each photo's original is the copy kept, the first one saved; its copies are the ones moved to the Trash. Built from
/// a scan's results, so it reads no files.
struct DuplicateLibrary: Equatable, Sendable {
    /// One saved file on the drive, shown as a thumbnail. Its path is relative to the destination and unique there.
    struct Tile: Identifiable, Equatable, Sendable {
        let path: String

        var id: String { path }
        var fileName: String { (path as NSString).lastPathComponent }
        /// The folder relative to the destination; empty for files at the top.
        var folder: String { (path as NSString).deletingLastPathComponent }
        var isVideo: Bool { ["mov", "mp4", "m4v"].contains((path as NSString).pathExtension.lowercased()) }
    }

    /// One photo: the original, and the copies that the removal moves to the Trash.
    struct Photo: Identifiable, Equatable, Sendable {
        /// The group's ID, or the item's record key for extra copies. The user's exclusions are keyed by it.
        let id: String
        let original: Tile
        let copies: [Tile]
        /// The bytes of the copies, which the Trash frees.
        let copyBytes: Int64
    }

    /// Counts over some photos. `copies` are the copies to remove, not the originals kept.
    struct Totals: Equatable, Sendable {
        var photos = 0
        var copies = 0
        var bytes: Int64 = 0
    }

    /// Largest reclaimable size first.
    let photos: [Photo]

    init(groups: [DuplicateFinder.Group], extraCopies: [DuplicateFinder.ExtraCopy]) {
        var photos = groups.map { group in
            Photo(
                id: group.id,
                original: Tile(path: group.keeper.mediaPaths[0]),
                copies: group.duplicates.map { Tile(path: $0.mediaPaths[0]) },
                copyBytes: group.duplicateBytes
            )
        }

        // An item with extra copies has one original, the copy in the layout, and one folder per extra copy.
        for (id, copies) in Dictionary(grouping: extraCopies, by: \.recordID) {
            let sorted = copies.sorted { $0.folder < $1.folder }
            photos.append(Photo(
                id: id,
                original: Tile(path: sorted[0].keeperPaths[0]),
                copies: sorted.map { Tile(path: $0.mediaPaths[0]) },
                copyBytes: sorted.reduce(0) { $0 + $1.byteCount }
            ))
        }

        self.photos = photos.sorted { a, b in
            a.copyBytes != b.copyBytes ? a.copyBytes > b.copyBytes : a.id < b.id
        }
    }

    /// The copies of the photos not in `excluded`, which are the ones the removal moves to the Trash. Pass no IDs for
    /// the whole library.
    func totals(excluding excluded: Set<String> = []) -> Totals {
        photos.reduce(into: Totals()) { totals, photo in
            guard !excluded.contains(photo.id) else { return }
            totals.photos += 1
            totals.copies += photo.copies.count
            totals.bytes += photo.copyBytes
        }
    }
}
