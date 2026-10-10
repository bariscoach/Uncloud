import Foundation
import Photos

enum ExportEvent: Sendable {
    case prepared(total: Int, alreadyExported: Int)
    case exported(name: String, fileCount: Int)
    case failed(name: String, reason: String)
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

/// Exports every library item not yet recorded in the destination's manifest,
/// one at a time, into `YYYY/MM` folders.
struct ExportEngine: Sendable {
    let destination: URL
    let gate: PauseGate

    /// Starts the export. Cancelling the task that iterates the stream stops it.
    func events() -> AsyncThrowingStream<ExportEvent, Error> {
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: ExportEvent.self)
        let task = Task.detached {
            do {
                try await run { continuation.yield($0) }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    private func run(emit: (ExportEvent) -> Void) async throws {
        let manifest = try ExportManifest(destination: destination)
        let library = PhotoLibrary.allAssets()
        var pending: [PHAsset] = []
        library.enumerateObjects { asset, _, _ in
            if !manifest.contains(asset.localIdentifier) {
                pending.append(asset)
            }
        }
        emit(.prepared(total: library.count, alreadyExported: library.count - pending.count))

        var failures = 0
        for asset in pending {
            await gate.waitWhilePaused()
            try Task.checkCancellation()

            let files = AssetFiles(asset: asset)
            do {
                let paths = try await export(files)
                try manifest.recordExport(of: asset.localIdentifier, files: paths)
                emit(.exported(name: files.displayName, fileCount: paths.count))
            } catch {
                if Task.isCancelled {
                    throw CancellationError()
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

    /// Writes all of an item's files and returns their paths relative to the destination.
    /// If any file fails, the ones already written for this item are removed.
    private func export(_ files: AssetFiles) async throws -> [String] {
        guard !files.items.isEmpty else { throw ExportError.noExportableFiles }

        let folder = destination.appending(path: files.folderPath, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        var written: [URL] = []
        do {
            for item in files.items {
                let url = FileManager.default.availableURL(in: folder, for: item.filename)
                try await ResourceWriter.write(item.resource, to: url)
                written.append(url)
            }
        } catch {
            for url in written {
                try? FileManager.default.removeItem(at: url)
            }
            throw error
        }
        return written.map { "\(files.folderPath)/\($0.lastPathComponent)" }
    }
}

private extension FileManager {
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

private extension Error {
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
