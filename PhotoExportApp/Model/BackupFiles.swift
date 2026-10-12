import Foundation
import os
import Photos

/// File and library helpers for Verify Backup and Free Up Space. Every path read
/// from the manifest goes through `containedURL` before it's touched.
enum BackupFiles {
    private static let manifestFolderName = ".photo-export"

    /// The file URL for a manifest path, or nil unless it stays inside `destination`
    /// after resolving ".", ".." and symlinked folders. The manifest's own folder is never returned.
    static func containedURL(for relativePath: String, in destination: URL) -> URL? {
        guard !relativePath.isEmpty, !relativePath.hasPrefix("/"), !relativePath.hasPrefix("~") else { return nil }
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }),
              components.first.map(String.init) != manifestFolderName else { return nil }

        let root = destination.standardizedFileURL.resolvingSymlinksInPath()
        let candidate = root.appending(path: relativePath).standardizedFileURL
        // Resolve symlinks in the folders but not in the file itself: removing a symlink removes only the link.
        let parent = candidate.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath()
        let rootComponents = root.pathComponents
        guard parent.pathComponents.count >= rootComponents.count,
              Array(parent.pathComponents.prefix(rootComponents.count)) == rootComponents else { return nil }
        return parent.appending(path: candidate.lastPathComponent)
    }

    // MARK: - File details

    struct FileDetails: Sendable, Equatable {
        var newestModification: Date?
        var byteCount: Int64 = 0
        /// Every recorded file is a regular file inside the destination.
        var allPresent = true
    }

    static func details(of paths: [String], in destination: URL) -> FileDetails {
        var details = FileDetails(allPresent: !paths.isEmpty)
        for path in paths {
            guard let url = containedURL(for: path, in: destination),
                  let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]),
                  values.isRegularFile == true else {
                details.allPresent = false
                continue
            }
            details.byteCount += Int64(values.fileSize ?? 0)
            if let date = values.contentModificationDate {
                details.newestModification = max(details.newestModification ?? date, date)
            }
        }
        return details
    }

    // MARK: - Removing files

    struct RemovalResult: Sendable {
        /// Items whose recorded files are all gone now, so they can be forgotten.
        var clearedIDs: Set<String> = []
        var removedFileCount = 0
        /// Paths left in place: outside the destination, not a file, shared with another item, or couldn't be removed.
        var keptPaths: [String] = []
    }

    /// Removes the files recorded for `itemIDs`, item by item. An item is cleared only when none of its files remain.
    static func removeRecordedFiles(for itemIDs: Set<String>, in destination: URL) -> RemovalResult {
        let records = ExportManifest.records(in: destination)
        let pathsOfOtherItems = Set(records.filter { !itemIDs.contains($0.key) }.values.joined())
        let fileManager = FileManager.default
        var result = RemovalResult()

        for id in itemIDs.sorted() {
            guard let paths = records[id] else { continue }
            var isCleared = true
            for path in paths {
                guard !pathsOfOtherItems.contains(path), let url = containedURL(for: path, in: destination) else {
                    result.keptPaths.append(path)
                    isCleared = false
                    continue
                }
                let filePath = url.path(percentEncoded: false)
                // attributesOfItem doesn't follow a final symlink, so this sees the link itself.
                guard let attributes = try? fileManager.attributesOfItem(atPath: filePath) else {
                    continue // Already missing.
                }
                let type = attributes[.type] as? FileAttributeType
                guard type == .typeRegular || type == .typeSymbolicLink else {
                    result.keptPaths.append(path)
                    isCleared = false
                    continue
                }
                do {
                    try fileManager.removeItem(atPath: filePath)
                    result.removedFileCount += 1
                } catch {
                    result.keptPaths.append(path)
                    isCleared = false
                }
            }
            if isCleared {
                result.clearedIDs.insert(id)
            }
        }
        return result
    }

    // MARK: - Library

    /// Fetch options that include hidden items and every burst photo, like the export does.
    static func libraryFetchOptions() -> PHFetchOptions {
        let options = PHFetchOptions()
        options.includeHiddenAssets = true
        options.includeAllBurstAssets = true
        return options
    }

    static func allLibraryIDs() -> Set<String> {
        var ids = Set<String>()
        PhotoLibrary.allAssets().enumerateObjects { asset, _, _ in
            ids.insert(asset.localIdentifier)
        }
        return ids
    }

    /// The identifiers from `ids` that are still in the library.
    static func existingLibraryIDs(_ ids: some Collection<String>) -> Set<String> {
        guard !ids.isEmpty else { return [] }
        var existing = Set<String>()
        PHAsset.fetchAssets(withLocalIdentifiers: Array(ids), options: libraryFetchOptions()).enumerateObjects { asset, _, _ in
            existing.insert(asset.localIdentifier)
        }
        return existing
    }
}

/// Lets frequent progress callbacks through about ten times a second, plus the last one.
final class ProgressThrottle: Sendable {
    private let lastReport = OSAllocatedUnfairLock<ContinuousClock.Instant?>(initialState: nil)

    func shouldReport(done: Int, total: Int) -> Bool {
        if done >= total { return true }
        let now = ContinuousClock.now
        return lastReport.withLock { last in
            if let last, now - last < .milliseconds(100) { return false }
            last = now
            return true
        }
    }
}

/// "1 item", "1,234 items".
func countText(_ count: Int, _ singular: String, _ plural: String? = nil) -> String {
    "\(count.formatted()) \(count == 1 ? singular : plural ?? singular + "s")"
}
