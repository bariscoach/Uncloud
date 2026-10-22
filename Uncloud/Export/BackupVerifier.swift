import Foundation
import os

/// The outcome of checking exported files against their recorded checksums.
struct VerificationReport: Sendable {
    var verifiedItemIDs: Set<String> = []      // every file present and its checksum matches
    var damagedItemIDs: Set<String> = []       // some file missing, unreadable, or checksum mismatch
    var unverifiableItemIDs: Set<String> = []  // all files present but at least one has no recorded checksum (exported by an older version)
    var missingFiles: [String] = []            // relative paths
    var damagedFiles: [String] = []            // relative paths (mismatch or unreadable)
    var checkedFileCount = 0
    var notBackedUpCount = 0                   // items in `libraryIDs` with no manifest record
    /// True when the pass continued from a saved checkpoint instead of starting at the first item.
    var resumedFromCheckpoint = false
    /// Set when a checkpoint existed but no longer matched the journal, so the pass started over. Shown to the user.
    var checkpointRestartReason: String?
}

/// Bytes read so far in one verify run, shared with the caller's UI. Safe to update from the verifier's detached work.
final class VerifyByteCount: Sendable {
    private let state = OSAllocatedUnfairLock(initialState: Int64(0))

    var value: Int64 { state.withLock { $0 } }

    func add(_ bytes: Int64) {
        state.withLock { $0 += bytes }
    }
}

enum BackupVerifier {
    /// Re-reads exported files and compares them with the recorded checksums.
    /// - itemIDs: limit to these items (nil = every item in the manifest, checked in the order they were first exported).
    /// - libraryIDs: when given, items in the library but not in the manifest are counted in notBackedUpCount.
    /// - checkpoint: for a full pass (`itemIDs` nil), where to keep progress so an interrupted pass can continue. A pass
    ///   with `itemIDs` never uses a checkpoint.
    /// - progress: called with (filesChecked, totalFiles) after each file.
    /// - bytes: when given, gets the bytes of every file read in this run.
    static func verify(
        destination: URL,
        itemIDs: Set<String>? = nil,
        libraryIDs: Set<String>? = nil,
        checkpoint: VerifyCheckpointStore? = nil,
        bytes: VerifyByteCount? = nil,
        progress: @escaping @Sendable (Int, Int) -> Void
    ) async throws -> VerificationReport {
        let work = Task.detached(priority: .utility) {
            try verifySynchronously(
                destination: destination, itemIDs: itemIDs, libraryIDs: libraryIDs, checkpoint: checkpoint, bytes: bytes,
                progress: progress
            )
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
        checkpoint: VerifyCheckpointStore?,
        bytes: VerifyByteCount?,
        progress: @Sendable (Int, Int) -> Void
    ) throws -> VerificationReport {
        // Items only partly downloaded (`icloud-partial:`) aren't backed up, so they aren't verified as items.
        let records = ExportManifest.records(in: destination)
            .filter { !$0.key.hasPrefix(ExportManifest.iCloudPartialPrefix) }
        let checksums = ExportManifest.checksums(in: destination)

        // A full pass goes in disk order: the order items were first exported, which is close to physical order.
        let fullPass = itemIDs == nil
        let order: [String]
        if fullPass {
            let positions = ExportManifest.firstRecordPositions(in: destination)
            order = records.keys.sorted { lhs, rhs in
                let left = positions[lhs] ?? Int.max
                let right = positions[rhs] ?? Int.max
                return left != right ? left < right : lhs < rhs
            }
        } else {
            order = (itemIDs ?? []).filter { records[$0] != nil }.sorted()
        }

        var report = VerificationReport()
        if let libraryIDs {
            report.notBackedUpCount = libraryIDs.subtracting(records.keys).count
        }
        let totalFiles = order.reduce(0) { $0 + (records[$1]?.count ?? 0) }

        // Only a full pass uses a checkpoint.
        let store = fullPass ? checkpoint : nil
        let journalBytes = store == nil ? 0 : VerifyJournal.size(in: destination)
        let journalHead = store == nil ? "" : (VerifyJournal.headOfCurrentJournal(in: destination, size: journalBytes) ?? "")

        var startIndex = 0
        var startedAt = store?.now() ?? Date()
        if let store {
            switch VerifyCheckpoint.resumability(of: store.load(), destination: destination) {
            case .none:
                break
            case .restart(let reason):
                report.checkpointRestartReason = reason
                store.remove()
            case .resume(let saved):
                // Everything before the saved index is finished. Rebuild the sets from the checkpoint.
                startIndex = min(saved.nextItemIndex, order.count)
                let problems = Set(saved.damagedItemIDs).union(saved.unverifiableItemIDs)
                report.verifiedItemIDs = Set(order[0..<startIndex]).subtracting(problems)
                report.damagedItemIDs = Set(saved.damagedItemIDs)
                report.unverifiableItemIDs = Set(saved.unverifiableItemIDs)
                report.missingFiles = saved.missingFiles
                report.damagedFiles = saved.damagedFiles
                report.checkedFileCount = saved.checkedFileCount
                report.resumedFromCheckpoint = true
                startedAt = saved.startedAt
            }
        }

        // `report` only ever holds finished items, so a checkpoint saved mid-item never counts a half-checked item.
        var checked = report.checkedFileCount
        var nextIndex = startIndex
        var filesSinceSave = 0
        var lastSave = store?.now() ?? Date()

        func snapshot() -> VerifyCheckpoint {
            VerifyCheckpoint(
                startedAt: startedAt,
                journalBytes: journalBytes,
                journalHead: journalHead,
                nextItemIndex: nextIndex,
                checkedFileCount: report.checkedFileCount,
                verifiedCount: report.verifiedItemIDs.count,
                damagedItemIDs: report.damagedItemIDs.sorted(),
                unverifiableItemIDs: report.unverifiableItemIDs.sorted(),
                missingFiles: report.missingFiles,
                damagedFiles: report.damagedFiles,
                updatedAt: store?.now() ?? Date()
            )
        }

        do {
            for index in startIndex..<order.count {
                try Task.checkCancellation()
                nextIndex = index
                let id = order[index]
                let paths = records[id] ?? []
                var isDamaged = false
                var isUnverifiable = paths.isEmpty
                var itemChecked = 0
                var itemMissing: [String] = []
                var itemDamaged: [String] = []

                for path in paths {
                    try Task.checkCancellation()
                    let url = destination.appending(path: path)
                    itemChecked += 1
                    checked += 1
                    defer { progress(checked, totalFiles) }

                    guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else {
                        itemMissing.append(path)
                        isDamaged = true
                        continue
                    }
                    if let bytes, let attributes = try? FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false)),
                       let size = attributes[.size] as? NSNumber {
                        bytes.add(size.int64Value)
                    }
                    guard let expected = checksums[path] else {
                        isUnverifiable = true
                        continue
                    }
                    do {
                        if try SequentialFileReader.sha256(of: url) != expected {
                            itemDamaged.append(path)
                            isDamaged = true
                        }
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        // Unreadable file: report it as damaged rather than failing the whole check.
                        itemDamaged.append(path)
                        isDamaged = true
                    }
                }

                report.checkedFileCount += itemChecked
                report.missingFiles += itemMissing
                report.damagedFiles += itemDamaged
                if isDamaged {
                    report.damagedItemIDs.insert(id)
                } else if isUnverifiable {
                    report.unverifiableItemIDs.insert(id)
                } else {
                    report.verifiedItemIDs.insert(id)
                }
                nextIndex = index + 1

                if let store {
                    filesSinceSave += itemChecked
                    let current = store.now()
                    if filesSinceSave >= store.saveEveryFiles || current.timeIntervalSince(lastSave) >= store.saveEverySeconds {
                        // Best effort: a checkpoint that can't be written only costs the resume.
                        try? store.save(snapshot())
                        filesSinceSave = 0
                        lastSave = current
                    }
                }
            }
        } catch {
            // Cancelled or failed: keep what has been finished, so the next pass can continue from it.
            if let store {
                try? store.save(snapshot())
            }
            throw error
        }

        store?.remove()
        return report
    }
}
