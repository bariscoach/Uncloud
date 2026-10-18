import Foundation

/// Finds items on the destination that were saved more than once, and moves the extra copies to the Trash.
/// Works from the manifest's records and checksums, so finding groups reads no files. Only the destination
/// changes: the photo library and iCloud are never touched.
enum DuplicateFinder {
    /// One saved item on the drive, which can be kept or moved to the Trash.
    struct Copy: Identifiable, Equatable, Sendable {
        /// The record's key: `icloud-id:<asset>` for iCloud items, the local identifier for Photos library items.
        let id: String
        /// Every recorded path, sidecars included.
        let paths: [String]
        /// The photo and movie paths, without `.xmp` sidecars. Never empty.
        let mediaPaths: [String]
        /// The recorded SHA-256 of each media path.
        let checksums: [String: String]
        /// The size of every recorded file, in bytes; a file that can't be read counts as zero.
        let byteCount: Int64
        /// The line of the record's first export in `exported.tsv`. Earlier exports rank first as keepers.
        let exportOrder: Int
    }

    /// Items with the same files in the same folder. One copy is kept and the others are duplicates.
    struct Group: Identifiable, Equatable, Sendable {
        let id: String
        /// Every copy, the best keeper first.
        let copies: [Copy]
        /// The copy to keep. Starts as the best keeper; the user can choose another.
        var keeperID: String

        var keeper: Copy {
            copies.first { $0.id == keeperID } ?? copies[0]
        }

        var duplicates: [Copy] {
            copies.filter { $0.id != keeperID }
        }

        var duplicateBytes: Int64 {
            duplicates.reduce(0) { $0 + $1.byteCount }
        }
    }

    struct Result: Equatable, Sendable {
        /// Largest reclaimable size first.
        var groups: [Group]
        /// Items that couldn't be compared: a media file has no recorded checksum, or the record is path-only or partial.
        var notCheckedCount: Int
    }

    struct RemovalResult: Equatable, Sendable {
        /// Duplicates whose files are all in the Trash and whose records now point at their keeper.
        var removedCopies = 0
        var removedBytes: Int64 = 0
        /// Duplicates left in place because a file changed, is missing, or isn't inside the destination.
        var skippedCopies = 0
        /// Duplicates where a file couldn't be moved to the Trash. Files already moved stay moved.
        var failedCopies = 0
    }

    /// Groups the items that have identical media files in the same folder.
    /// - records: key to relative paths, from `ExportManifest.records(in:)`.
    /// - checksums: relative path to SHA-256, from `ExportManifest.checksums(in:)`.
    /// - sizes: relative path to size in bytes. Missing paths count as zero.
    /// - exportOrder: key to the line of its first export. Missing keys rank last.
    static func findGroups(
        records: [String: [String]],
        checksums: [String: String],
        sizes: [String: Int64],
        exportOrder: [String: Int] = [:]
    ) -> Result {
        var notChecked = 0
        let idPaths = Set(records.filter { $0.key.hasPrefix(ExportManifest.iCloudIDPrefix) }.values.joined())
        let idAssets = Set(records.keys.compactMap { key -> String? in
            key.hasPrefix(ExportManifest.iCloudIDPrefix) ? String(key.dropFirst(ExportManifest.iCloudIDPrefix.count)) : nil
        })

        // Path-only and partial records aren't items. They're only counted, unless an ID record covers the same files.
        var items: [(key: String, paths: [String])] = []
        for (key, paths) in records.sorted(by: { $0.key < $1.key }) {
            if key.hasPrefix(ExportManifest.iCloudPathPrefix) {
                if !paths.contains(where: idPaths.contains) { notChecked += 1 }
            } else if key.hasPrefix(ExportManifest.iCloudPartialPrefix) {
                if !idAssets.contains(String(key.dropFirst(ExportManifest.iCloudPartialPrefix.count))) { notChecked += 1 }
            } else {
                items.append((key, paths))
            }
        }

        // A file listed by two items is one file, not two copies, so those items are left out.
        var owners: [String: Int] = [:]
        for item in items {
            for path in Set(item.paths) {
                owners[path, default: 0] += 1
            }
        }

        var copiesByFingerprint: [String: [Copy]] = [:]
        for item in items {
            guard let firstMedia = item.paths.first(where: { !isSidecar($0) }) else {
                notChecked += 1
                continue
            }
            guard !item.paths.contains(where: { owners[$0, default: 0] > 1 }) else { continue }

            let media = item.paths.filter { !isSidecar($0) }
            var recorded: [String: String] = [:]
            for path in media {
                guard let digest = checksums[path] else { break }
                recorded[path] = digest
            }
            guard recorded.count == Set(media).count else {
                notChecked += 1
                continue
            }

            // Only copies in the same folder match. The same photo in two album folders is in both albums on
            // purpose, so removing one would take it out of an album. A true duplicate import lands in the same
            // month or flat folder, so this also keeps the layouts apart.
            let folder = (firstMedia as NSString).deletingLastPathComponent
            // Matching is on whole items: the sorted digests of every media file, so a Live Photo only matches a Live Photo.
            let fingerprint = media.compactMap { recorded[$0] }.sorted().joined(separator: ",")
            let copy = Copy(
                id: item.key,
                paths: item.paths,
                mediaPaths: media,
                checksums: recorded,
                byteCount: item.paths.reduce(0) { $0 + (sizes[$1] ?? 0) },
                exportOrder: exportOrder[item.key] ?? Int.max
            )
            copiesByFingerprint["\(folder)|\(fingerprint)", default: []].append(copy)
        }

        let groups = copiesByFingerprint
            .filter { $0.value.count > 1 }
            .map { key, copies -> Group in
                let ranked = rankKeepers(copies)
                return Group(id: key, copies: ranked, keeperID: ranked[0].id)
            }
            .sorted { a, b in
                a.duplicateBytes != b.duplicateBytes ? a.duplicateBytes > b.duplicateBytes : a.id < b.id
            }
        return Result(groups: groups, notCheckedCount: notChecked)
    }

    /// The copies in the order they should be kept: fewest copy markers in their names first, then the shortest
    /// path, then the earliest export. The first one is the keeper.
    static func rankKeepers(_ copies: [Copy]) -> [Copy] {
        copies.sorted { a, b in
            let markersA = a.mediaPaths.reduce(0) { $0 + copyMarkerCount(in: $1) }
            let markersB = b.mediaPaths.reduce(0) { $0 + copyMarkerCount(in: $1) }
            if markersA != markersB { return markersA < markersB }
            let lengthA = a.mediaPaths[0].count
            let lengthB = b.mediaPaths[0].count
            if lengthA != lengthB { return lengthA < lengthB }
            if a.exportOrder != b.exportOrder { return a.exportOrder < b.exportOrder }
            return a.id < b.id
        }
    }

    /// The copy markers in a file name: ` (1)`, ` copy`, `-1`, and an icloudpd size suffix such as `-2483921`.
    static func copyMarkerCount(in path: String) -> Int {
        let name = (path as NSString).lastPathComponent
        let stem = (name as NSString).deletingPathExtension
        let numbered = name.matches(of: /\s\(\d+\)/).count
        let copied = name.lowercased().matches(of: /\scopy/).count
        let suffixed = stem.contains(/-\d+$/) ? 1 : 0
        return numbered + copied + suffixed
    }

    /// Moves the duplicates to the Trash and re-points their records at their keepers' files.
    /// Each item is checked first: its files must still match the recorded checksums and every path must be inside
    /// the destination. A keeper is checked once per group, and if it fails, every copy in its group is skipped.
    /// A duplicate with any file that couldn't be moved isn't re-pointed, so the next run and Verify Backup still
    /// see it as it was.
    /// Call only after the user confirmed, and never while an export runs.
    /// - hasher and trasher: injectable for tests. The default moves files to the Trash.
    static func remove(
        groups: [Group],
        in destination: URL,
        hasher: (URL) throws -> String = FileHasher.sha256(of:),
        trasher: (URL) throws -> Void = DuplicateFinder.moveToTrash,
        progress: (Int, Int) -> Void
    ) -> RemovalResult {
        let total = groups.reduce(0) { $0 + $1.duplicates.count }
        // Which records list each file. A file that another record still lists isn't removed.
        var listedBy: [String: Set<String>] = [:]
        for (key, paths) in ExportManifest.records(in: destination) where !key.hasPrefix(ExportManifest.iCloudPartialPrefix) {
            for path in paths {
                listedBy[path, default: []].insert(key)
            }
        }

        var result = RemovalResult()
        var index = 0
        for group in groups {
            // Every copy in the group is compared with the same keeper, so the keeper is hashed once here.
            let keeperIsIntact = isIntact(group.keeper, in: destination, hasher: hasher)
            for copy in group.duplicates {
                if keeperIsIntact {
                    removeCopy(copy, keeper: group.keeper, in: destination, listedBy: listedBy,
                               hasher: hasher, trasher: trasher, result: &result)
                } else {
                    result.skippedCopies += 1
                }
                index += 1
                progress(index, total)
            }
        }
        return result
    }

    /// Moves a file to the Trash, where it can still be restored.
    static func moveToTrash(_ url: URL) throws {
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
    }

    private static func removeCopy(
        _ copy: Copy,
        keeper: Copy,
        in destination: URL,
        listedBy: [String: Set<String>],
        hasher: (URL) throws -> String,
        trasher: (URL) throws -> Void,
        result: inout RemovalResult
    ) {
        let ownFilesAreNotListedElsewhere = copy.paths.allSatisfy { (listedBy[$0] ?? []).subtracting([copy.id]).isEmpty }
        guard ownFilesAreNotListedElsewhere, isIntact(copy, in: destination, hasher: hasher) else {
            result.skippedCopies += 1
            return
        }

        var trashedBytes: Int64 = 0
        for path in copy.paths {
            let url = destination.appending(path: path)
            // A sidecar that's already gone has nothing to move.
            guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else { continue }
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            do {
                try trasher(url)
                trashedBytes += Int64(size)
            } catch {
                // Stop here: the record stays as it was, so the copy is reported, not half-moved into its keeper.
                result.failedCopies += 1
                return
            }
        }

        do {
            try ExportManifest.appendRecords([(key: copy.id, paths: keeper.paths)], in: destination)
        } catch {
            result.failedCopies += 1
            return
        }
        result.removedCopies += 1
        result.removedBytes += trashedBytes
    }

    /// Whether every path of an item is inside the destination and its media still match the recorded checksums.
    private static func isIntact(_ copy: Copy, in destination: URL, hasher: (URL) throws -> String) -> Bool {
        copy.paths.allSatisfy { isInside($0, destination) } && copy.mediaPaths.allSatisfy { path in
            (try? hasher(destination.appending(path: path))) == copy.checksums[path]
        }
    }

    /// Whether a recorded path is a plain relative path that stays inside `destination`, without symbolic links on the way.
    private static func isInside(_ path: String, _ destination: URL) -> Bool {
        guard ExportManifest.isSafeRelativePath(path) else { return false }
        do {
            try ExportManifest.requireInsideDestination(path, in: destination)
            return true
        } catch {
            return false
        }
    }

    private static func isSidecar(_ path: String) -> Bool {
        (path as NSString).pathExtension.lowercased() == "xmp"
    }
}
