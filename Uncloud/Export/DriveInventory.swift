import Foundation

/// A stat-only listing of an export destination, for "Check the drive". It never reads file contents.
///
/// Two modes:
/// - `.quick` re-lists only the folders whose modification time differs from the last `files.tsv` snapshot.
///   Folders that didn't change are taken from the snapshot, without stat'ing their files. A change to a file's
///   contents inside an unchanged folder is not seen; only `.full` catches that.
/// - `.full` lists and stats everything.
///
/// Skipped: `.photo-export`, dotfiles and folders, symbolic links, and control characters in names. `.part` and
/// `.partial` files are not listed; they are counted separately in `Result.partialFileCount`.
enum DriveInventory {
    enum Mode: Sendable, Equatable {
        case quick
        case full
    }

    struct Progress: Sendable, Equatable {
        /// Files listed so far, including ones taken from the snapshot.
        let filesListed: Int
        /// The file count of the previous snapshot, when there is one, for "41,000 of ~93,000 files".
        let expectedFiles: Int?
    }

    struct Result: Sendable {
        let mode: Mode
        /// Every listed file, keyed by relative path.
        let files: [String: FilesSnapshot.FileEntry]
        /// Every listed folder, keyed by relative path (`""` is the destination root), with its modification time.
        let directories: [String: Double]
        /// Folders that were listed from disk in this pass. Quick mode lists only changed ones.
        let relistedDirectories: Set<String>
        /// `.part` and `.partial` files in the folders listed in this pass.
        let partialFileCount: Int

        /// The snapshot to store as `files.tsv`. It covers everything listed, including files the manifest doesn't
        /// know about, so that the next quick check still sees them in unchanged folders.
        var snapshot: FilesSnapshot {
            FilesSnapshot(files: files, directories: directories)
        }
    }

    enum InventoryError: Error, Equatable {
        case destinationMissing
    }

    /// Progress is reported after every this many files.
    static let progressInterval = 1_000

    /// Lists the destination on a background task. Cancelling the caller's task cancels the listing,
    /// which stops within a file or two.
    ///
    /// Quick mode without a `previous` snapshot lists everything, like full mode.
    static func run(
        destination: URL,
        mode: Mode,
        previous: FilesSnapshot? = nil,
        progress: (@Sendable (Progress) -> Void)? = nil
    ) async throws -> Result {
        let task = Task.detached(priority: .utility) {
            try scan(destination: destination, mode: mode, previous: previous, progress: progress)
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    // MARK: - Scanning

    private static func scan(
        destination: URL,
        mode: Mode,
        previous: FilesSnapshot?,
        progress: (@Sendable (Progress) -> Void)?
    ) throws -> Result {
        guard FileManager.default.fileExists(atPath: destination.path(percentEncoded: false)) else {
            throw InventoryError.destinationMissing
        }
        // Quick mode only reuses folders when there is a snapshot to reuse them from.
        let reuse = mode == .quick ? previous : nil
        let expectedFiles = previous?.files.count

        var filesByFolder: [String: [String]] = [:]
        var foldersByParent: [String: [String]] = [:]
        if let reuse {
            for path in reuse.files.keys {
                filesByFolder[parent(of: path), default: []].append(path)
            }
            for folder in reuse.directories.keys where !folder.isEmpty {
                foldersByParent[parent(of: folder), default: []].append(folder)
            }
        }

        var files: [String: FilesSnapshot.FileEntry] = [:]
        var directories: [String: Double] = [:]
        var relisted: Set<String> = []
        var partialFileCount = 0
        var listed = 0
        // A folder's modification time comes with it when its parent's listing already had it. Otherwise it is read.
        var pending: [(folder: String, modified: Double?)] = [("", nil)]

        func reportProgress() {
            progress?(Progress(filesListed: listed, expectedFiles: expectedFiles))
        }

        while let next = pending.popLast() {
            try Task.checkCancellation()
            let folder = next.folder
            let folderURL = folder.isEmpty
                ? destination
                : destination.appending(path: folder, directoryHint: .isDirectory)
            let modified: Double
            if let known = next.modified {
                modified = known
            } else {
                // A folder that disappeared since its parent was listed has nothing left to list.
                guard let found = modificationTime(of: folderURL) else { continue }
                modified = found
            }

            if let reuse, reuse.directories[folder] == modified {
                // Unchanged since the snapshot: its files and subfolders are the same as they were. Its subfolders'
                // times aren't known here, so they are read when they are reached.
                directories[folder] = modified
                for path in filesByFolder[folder] ?? [] {
                    try Task.checkCancellation()
                    files[path] = reuse.files[path]
                    listed += 1
                    if listed % progressInterval == 0 { reportProgress() }
                }
                pending.append(contentsOf: (foldersByParent[folder] ?? []).map { (folder: $0, modified: nil) })
                continue
            }

            // Changed, new, or a full run: list the folder once, in one bulk pass. Its subfolders are checked the same way.
            let children: [BulkDirectoryLister.Entry]
            do {
                children = try BulkDirectoryLister.list(folderURL)
            } catch let error as NSError where error.domain == NSPOSIXErrorDomain
                && (error.code == Int(ENOENT) || (error.code == Int(EACCES) && !folder.isEmpty)) {
                // Removed between the parent's listing and this one, or a subfolder that can't be read. Neither
                // stops the scan; the root's failures still throw.
                continue
            }
            directories[folder] = modified
            relisted.insert(folder)
            for child in children {
                try Task.checkCancellation()
                // Hidden names and hidden-flagged entries (the old `.skipsHiddenFiles`) are not listed.
                guard !child.name.hasPrefix("."), !child.isHidden,
                      child.name.rangeOfCharacter(from: .controlCharacters) == nil else {
                    continue
                }
                let path = folder.isEmpty ? child.name : folder + "/" + child.name

                switch child.kind {
                case .directory:
                    pending.append((folder: path, modified: child.modified))
                case .file:
                    let extensionName = (child.name as NSString).pathExtension.lowercased()
                    if extensionName == "part" || extensionName == "partial" {
                        partialFileCount += 1
                        continue
                    }
                    files[path] = FilesSnapshot.FileEntry(size: child.size, modified: child.modified)
                    listed += 1
                    if listed % progressInterval == 0 { reportProgress() }
                case .symlink, .other:
                    continue
                }
            }
        }

        reportProgress()
        return Result(
            mode: mode,
            files: files,
            directories: directories,
            relistedDirectories: relisted,
            partialFileCount: partialFileCount
        )
    }

    /// The folder's modification time, which changes when an entry is added, removed or renamed in it.
    /// Nil when the folder can't be read.
    private static func modificationTime(of url: URL) -> Double? {
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
        return values?.contentModificationDate?.timeIntervalSince1970
    }

    /// The folder part of a relative path (`""` for the destination root).
    private static func parent(of path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return "" }
        return String(path[..<slash])
    }
}
