import Foundation

/// What a quick check found. Lists are relative paths; sets are manifest keys (item IDs).
struct QuickVerifyReport: Equatable, Sendable {
    var checkedFiles: Int
    var okItems: Int
    var seconds: Double
    var missingFiles: [String]
    var emptyFiles: [String]
    var changedFiles: [String]
    /// iCloud items whose media files don't add up to the size the catalog recorded. Usually a truncated download.
    var sizeMismatchItemIDs: Set<String>
    /// Every item with a problem above. "Check These Fully" and re-export work from this set.
    var problemItemIDs: Set<String>

    var problemItemCount: Int { problemItemIDs.count }
}

/// Checks that every recorded file is present with the right size, from one listing per folder. It never reads file
/// contents, so it finishes in seconds where the full pass takes hours. Read-only: only folders and the manifest are
/// opened.
enum QuickVerifier {
    /// FAT keeps modification times to 2 s, so a difference inside that window isn't a change.
    static let modifiedTolerance: Double = 2

    /// - catalogSizes: the bytes a download of each iCloud asset ID writes, when known. Items without an entry skip the
    ///   size-sum check.
    static func check(destination: URL, catalogSizes: [String: Int64]? = nil) throws -> QuickVerifyReport {
        let started = ContinuousClock.now
        // Items only partly downloaded aren't backed up, so they aren't checked as items.
        let records = ExportManifest.records(in: destination)
            .filter { !$0.key.hasPrefix(ExportManifest.iCloudPartialPrefix) }
        let snapshot = ExportManifest.filesSnapshot(in: destination)

        // Group the recorded paths by folder, so each folder is listed once.
        var pathsByFolder: [String: [String]] = [:]
        var unsafePaths: [String] = []
        for paths in records.values {
            for path in paths {
                guard ExportManifest.isSafeRelativePath(path) else {
                    unsafePaths.append(path)
                    continue
                }
                let folder = path.split(separator: "/", omittingEmptySubsequences: false).dropLast().joined(separator: "/")
                pathsByFolder[folder, default: []].append(path)
            }
        }

        var missing: [String] = unsafePaths
        var empty: [String] = []
        var changed: [String] = []
        var sizes: [String: Int64] = [:]
        var itemOfPath: [String: String] = [:]
        for (key, paths) in records {
            for path in paths { itemOfPath[path] = key }
        }

        for folder in pathsByFolder.keys.sorted() {
            try Task.checkCancellation()
            let folderURL = folder.isEmpty ? destination : destination.appending(path: folder, directoryHint: .isDirectory)
            // A folder that can't be listed makes every file in it missing.
            let listing: [String: BulkDirectoryLister.Entry] = (try? BulkDirectoryLister.list(folderURL)).map { entries in
                Dictionary(entries.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
            } ?? [:]

            for path in pathsByFolder[folder] ?? [] {
                let name = String(path.split(separator: "/").last ?? "")
                guard let entry = listing[name], entry.kind == .file else {
                    missing.append(path)
                    continue
                }
                sizes[path] = entry.size
                if entry.size == 0 {
                    empty.append(path)
                }
                if let recorded = snapshot?.files[path],
                   recorded.size != entry.size || abs(recorded.modified - entry.modified) > modifiedTolerance {
                    changed.append(path)
                }
            }
        }

        // iCloud items: the media files (everything but the sidecar .xmp) should add up to the catalog's byte count.
        var sizeMismatch: Set<String> = []
        if let catalogSizes {
            for (key, paths) in records where key.hasPrefix(ExportManifest.iCloudIDPrefix) {
                let id = String(key.dropFirst(ExportManifest.iCloudIDPrefix.count))
                guard let expected = catalogSizes[id] else { continue }
                let media = paths.filter { !$0.lowercased().hasSuffix(".xmp") }
                // A missing file is already a problem; the sum can't be compared then.
                guard !media.isEmpty, media.allSatisfy({ sizes[$0] != nil }) else { continue }
                let total = media.reduce(Int64(0)) { $0 + (sizes[$1] ?? 0) }
                if total != expected {
                    sizeMismatch.insert(key)
                }
            }
        }

        var problems = sizeMismatch
        for path in missing + empty + changed {
            if let key = itemOfPath[path] { problems.insert(key) }
        }

        let elapsed = started.duration(to: ContinuousClock.now)
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        return QuickVerifyReport(
            checkedFiles: records.values.reduce(0) { $0 + $1.count },
            okItems: records.count - problems.count,
            seconds: seconds,
            missingFiles: missing.sorted(),
            emptyFiles: empty.sorted(),
            changedFiles: changed.sorted(),
            sizeMismatchItemIDs: sizeMismatch,
            problemItemIDs: problems
        )
    }
}
