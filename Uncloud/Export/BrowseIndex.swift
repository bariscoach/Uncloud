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

/// Builds the Browse Backup index from the drive. Lists the manifest's media files, reads the metadata of each file
/// that's new or changed, and keeps the rest. Reads the drive; never writes to it.
enum BrowseIndexer {
    /// The recorded photo and movie paths: no `.xmp` sidecars, and no Live Photo movie whose photo is recorded too.
    /// The paths aren't checked against the drive here; `update` skips the ones that are gone.
    static func mediaPaths(in destination: URL) -> [String] {
        var recorded: Set<String> = []
        for paths in ExportManifest.records(in: destination).values {
            for path in paths where ICloudDownloadPaths.hasDownloadExtension(path) && !isSidecar(path) {
                recorded.insert(path)
            }
        }
        return recorded.subtracting(ICloudItemCount.livePhotoMovies(in: recorded)).sorted()
    }

    /// Brings `previous` up to date with the drive. A file is read again only when its size or modification time changed.
    /// - Parameters:
    ///   - waitWhilePaused: Called before each file. It returns when reading may go on, such as after an export ends.
    ///   - progress: Files handled so far, out of the total. Called every 200 files and at the end.
    ///   - persist: The entries so far, every 1,000 files, at the end, and when the update stops early, so a large drive resumes.
    /// - Throws: `CancellationError` when cancelled, or `driveUnavailable` when the destination folder is gone.
    static func update(
        destination: URL,
        previous: [String: BrowseEntry],
        read: @escaping @Sendable (URL) async -> BrowseMetadata = { await BrowseMetadata.read(of: $0) },
        waitWhilePaused: @escaping @Sendable () async throws -> Void,
        progress: @escaping @Sendable (Int, Int) -> Void,
        persist: @escaping @Sendable ([String: BrowseEntry]) -> Void
    ) async throws -> [String: BrowseEntry] {
        let destinationPath = destination.path(percentEncoded: false)
        guard FileManager.default.fileExists(atPath: destinationPath) else { throw BrowseIndexError.driveUnavailable }

        let paths = mediaPaths(in: destination)
        var entries = previous
        var processed = 0
        do {
            for path in paths {
                try Task.checkCancellation()
                try await waitWhilePaused()
                if let url = BackupFiles.containedURL(for: path, in: destination),
                   let stamp = fileStamp(of: url) {
                    if let old = entries[path], old.size == stamp.size, old.modified == stamp.modified {
                        // Unchanged: keep what was read.
                    } else {
                        let metadata = await read(url)
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
                    persist(entries)
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
