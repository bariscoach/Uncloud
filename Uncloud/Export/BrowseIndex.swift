import Foundation

/// One file's entry in the Browse Backup index: what was read from it, and the size and modification time it was read at.
struct BrowseEntry: Codable, Equatable, Sendable {
    var path: String
    var size: Int64
    /// Modification time in seconds since 1970. An unchanged size and time means the file isn't read again.
    var modified: Double
    var latitude: Double?
    var longitude: Double?
    var date: Date?
    var camera: String?
    /// Where the entry came from. Nil (older index files, and every file read) means the file itself. `iCloud` means
    /// the catalog's row: the date and place are iCloud's, and the camera is read from the file on demand.
    var source: Source? = nil

    enum Source: String, Codable, Sendable {
        case file
        case iCloud
    }

    var hasLocation: Bool { latitude != nil && longitude != nil }
}

/// The index file for each destination, in Application Support (never on the drive). The file is replaced as a whole,
/// so a crash leaves the last complete index.
struct BrowseIndexStore: Sendable {
    let directory: URL

    private static let version = 1

    private struct File: Codable {
        var version: Int
        var entries: [String: BrowseEntry]
    }

    /// `Application Support/Uncloud/BrowseIndex`, in the app's sandbox container.
    static func standard() -> BrowseIndexStore {
        let support = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        return BrowseIndexStore(directory: support.appending(path: "Uncloud", directoryHint: .isDirectory)
            .appending(path: "BrowseIndex", directoryHint: .isDirectory))
    }

    /// The saved entries by path. Empty when there's no index, or it's unreadable or from another version.
    func load(key: String) -> [String: BrowseEntry] {
        guard let data = try? Data(contentsOf: url(for: key)),
              let file = try? JSONDecoder().decode(File.self, from: data),
              file.version == Self.version else { return [:] }
        return file.entries
    }

    func save(_ entries: [String: BrowseEntry], key: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(File(version: Self.version, entries: entries))
        try data.write(to: url(for: key), options: .atomic)
    }

    func remove(key: String) {
        try? FileManager.default.removeItem(at: url(for: key))
    }

    private func url(for key: String) -> URL {
        directory.appending(path: key + ".json")
    }
}

enum BrowseIndexError: Error, Equatable {
    /// The destination folder isn't there (the drive is disconnected). Nothing is dropped from the index.
    case driveUnavailable
}

/// What one listing per folder tells the indexer about the recorded files: each file's size and modification time,
/// and every entry's path, so that a sidecar check needs no lookup.
struct BrowseDriveListing: Sendable {
    struct Stamp: Equatable, Sendable {
        let size: Int64
        let modified: Double
    }

    /// Regular files by relative path.
    private(set) var stamps: [String: Stamp] = [:]
    /// Standardized full paths of every entry in the listed folders.
    private(set) var entryPaths: Set<String> = []
    /// Relative folders whose listing failed for a reason other than the folder being gone (EACCES, EIO, and so on).
    /// Their files are neither read nor dropped: the index keeps what it had for them.
    private(set) var failedFolders: Set<String> = []

    /// Lists each folder that holds one of `paths` once, with `BulkDirectoryLister`. A folder that is missing
    /// contributes nothing, so its files count as gone. A folder that fails any other way is recorded in
    /// `failedFolders`.
    static func build(paths: [String], in destination: URL) -> BrowseDriveListing {
        var listing = BrowseDriveListing()
        let folders = Dictionary(grouping: paths) { ($0 as NSString).deletingLastPathComponent }
        for (relativeFolder, group) in folders {
            guard let sample = BackupFiles.containedURL(for: group[0], in: destination) else { continue }
            let folderURL = sample.deletingLastPathComponent()
            let entries: [BulkDirectoryLister.Entry]
            do {
                entries = try BulkDirectoryLister.list(folderURL)
            } catch let error as NSError where error.domain == NSPOSIXErrorDomain && error.code == Int(ENOENT) {
                continue
            } catch {
                listing.failedFolders.insert(relativeFolder)
                continue
            }
            for entry in entries {
                listing.entryPaths.insert(standardized(folderURL.appending(path: entry.name)))
                guard entry.kind == .file else { continue }
                let relativePath = relativeFolder.isEmpty ? entry.name : relativeFolder + "/" + entry.name
                listing.stamps[relativePath] = Stamp(size: entry.size, modified: entry.modified)
            }
        }
        return listing
    }

    /// Whether the folder of `path` could not be listed for a reason other than being gone.
    func isInFailedFolder(_ path: String) -> Bool {
        failedFolders.contains((path as NSString).deletingLastPathComponent)
    }

    /// Whether `url` is an entry in one of the listed folders. Used for `.xmp` sidecars.
    func containsEntry(at url: URL) -> Bool {
        entryPaths.contains(Self.standardized(url))
    }

    private static func standardized(_ url: URL) -> String {
        url.standardizedFileURL.path(percentEncoded: false)
    }
}

/// Builds the Browse Backup index from the drive. Lists the manifest's media files, reads the metadata of each file
/// that's new or changed, and keeps the rest. Reads the drive; never writes to it.
enum BrowseIndexer {
    /// The seconds that must pass between saves of a large index. Saves still happen at every 1,000 files.
    static let minimumSaveInterval: TimeInterval = 30

    /// The recorded photo and movie paths: no `.xmp` sidecars, and no Live Photo movie whose photo is recorded too.
    /// The paths aren't checked against the drive here; `update` skips the ones that are gone.
    static func mediaPaths(in destination: URL) -> [String] {
        mediaPaths(among: ExportManifest.records(in: destination).values.joined())
    }

    /// The media paths among `paths`, by the same rules as `mediaPaths(in:)`.
    static func mediaPaths<S: Sequence>(among paths: S) -> [String] where S.Element == String {
        var recorded: Set<String> = []
        for path in paths where ICloudDownloadPaths.hasDownloadExtension(path) && !isSidecar(path) {
            recorded.insert(path)
        }
        return recorded.subtracting(ICloudItemCount.livePhotoMovies(in: recorded)).sorted()
    }

    /// The metadata the catalog knows for the iCloud items' media files, by path. Each file of an `icloud-id:` record
    /// gets its asset's row: the place, and the date (`created`, or `added` when there's none). Files whose asset has
    /// no row are left out, so the caller reads them. A row's date and place are used as they are.
    static func iCloudMetadata(in destination: URL, catalog: ICloudCatalog) async throws -> [String: BrowseMetadata] {
        let items = ExportManifest.iCloudItems(in: destination)
        let media = Set(mediaPaths(among: items.values.joined()))
        var assetByPath: [String: String] = [:]
        for (asset, paths) in items {
            for path in paths where media.contains(path) {
                assetByPath[path] = asset
            }
        }
        let rows = try await catalog.rows(ids: Set(assetByPath.values))
        var metadata: [String: BrowseMetadata] = [:]
        for (path, asset) in assetByPath {
            guard let row = rows[asset] else { continue }
            metadata[path] = BrowseMetadata(
                latitude: row.latitude, longitude: row.longitude, date: row.created ?? row.added, camera: nil
            )
        }
        return metadata
    }

    /// Brings `previous` up to date with the drive. A file is read again only when its size or modification time changed.
    ///
    /// The drive is listed once per folder (`BrowseDriveListing`). That gives every file's size and time and the
    /// sidecars' existence, without a lookup per file, which is slow on exFAT.
    /// - Parameters:
    ///   - read: Reads one file. Nil reads it with `BrowseMetadata.read`, which takes its sidecar check from the listing.
    ///   - iCloudMetadata: From `iCloudMetadata(in:catalog:)`. A new or changed file with a date here is indexed from it
    ///     and not read. Files without a date are read.
    ///   - waitWhilePaused: Called before the drive is listed and before each file. It returns when reading may go on,
    ///     such as after an export ends.
    ///   - progress: Files handled so far, out of the total. Called every 200 files and at the end.
    ///   - persist: The entries so far. Called every 1,000 files, but no more often than every `minimumSaveInterval`
    ///     seconds by `clock`, and at the end and when the update stops early, so a large drive resumes.
    ///   - clock: Seconds on a monotonic clock. Tests pass a fake.
    /// - Throws: `CancellationError` when cancelled, or `driveUnavailable` when the destination folder is gone.
    static func update(
        destination: URL,
        previous: [String: BrowseEntry],
        read: (@Sendable (URL) async -> BrowseMetadata)? = nil,
        iCloudMetadata: [String: BrowseMetadata] = [:],
        waitWhilePaused: @escaping @Sendable () async throws -> Void,
        progress: @escaping @Sendable (Int, Int) -> Void,
        persist: @escaping @Sendable ([String: BrowseEntry]) -> Void,
        clock: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) async throws -> [String: BrowseEntry] {
        let destinationPath = destination.path(percentEncoded: false)
        guard FileManager.default.fileExists(atPath: destinationPath) else { throw BrowseIndexError.driveUnavailable }

        // Wait before listing, so a run that starts during an export lists the drive once the export has written its files.
        try await waitWhilePaused()
        let paths = mediaPaths(in: destination)
        let listing = BrowseDriveListing.build(paths: paths, in: destination)
        var entries = previous
        var processed = 0
        var lastSave: TimeInterval?
        do {
            for path in paths {
                try Task.checkCancellation()
                try await waitWhilePaused()
                if let url = BackupFiles.containedURL(for: path, in: destination),
                   let stamp = listing.stamps[path] {
                    if let old = entries[path], old.size == stamp.size, old.modified == stamp.modified {
                        // Unchanged: keep what was read.
                    } else if let row = iCloudMetadata[path], row.date != nil {
                        // The catalog has this item's date and place, so the file isn't read.
                        entries[path] = BrowseEntry(
                            path: path,
                            size: stamp.size,
                            modified: stamp.modified,
                            latitude: row.latitude,
                            longitude: row.longitude,
                            date: row.date,
                            camera: nil,
                            source: .iCloud
                        )
                    } else {
                        let metadata: BrowseMetadata
                        if let read {
                            metadata = await read(url)
                        } else {
                            metadata = await BrowseMetadata.read(of: url, sidecarExists: { listing.containsEntry(at: $0) })
                        }
                        entries[path] = BrowseEntry(
                            path: path,
                            size: stamp.size,
                            modified: stamp.modified,
                            latitude: metadata.latitude,
                            longitude: metadata.longitude,
                            date: metadata.date,
                            camera: metadata.camera
                        )
                    }
                } else if listing.isInFailedFolder(path) {
                    // The folder couldn't be listed this time, so nothing is known about the file. Keep its entry.
                } else {
                    // Gone. A missing folder means the drive went away, which is not the same as a deleted file.
                    guard FileManager.default.fileExists(atPath: destinationPath) else { throw BrowseIndexError.driveUnavailable }
                    entries[path] = nil
                }
                processed += 1
                if processed % 200 == 0 || processed == paths.count {
                    progress(processed, paths.count)
                }
                if processed % 1_000 == 0 {
                    let now = clock()
                    if lastSave.map({ now - $0 >= minimumSaveInterval }) ?? true {
                        persist(entries)
                        lastSave = now
                    }
                }
            }
        } catch {
            persist(entries)
            throw error
        }

        // Entries for files no longer in the manifest go too. They're listed by path, so this is a set difference.
        let listed = Set(paths)
        entries = entries.filter { listed.contains($0.key) }
        persist(entries)
        return entries
    }

    /// The size and modification time of a regular file, or nil when it's missing or isn't a file.
    static func fileStamp(of url: URL) -> (size: Int64, modified: Double)? {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]),
              values.isRegularFile == true else { return nil }
        return (Int64(values.fileSize ?? 0), values.contentModificationDate?.timeIntervalSince1970 ?? 0)
    }

    private static func isSidecar(_ path: String) -> Bool {
        (path as NSString).pathExtension.lowercased() == "xmp"
    }
}
