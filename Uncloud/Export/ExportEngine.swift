import Foundation
import Photos

enum ExportEvent: Sendable {
    case prepared(total: Int, alreadyExported: Int)
    /// More items were found after `prepared`, such as the next album of an iCloud export.
    case totalIncreased(by: Int)
    /// `bytes` is what the item wrote to the destination, when the engine knows it.
    case exported(name: String, fileCount: Int, bytes: Int64? = nil)
    /// An item that was already in the destination. Counted, not logged.
    case skipped
    case failed(name: String, reason: String)
    case note(String)
}

enum ExportError: LocalizedError {
    case destinationFull
    case destinationUnavailable
    case noExportableFiles

    var errorDescription: String? {
        switch self {
        case .destinationFull:
            "The destination is full. Free up space or choose another folder, then choose Resume."
        case .destinationUnavailable:
            "The destination folder is no longer available. Reconnect the drive or choose another folder, then choose Resume."
        case .noExportableFiles:
            "It has no files that can be exported."
        }
    }
}

/// Exports every selected library item not yet recorded in the destination's manifest,
/// one at a time, into folders arranged by `layout`.
struct ExportEngine: Sendable {
    let destination: URL
    let layout: FolderLayout
    let writesSidecars: Bool
    let gate: PauseGate
    /// Items outside the selection are left out: neither exported nor counted as work.
    var selection: LibrarySelection = .everything

    /// Starts the export. Cancelling the run's task stops it; its events then finish once it has stopped.
    func start() -> ExportRun {
        ExportRun.start { emit in try await run(emit: emit) }
    }

    private func run(emit: @escaping @Sendable (ExportEvent) -> Void) async throws {
        let manifest = try ExportManifest(destination: destination)
        try manifest.recordLayout(layout)
        let places = layout.usesPlaces ? PlaceResolver() : nil
        let albums = (layout.usesAlbums || writesSidecars) ? AlbumIndex.build() : nil
        let library = PhotoLibrary.allAssets()
        var pending: [PHAsset] = []
        var excluded = 0
        let selection = selection
        library.enumerateObjects { asset, _, _ in
            if !selection.contains(asset.localIdentifier) {
                excluded += 1
            } else if !manifest.contains(asset.localIdentifier) {
                pending.append(asset)
            }
        }
        let total = library.count - excluded
        emit(.prepared(total: total, alreadyExported: total - pending.count))
        if excluded > 0 {
            let noun = excluded == 1 ? "item that isn’t" : "items that aren’t"
            emit(.note("Leaving out \(excluded.formatted()) \(noun) selected."))
        }

        var failures = 0
        for asset in pending {
            await gate.waitWhilePaused()
            try Task.checkCancellation()

            let files = AssetFiles(asset: asset)
            do {
                let albumPaths = albums?.albums(for: asset.localIdentifier) ?? []
                let paths = try await folderPaths(for: asset, albums: albumPaths, places: places, emit: emit)
                let metadata = writesSidecars ? AssetMetadata(asset: asset, albums: albumPaths) : nil
                let checksums = try await export(files, into: paths, metadata: metadata)
                try manifest.recordChecksums(checksums)
                try manifest.recordExport(of: asset.localIdentifier, files: checksums.keys.sorted())
                let bytes = Self.totalSize(of: checksums.keys.map { destination.appending(path: $0) })
                emit(.exported(name: files.displayName, fileCount: files.items.count, bytes: bytes))
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
                failures += 1
                emit(.failed(name: files.displayName, reason: error.localizedDescription))
            }
        }

        // Leave the run marked incomplete when items failed, so Resume retries them.
        if failures == 0 {
            manifest.markRunFinished()
        }
    }

    /// The item's folders relative to the destination. Album layout puts the item in each of its albums.
    private func folderPaths(
        for asset: PHAsset,
        albums: [String],
        places: PlaceResolver?,
        emit: @escaping @Sendable (ExportEvent) -> Void
    ) async throws -> [String] {
        if layout.usesAlbums {
            return albums.isEmpty ? [AlbumIndex.notInAlbumFolder] : albums
        }
        return [try await folderPath(for: asset, places: places, emit: emit)]
    }

    /// The item's folder relative to the destination, such as `2024/07` or `Italy/Rome/2024-07`. Empty for the
    /// flat layout, which writes into the destination itself.
    private func folderPath(
        for asset: PHAsset,
        places: PlaceResolver?,
        emit: @escaping @Sendable (ExportEvent) -> Void
    ) async throws -> String {
        guard layout != .flat else { return "" }
        let month = asset.creationDate.map { date in
            let parts = Calendar.current.dateComponents([.year, .month], from: date)
            return String(format: "%04d-%02d", parts.year ?? 0, parts.month ?? 0)
        }
        guard let places else {
            return Self.folderPath(for: layout, monthKey: month, place: nil)
        }

        var place = PlaceResolver.unknownFolder
        if let coordinate = asset.location?.coordinate {
            place = try await places.folderPath(latitude: coordinate.latitude, longitude: coordinate.longitude) { delay in
                emit(.note("Place lookups are busy. Trying again in \(delay.formatted(.units(width: .wide)))…"))
            }
        }
        return Self.folderPath(for: layout, monthKey: month, place: place)
    }

    /// The folder for layouts that don't need an album lookup. `monthKey` is `2024-07`; `place` is a resolved folder name.
    static func folderPath(for layout: FolderLayout, monthKey: String?, place: String?) -> String {
        switch layout {
        case .flat:
            return ""
        case .place:
            return place ?? PlaceResolver.unknownFolder
        case .placeThenMonth:
            return "\(place ?? PlaceResolver.unknownFolder)/\(monthKey ?? "Undated")"
        case .month, .album:
            return monthKey?.replacingOccurrences(of: "-", with: "/") ?? "Undated"
        }
    }

    /// The combined size of the files that exist, for an item's `bytes`.
    static func totalSize(of urls: [URL]) -> Int64 {
        urls.reduce(Int64(0)) { total, url in
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            return total + Int64(size)
        }
    }

    /// The folder URL for a folder path from `folderPath`. An empty path is the destination itself.
    static func folderURL(in destination: URL, folderPath: String) -> URL {
        folderPath.isEmpty ? destination : destination.appending(path: folderPath, directoryHint: .isDirectory)
    }

    /// `folderPath/filename` relative to the destination, or just `filename` when the folder is the destination.
    static func relativePath(in folderPath: String, filename: String) -> String {
        folderPath.isEmpty ? filename : "\(folderPath)/\(filename)"
    }

    /// Writes an item's files into the first folder, copies them into each further folder, and writes a sidecar
    /// next to each folder's primary file when `metadata` is set. Returns the SHA-256 of every file, keyed by path
    /// relative to the destination. If anything fails, every file written for this item is removed.
    private func export(_ files: AssetFiles, into folderPaths: [String], metadata: AssetMetadata?) async throws -> [String: String] {
        guard !files.items.isEmpty else { throw ExportError.noExportableFiles }

        let folders = folderPaths.map { Self.folderURL(in: destination, folderPath: $0) }
        // The primary file is the item's main original, found by position so a renamed copy still counts.
        let primaryIndex = files.items.firstIndex { $0.filename == files.displayName } ?? 0

        var written: [URL] = []
        var checksums: [String: String] = [:]
        do {
            for folder in folders {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            }

            var originals: [(url: URL, digest: String)] = []
            for item in files.items {
                let url = FileManager.default.availableURL(in: folders[0], for: item.filename)
                let digest = try await ResourceWriter.write(item.resource, to: url)
                written.append(url)
                originals.append((url: url, digest: digest))
                checksums[Self.relativePath(in: folderPaths[0], filename: url.lastPathComponent)] = digest
            }

            var placed: [[URL]] = [originals.map { $0.url }]
            for (folder, folderPath) in zip(folders, folderPaths).dropFirst() {
                var copies: [URL] = []
                for original in originals {
                    let url = FileManager.default.availableURL(in: folder, for: original.url.lastPathComponent)
                    try FileManager.default.copyItem(at: original.url, to: url)
                    written.append(url)
                    copies.append(url)
                    checksums[Self.relativePath(in: folderPath, filename: url.lastPathComponent)] = original.digest
                }
                placed.append(copies)
            }

            if let metadata {
                for (folderPath, urls) in zip(folderPaths, placed) {
                    let sidecar = try XMPSidecar.write(metadata, nextTo: urls[primaryIndex])
                    written.append(sidecar)
                    checksums[Self.relativePath(in: folderPath, filename: sidecar.lastPathComponent)] = try FileHasher.sha256(of: sidecar)
                }
            }
            return checksums
        } catch {
            for url in written {
                try? FileManager.default.removeItem(at: url)
            }
            throw error
        }
    }
}

extension FileManager {
    /// `name.ext`, or `name (1).ext`, `name (2).ext`… if that's taken.
    func availableURL(in folder: URL, for filename: String) -> URL {
        let stem = (filename as NSString).deletingPathExtension
        let ext = (filename as NSString).pathExtension
        var candidate = folder.appending(path: filename)
        var counter = 1
        while fileExists(atPath: candidate.path(percentEncoded: false)) {
            let name = ext.isEmpty ? "\(stem) (\(counter))" : "\(stem) (\(counter)).\(ext)"
            candidate = folder.appending(path: name)
            counter += 1
        }
        return candidate
    }
}

extension Error {
    var isOutOfSpace: Bool {
        let error = self as NSError
        if error.domain == NSCocoaErrorDomain, error.code == NSFileWriteOutOfSpaceError {
            return true
        }
        if error.domain == NSPOSIXErrorDomain, error.code == Int(ENOSPC) {
            return true
        }
        return (error.userInfo[NSUnderlyingErrorKey] as? Error)?.isOutOfSpace ?? false
    }
}
