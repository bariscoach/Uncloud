import Foundation

enum TakeoutImportError: LocalizedError {
    /// The file's name, or the folder it would go in, can't be recorded safely.
    case unsafeName(String)

    var errorDescription: String? {
        switch self {
        case .unsafeName(let name):
            "“\(name)” can’t be saved in the backup under its name."
        }
    }
}

/// Copies the media of Google Takeout inputs into the backup folder, arranged by `layout`, the way `ExportEngine`
/// arranges a library export. Only `destination` is written to.
///
/// Each file is copied into a staging file in `.photo-export/google-staging` while it is hashed. A file whose SHA-256 is
/// already in the backup (`checksums.tsv`, or an earlier `google:` record) is dropped and counted as skipped. The rest
/// move into their folder with a sidecar `.xmp` when Takeout gave a date or a location. The records are
/// `google:<sha256>` in `exported.tsv`, and `.photo-export/google-imported.tsv` lists the Takeout files that are done, so
/// a resumed import reads none of them again. The import doesn't mark an export run, so it never changes the
/// iCloud or Photos run marker.
struct TakeoutImporter: Sendable {
    let destination: URL
    let layout: FolderLayout
    /// The chosen files and folders: a `Takeout` folder, a `Google Photos` folder, an album folder, a folder of zip
    /// files, or zip files.
    let inputs: [URL]
    let gate: PauseGate
    /// Looks up place names for the place layouts. Nil puts items without a folder name in "Unknown Location".
    var places: PlaceResolver? = nil

    private static let chunkSize = 1 << 20
    private static let stagingFolderName = "google-staging"

    /// Starts the import. Cancelling the run's task stops it; its events then finish once it has stopped.
    func start() -> ExportRun {
        ExportRun.start { emit in try await run(emit: emit) }
    }

    /// The folder staging files are written to, inside the destination's manifest folder.
    static func stagingURL(in destination: URL) -> URL {
        ExportManifest.folder(in: destination).appending(path: stagingFolderName, directoryHint: .isDirectory)
    }

    /// `yyyy-MM` for the folder of a date, in the current calendar, as `ExportEngine` names months.
    static func monthKey(_ date: Date) -> String {
        let parts = Calendar.current.dateComponents([.year, .month], from: date)
        return String(format: "%04d-%02d", parts.year ?? 0, parts.month ?? 0)
    }

    private func run(emit: @escaping @Sendable (ExportEvent) -> Void) async throws {
        emit(.note("Reading your Takeout files…"))
        let scan = try TakeoutSource.scan(inputs)
        for name in scan.unreadable {
            emit(.note("Couldn’t read “\(name)”. Choose the Takeout folder or the zip files Google gave you."))
        }

        let manifest = try ExportManifest(destination: destination, marksRun: false)
        let journal = try TakeoutImportJournal(destination: destination)
        let staging = Self.stagingURL(in: destination)
        try? FileManager.default.removeItem(at: staging)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }

        let session = Session(
            destination: destination,
            layout: layout,
            places: places,
            manifest: manifest,
            journal: journal,
            checksums: Set(ExportManifest.checksums(in: destination).values),
            stagingFolder: staging,
            emit: emit
        )

        // Items in an album come first, so a photo that is both in an album and in a year folder is kept
        // with its album, and the year-folder copy is the one skipped.
        let ordered = scan.items.filter { $0.album != nil } + scan.items.filter { $0.album == nil }
        let alreadyDone = ordered.count { journal.contains($0.sourceKey) }
        emit(.prepared(total: ordered.count, alreadyExported: alreadyDone))

        for item in ordered {
            await gate.waitWhilePaused()
            try Task.checkCancellation()
            if journal.contains(item.sourceKey) {
                continue
            }
            do {
                let event = try await session.importItem(item)
                emit(event)
            } catch {
                if Task.isCancelled {
                    throw CancellationError()
                }
                if error is PlaceLookupError {
                    throw error
                }
                if error.isOutOfSpace {
                    throw ExportError.destinationFull
                }
                if !FileManager.default.fileExists(atPath: destination.path(percentEncoded: false)) {
                    throw ExportError.destinationUnavailable
                }
                emit(.failed(name: item.name, reason: error.localizedDescription))
            }
        }
    }

    /// The state of one import run. Used by one task only.
    private final class Session {
        let destination: URL
        let layout: FolderLayout
        let places: PlaceResolver?
        let manifest: ExportManifest
        let journal: TakeoutImportJournal
        var checksums: Set<String>
        let stagingFolder: URL
        let emit: @Sendable (ExportEvent) -> Void
        private var readers: [URL: ZipArchiveReader] = [:]
        private var albumFolders: [String: String] = [:]
        private var usedAlbumNames: Set<String> = []

        init(
            destination: URL,
            layout: FolderLayout,
            places: PlaceResolver?,
            manifest: ExportManifest,
            journal: TakeoutImportJournal,
            checksums: Set<String>,
            stagingFolder: URL,
            emit: @escaping @Sendable (ExportEvent) -> Void
        ) {
            self.destination = destination
            self.layout = layout
            self.places = places
            self.manifest = manifest
            self.journal = journal
            self.checksums = checksums
            self.stagingFolder = stagingFolder
            self.emit = emit
        }

        /// Imports one item, or recognizes it as already in the backup. Throws on a failure of this item only.
        func importItem(_ item: TakeoutItem) async throws -> ExportEvent {
            let ext = (item.name as NSString).pathExtension.lowercased()
            let stagedName = ext.isEmpty ? UUID().uuidString : "\(UUID().uuidString).\(ext)"
            let staged = stagingFolder.appending(path: stagedName)
            var moved = false
            defer {
                if !moved {
                    try? FileManager.default.removeItem(at: staged)
                }
            }

            let sha = try stage(item, to: staged)
            let key = ExportManifest.googleKeyPrefix + sha
            if manifest.contains(key) || checksums.contains(sha) {
                try journal.record(sourceKey: item.sourceKey, sha256: sha)
                return .skipped
            }

            // Takeout's sidecar is the first choice for the date and place. The file's own metadata fills in what
            // the sidecar lacks, and the file's modification date is the last resort for the folder.
            let sidecar = item.metadata
            let takenDate = sidecar?.takenDate
            var coordinate = sidecar?.coordinate
            var date = takenDate
            if date == nil || coordinate == nil {
                let own = await BrowseMetadata.read(of: staged)
                date = date ?? own.date
                if coordinate == nil, let latitude = own.latitude, let longitude = own.longitude {
                    coordinate = TakeoutMetadata.Coordinate(latitude: latitude, longitude: longitude, altitude: nil)
                }
            }
            let folderDate = date ?? item.modified

            let album = item.album.map { albumFolder(for: $0) }
            var place: String?
            if layout.usesPlaces {
                place = try await placeFolder(coordinate)
            }
            let folderPath: String
            if layout == .album {
                folderPath = album ?? AlbumIndex.notInAlbumFolder
            } else {
                folderPath = ExportEngine.folderPath(
                    for: layout, monthKey: folderDate.map(TakeoutImporter.monthKey), place: place
                )
            }
            let relative = ExportEngine.relativePath(in: folderPath, filename: item.name)
            guard ExportManifest.isSafeRelativePath(relative) else {
                throw TakeoutImportError.unsafeName(item.name)
            }

            let folderURL = ExportEngine.folderURL(in: destination, folderPath: folderPath)
            try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
            let finalURL = FileManager.default.availableURL(in: folderURL, for: item.name)
            try FileManager.default.moveItem(at: staged, to: finalURL)
            moved = true

            var written: [URL] = [finalURL]
            do {
                if let date {
                    try FileManager.default.setAttributes(
                        [.creationDate: date, .modificationDate: date], ofItemAtPath: finalURL.path(percentEncoded: false)
                    )
                }
                var paths = [relative]
                var digests = [relative: sha]
                if takenDate != nil || sidecar?.coordinate != nil {
                    let metadata = AssetMetadata(
                        localIdentifier: key,
                        creationDate: takenDate,
                        modificationDate: takenDate,
                        latitude: sidecar?.coordinate?.latitude,
                        longitude: sidecar?.coordinate?.longitude,
                        altitude: sidecar?.coordinate?.altitude,
                        isFavorite: sidecar?.favorited ?? false,
                        isHidden: false,
                        albums: album.map { [$0] } ?? []
                    )
                    let sidecarURL = try XMPSidecar.write(metadata, nextTo: finalURL)
                    written.append(sidecarURL)
                    let sidecarPath = ExportEngine.relativePath(in: folderPath, filename: sidecarURL.lastPathComponent)
                    paths.append(sidecarPath)
                    digests[sidecarPath] = try FileHasher.sha256(of: sidecarURL)
                }

                try manifest.recordChecksums(digests)
                try manifest.recordExport(of: key, files: paths.sorted())
                try journal.record(sourceKey: item.sourceKey, sha256: sha)
                checksums.insert(sha)
                return .exported(
                    name: item.name,
                    fileCount: paths.count,
                    bytes: ExportEngine.totalSize(of: written)
                )
            } catch {
                for url in written {
                    try? FileManager.default.removeItem(at: url)
                }
                throw error
            }
        }

        /// Copies the item's bytes into `url` while hashing them. Throws on a read error, a corrupt zip entry, or a
        /// full disk. The caller removes the staging file.
        private func stage(_ item: TakeoutItem, to url: URL) throws -> String {
            FileManager.default.createFile(atPath: url.path(percentEncoded: false), contents: nil)
            let output = try FileHandle(forWritingTo: url)
            defer { try? output.close() }
            let hasher = StreamingHasher()
            switch item.origin {
            case .file(let source):
                let input = try FileHandle(forReadingFrom: source)
                defer { try? input.close() }
                while true {
                    try Task.checkCancellation()
                    guard let chunk = try input.read(upToCount: TakeoutImporter.chunkSize), !chunk.isEmpty else { break }
                    try output.write(contentsOf: chunk)
                    hasher.update(chunk)
                }
            case .zip(let archive, let entry):
                let reader = try reader(for: archive)
                try reader.extract(entry, to: output) { hasher.update($0) }
            }
            return hasher.finalizeHex()
        }

        /// One reader per archive for the whole run: the central directory is read once, not per item.
        private func reader(for archive: URL) throws -> ZipArchiveReader {
            if let reader = readers[archive] {
                return reader
            }
            let reader = try ZipArchiveReader(url: archive)
            readers[archive] = reader
            return reader
        }

        /// The folder name for an album, sanitized like the iCloud and Photos album folders. Albums with the same
        /// name share one folder.
        private func albumFolder(for album: String) -> String {
            if let name = albumFolders[album] {
                return name
            }
            let name = AlbumIndex.uniqueName(for: album, usedNames: &usedAlbumNames)
            albumFolders[album] = name
            return name
        }

        /// The `Country/City` folder for a location, or "Unknown Location" when there is no location or no resolver.
        private func placeFolder(_ coordinate: TakeoutMetadata.Coordinate?) async throws -> String {
            guard let coordinate, let places else { return PlaceResolver.unknownFolder }
            let emit = self.emit
            return try await places.folderPath(latitude: coordinate.latitude, longitude: coordinate.longitude) { delay in
                emit(.note("Place lookups are busy. Trying again in \(delay.formatted(.units(width: .wide)))…"))
            }
        }
    }
}
