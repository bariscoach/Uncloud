import Foundation

/// The outcome of checking exported files against their recorded checksums.
struct VerificationReport: Sendable {
    var verifiedItemIDs: Set<String> = []      // every file present and its checksum matches
    var damagedItemIDs: Set<String> = []       // some file missing, unreadable, or checksum mismatch
    var unverifiableItemIDs: Set<String> = []  // all files present but at least one has no recorded checksum (exported by an older version)
    var missingFiles: [String] = []            // relative paths
    var damagedFiles: [String] = []            // relative paths (mismatch or unreadable)
    var checkedFileCount = 0
    var notBackedUpCount = 0                   // items in `libraryIDs` with no manifest record
}

enum BackupVerifier {
    /// Re-reads exported files and compares them with the recorded checksums.
    /// - itemIDs: limit to these items (nil = every item in the manifest).
    /// - libraryIDs: when given, items in the library but not in the manifest are counted in notBackedUpCount.
    /// - progress: called with (filesChecked, totalFiles) after each file.
    static func verify(
        destination: URL,
        itemIDs: Set<String>? = nil,
        libraryIDs: Set<String>? = nil,
        progress: @escaping @Sendable (Int, Int) -> Void
    ) async throws -> VerificationReport {
        let work = Task.detached(priority: .utility) {
            try verifySynchronously(destination: destination, itemIDs: itemIDs, libraryIDs: libraryIDs, progress: progress)
        }
        return try await withTaskCancellationHandler {
            try await work.value
        } onCancel: {
            work.cancel()
        }
    }

    private static func verifySynchronously(
        destination: URL,
        itemIDs: Set<String>?,
        libraryIDs: Set<String>?,
        progress: @Sendable (Int, Int) -> Void
    ) throws -> VerificationReport {
        // Items only partly downloaded (`icloud-partial:`) aren't backed up, so they aren't verified as items.
        let records = ExportManifest.records(in: destination)
            .filter { !$0.key.hasPrefix(ExportManifest.iCloudPartialPrefix) }
        let checksums = ExportManifest.checksums(in: destination)
        let selected = (itemIDs ?? Set(records.keys)).filter { records[$0] != nil }.sorted()

        var report = VerificationReport()
        if let libraryIDs {
            report.notBackedUpCount = libraryIDs.subtracting(records.keys).count
        }

        let totalFiles = selected.reduce(0) { $0 + (records[$1]?.count ?? 0) }
        var checked = 0

        for id in selected {
            let paths = records[id] ?? []
            var isDamaged = false
            var isUnverifiable = paths.isEmpty

            for path in paths {
                try Task.checkCancellation()
                let url = destination.appending(path: path)
                report.checkedFileCount += 1
                checked += 1
                defer { progress(checked, totalFiles) }

                guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else {
                    report.missingFiles.append(path)
                    isDamaged = true
                    continue
                }
                guard let expected = checksums[path] else {
                    isUnverifiable = true
                    continue
                }
                do {
                    if try FileHasher.sha256(of: url) != expected {
                        report.damagedFiles.append(path)
                        isDamaged = true
                    }
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    // Unreadable file: report it as damaged rather than failing the whole check.
                    report.damagedFiles.append(path)
                    isDamaged = true
                }
            }

            if isDamaged {
                report.damagedItemIDs.insert(id)
            } else if isUnverifiable {
                report.unverifiableItemIDs.insert(id)
            } else {
                report.verifiedItemIDs.insert(id)
            }
        }
        return report
    }
}
