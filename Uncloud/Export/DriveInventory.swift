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

    private static let listedKeys: [URLResourceKey] = [
        .isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey,
    ]

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
        var pending = [""]

        func reportProgress() {
            progress?(Progress(filesListed: listed, expectedFiles: expectedFiles))
        }

        while let folder = pending.popLast() {
            try Task.checkCancellation()
            let folderURL = folder.isEmpty
                ? destination
                : destination.appending(path: folder, directoryHint: .isDirectory)
            // A folder that disappeared since its parent was listed has nothing left to list.
            guard let modified = modificationTime(of: folderURL) else { continue }
            directories[folder] = modified

            if let reuse, reuse.directories[folder] == modified {
                // Unchanged since the snapshot: its files and subfolders are the same as they were.
                for path in filesByFolder[folder] ?? [] {
                    try Task.checkCancellation()
                    files[path] = reuse.files[path]
                    listed += 1
                    if listed % progressInterval == 0 { reportProgress() }
                }
                pending.append(contentsOf: foldersByParent[folder] ?? [])
                continue
            }

            // Changed, new, or a full run: list the folder, stat each file. Its subfolders are checked the same way.
            relisted.insert(folder)
            let children = try FileManager.default.contentsOfDirectory(
                at: folderURL,
                includingPropertiesForKeys: listedKeys,
                options: [.skipsHiddenFiles]
            )
            for child in children {
                try Task.checkCancellation()
                let name = child.lastPathComponent
                guard !name.hasPrefix("."), name.rangeOfCharacter(from: .controlCharacters) == nil,
                      let values = try? child.resourceValues(forKeys: Set(listedKeys)),
                      values.isSymbolicLink != true
                else { continue }
                let path = folder.isEmpty ? name : folder + "/" + name

                if values.isDirectory == true {
                    pending.append(path)
                } else if values.isRegularFile == true {
                    let extensionName = child.pathExtension.lowercased()
                    if extensionName == "part" || extensionName == "partial" {
                        partialFileCount += 1
                        continue
                    }
                    files[path] = FilesSnapshot.FileEntry(
                        size: Int64(values.fileSize ?? 0),
                        modified: values.contentModificationDate?.timeIntervalSince1970 ?? 0
                    )
                    listed += 1
                    if listed % progressInterval == 0 { reportProgress() }
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
