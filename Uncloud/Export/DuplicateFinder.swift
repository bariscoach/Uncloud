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

    /// One folder of an item's files that holds a same-content copy of the item's kept files, so the folder's files
    /// are extra copies. A Live Photo's files in the folder move together, sidecars included.
    struct ExtraCopy: Identifiable, Equatable, Sendable {
        /// The record's key, which the copy's paths are removed from.
        let recordID: String
        /// The folder, relative to the destination; empty for files at the top.
        let folder: String
        /// Every recorded path in the folder, sidecars included.
        let paths: [String]
        /// The photo and movie paths in the folder, without `.xmp` sidecars.
        let mediaPaths: [String]
        /// The recorded SHA-256 of each media path in the folder.
        let checksums: [String: String]
        /// The media paths of the copy that's kept, and their recorded SHA-256.
        let keeperPaths: [String]
        let keeperChecksums: [String: String]
        /// The size of the folder's files, in bytes; a file that can't be read counts as zero.
        let byteCount: Int64

        var id: String { "\(recordID)\t\(folder)" }
    }

    /// Items in iCloud that share a file, so the library has the same photo more than once. The first exported item is
    /// kept; the others can be deleted from iCloud.
    struct SharedItemGroup: Identifiable, Equatable, Sendable {
        /// Every item that shares the file, the first exported first.
        let ids: [String]
        /// The files the items share, relative to the destination.
        let paths: [String]
        /// The size of the shared files, once for each extra item.
        let byteCount: Int64

        var id: String { keeperID }
        var keeperID: String { ids[0] }
        var extraIDs: [String] { Array(ids.dropFirst()) }
    }

    struct Result: Equatable, Sendable {
        /// Largest reclaimable size first.
        var groups: [Group]
        /// Items that couldn't be compared: a media file has no recorded checksum, or the record is path-only or partial.
        var notCheckedCount: Int
        /// Extra copies of items whose files are also saved in the folder the layout keeps.
        var extraCopies: [ExtraCopy] = []
        /// iCloud items that share a file.
        var sharedItemGroups: [SharedItemGroup] = []
    }

    struct RemovalResult: Equatable, Sendable {
        /// Duplicates whose files are all in the Trash and whose records now point at their keeper.
        var removedCopies = 0
        var removedBytes: Int64 = 0
        /// Duplicates left in place because a file changed, is missing, or isn't inside the destination.
        var skippedCopies = 0
        /// Duplicates where a file couldn't be moved to the Trash. Files already moved stay moved.
        var failedCopies = 0

        mutating func add(_ other: RemovalResult) {
            removedCopies += other.removedCopies
            removedBytes += other.removedBytes
            skippedCopies += other.skippedCopies
            failedCopies += other.failedCopies
        }
    }

    /// Finds the three kinds of duplicates: items with identical media files in the same folder (`groups`), extra
    /// copies of an item in a folder the kept copy doesn't use (`extraCopies`), and iCloud items that share a file
    /// (`sharedItemGroups`).
    /// - records: key to relative paths, from `ExportManifest.records(in:)`.
    /// - checksums: relative path to SHA-256, from `ExportManifest.checksums(in:)`.
    /// - sizes: relative path to size in bytes. Missing paths count as zero.
    /// - exportOrder: key to the line of its first export. Missing keys rank last.
    /// - layout: the folder layout the destination records. Its folder keeps an item's copy when an item has
    ///   copies in several folders; nil keeps the copy recorded first.
    static func findGroups(
        records: [String: [String]],
        checksums: [String: String],
        sizes: [String: Int64],
        exportOrder: [String: Int] = [:],
        layout: FolderLayout? = nil
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

        // A file listed by two items is one file, not two copies, so those items are left out of the other two kinds.
        var owners: [String: Int] = [:]
        for item in items {
            for path in Set(item.paths) {
                owners[path, default: 0] += 1
            }
        }

        var copiesByFingerprint: [String: [Copy]] = [:]
        var extras: [ExtraCopy] = []
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

            // An item with extra copies is handled as those: its kept copy isn't also a same-folder duplicate, so no
            // file is in two lists. Once the extra copies are gone, the item can match others as usual.
            let itemExtras = extraCopies(recordID: item.key, paths: item.paths, checksums: recorded, sizes: sizes, layout: layout)
            guard itemExtras.isEmpty else {
                extras += itemExtras
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
        return Result(
            groups: groups,
            notCheckedCount: notChecked,
            extraCopies: extras.sorted { ($0.folder, $0.recordID) < ($1.folder, $1.recordID) },
            sharedItemGroups: sharedItemGroups(records: records, sizes: sizes, exportOrder: exportOrder)
        )
    }

    /// The folders of one item that hold extra copies. The copy kept is the one in the layout's folders, else the
    /// one recorded first. Another folder is extra when it's a backup folder (flat or month) and every media file in it
    /// has a same-checksum twin in the kept copy. Album folders are never extra: an album keeps its own copy.
    private static func extraCopies(
        recordID: String,
        paths: [String],
        checksums: [String: String],
        sizes: [String: Int64],
        layout: FolderLayout?
    ) -> [ExtraCopy] {
        var pathsByFolder: [String: [String]] = [:]
        var firstIndex: [String: Int] = [:]
        for (index, path) in paths.enumerated() {
            let folder = (path as NSString).deletingLastPathComponent
            pathsByFolder[folder, default: []].append(path)
            firstIndex[folder] = firstIndex[folder] ?? index
        }
        guard pathsByFolder.count > 1 else { return [] }

        let inLayout = layout.map { layout in
            pathsByFolder.keys.filter { ICloudDownloadPaths.isItem(paths: pathsByFolder[$0] ?? [], in: layout) }
        } ?? []
        let candidates = inLayout.isEmpty ? Array(pathsByFolder.keys) : inLayout
        guard let keeperFolder = candidates.min(by: { firstIndex[$0, default: 0] < firstIndex[$1, default: 0] }) else { return [] }

        let keeperPaths = (pathsByFolder[keeperFolder] ?? []).filter { !isSidecar($0) }
        guard !keeperPaths.isEmpty else { return [] }
        let keeperChecksums = checksums.filter { keeperPaths.contains($0.key) }
        let keeperDigests = Set(keeperChecksums.values)

        var copies: [ExtraCopy] = []
        for folder in pathsByFolder.keys.sorted() where folder != keeperFolder && isBackupFolder(folder) {
            let folderPaths = pathsByFolder[folder] ?? []
            let media = folderPaths.filter { !isSidecar($0) }
            guard !media.isEmpty, media.allSatisfy({ path in checksums[path].map { keeperDigests.contains($0) } ?? false }) else { continue }
            copies.append(ExtraCopy(
                recordID: recordID,
                folder: folder,
                paths: folderPaths,
                mediaPaths: media,
                checksums: checksums.filter { media.contains($0.key) },
                keeperPaths: keeperPaths,
                keeperChecksums: keeperChecksums,
                byteCount: folderPaths.reduce(0) { $0 + (sizes[$1] ?? 0) }
            ))
        }
        return copies
    }

    /// The top folder of a flat backup, or a `YYYY/MM` month folder: where icloudpd puts an item's files. Album folders aren't.
    private static func isBackupFolder(_ folder: String) -> Bool {
        folder.isEmpty || ICloudDownloadPaths.isMonthPath(folder + "/x")
    }

    /// iCloud items that share a file, joined into groups. Only `icloud-id:` items count: an item's file is listed by
    /// each item that saved it. The first exported item in a group is kept.
    private static func sharedItemGroups(
        records: [String: [String]],
        sizes: [String: Int64],
        exportOrder: [String: Int]
    ) -> [SharedItemGroup] {
        var keysByPath: [String: [String]] = [:]
        for (key, paths) in records where key.hasPrefix(ExportManifest.iCloudIDPrefix) {
            for path in Set(paths) {
                keysByPath[path, default: []].append(key)
            }
        }
        let shared = keysByPath.filter { $0.value.count > 1 }
        guard !shared.isEmpty else { return [] }

        // Union-find over the items that share a file.
        var parent: [String: String] = [:]
        func root(_ key: String) -> String {
            var current = key
            while let next = parent[current], next != current {
                current = next
            }
            return current
        }
        for keys in shared.values {
            for key in keys where parent[key] == nil {
                parent[key] = key
            }
            let first = root(keys[0])
            for key in keys.dropFirst() {
                let other = root(key)
                if other != first { parent[other] = first }
            }
        }

        var membersByRoot: [String: [String]] = [:]
        for key in parent.keys {
            membersByRoot[root(key), default: []].append(key)
        }
        var pathsByRoot: [String: Set<String>] = [:]
        for (path, keys) in shared {
            pathsByRoot[root(keys[0]), default: []].insert(path)
        }

        return membersByRoot.map { root, members -> SharedItemGroup in
            let ids = members
                .map { String($0.dropFirst(ExportManifest.iCloudIDPrefix.count)) }
                .sorted { a, b in
                    let orderA = exportOrder[ExportManifest.iCloudIDPrefix + a] ?? Int.max
                    let orderB = exportOrder[ExportManifest.iCloudIDPrefix + b] ?? Int.max
                    return orderA != orderB ? orderA < orderB : a < b
                }
            let paths = (pathsByRoot[root] ?? []).sorted()
            let fileBytes = paths.reduce(0) { $0 + (sizes[$1] ?? 0) }
            return SharedItemGroup(
                ids: ids.map { ExportManifest.iCloudIDPrefix + $0 },
                paths: paths,
                byteCount: fileBytes * Int64(ids.count - 1)
            )
        }
        .sorted { a, b in
            a.byteCount != b.byteCount ? a.byteCount > b.byteCount : a.id < b.id
        }
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
        // A file that another record still lists isn't removed.
        let listedBy = listers(in: destination)

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

    /// Moves extra copies to the Trash and removes their paths from their items' records. Each copy is checked before
    /// anything moves: the kept copy and the extra copy must still match their recorded checksums, the copy's paths
    /// must be inside the destination and listed only by its own item, and the item's record must still list them.
    /// A record keeps the paths that weren't moved, so a partly moved copy is still described correctly.
    /// Call only after the user confirmed, and never while an export runs.
    static func removeExtraCopies(
        _ copies: [ExtraCopy],
        in destination: URL,
        hasher: (URL) throws -> String = FileHasher.sha256(of:),
        trasher: (URL) throws -> Void = DuplicateFinder.moveToTrash,
        progress: (Int, Int) -> Void
    ) -> RemovalResult {
        var result = RemovalResult()
        var current = ExportManifest.records(in: destination)
        let listedBy = listers(in: destination)
        // The kept copy of an item is hashed once, however many extra copies it has.
        var keeperIntact: [String: Bool] = [:]

        for (index, copy) in copies.enumerated() {
            defer { progress(index + 1, copies.count) }
            guard let recorded = current[copy.recordID],
                  Set(copy.paths).isSubset(of: recorded),
                  Set(copy.keeperPaths).isSubset(of: recorded),
                  copy.paths.allSatisfy({ (listedBy[$0] ?? []).subtracting([copy.recordID]).isEmpty }),
                  (copy.paths + copy.keeperPaths).allSatisfy({ isInside($0, destination) })
            else {
                result.skippedCopies += 1
                continue
            }

            let keeperOK = keeperIntact[copy.recordID] ?? copy.keeperPaths.allSatisfy { path in
                (try? hasher(destination.appending(path: path))) == copy.keeperChecksums[path]
            }
            keeperIntact[copy.recordID] = keeperOK
            guard keeperOK, copy.mediaPaths.allSatisfy({ path in
                (try? hasher(destination.appending(path: path))) == copy.checksums[path]
            }) else {
                result.skippedCopies += 1
                continue
            }

            var trashed: [String] = []
            var trashedBytes: Int64 = 0
            var failed = false
            for path in copy.paths {
                let url = destination.appending(path: path)
                // A sidecar that's already gone has nothing to move, but its path still leaves the record.
                guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else {
                    trashed.append(path)
                    continue
                }
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
                do {
                    try trasher(url)
                    trashed.append(path)
                    trashedBytes += Int64(size)
                } catch {
                    failed = true
                    break
                }
            }

            if !trashed.isEmpty {
                let remaining = recorded.filter { !trashed.contains($0) }
                do {
                    try ExportManifest.appendRecords([(key: copy.recordID, paths: remaining)], in: destination)
                    try ExportManifest.forgetFiles(Set(trashed), in: destination)
                    current[copy.recordID] = remaining
                } catch {
                    failed = true
                }
            }

            if failed {
                result.failedCopies += 1
            } else {
                result.removedCopies += 1
                result.removedBytes += trashedBytes
            }
        }
        return result
    }

    /// Which records list each file, so a file that another record still lists isn't removed.
    private static func listers(in destination: URL) -> [String: Set<String>] {
        var listedBy: [String: Set<String>] = [:]
        for (key, paths) in ExportManifest.records(in: destination) where !key.hasPrefix(ExportManifest.iCloudPartialPrefix) {
            for path in paths {
                listedBy[path, default: []].insert(key)
            }
        }
        return listedBy
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
