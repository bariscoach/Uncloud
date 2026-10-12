import Foundation

/// Downloads the iCloud Photos library into the destination with icloudpd, once for the
/// whole library (by month) or once per album. icloudpd decides what's already downloaded
/// from its own file paths, so the files it writes are never moved or renamed afterwards.
///
/// When only some items are selected, the bridge (`photo_bridge.py`) downloads them instead,
/// with icloudpd's own download function, so they land exactly where icloudpd would put them.
struct ICloudExportEngine: Sendable {
    let destination: URL
    let layout: FolderLayout
    let writesSidecars: Bool
    let appleID: String
    let gate: PauseGate
    var selection: LibrarySelection = .everything
    /// Where selected items were last seen in icloudpd's order (from the browser), to find them quickly.
    var rankHints: [String: Int] = [:]

    /// Downloads between checksum scans while a run is in progress.
    private static let scanInterval = 200

    /// One icloudpd invocation: the folder it fills, relative to the destination ("" for the destination itself).
    private struct HelperRun {
        let folder: String
        let arguments: [String]
    }

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

    private func run(emit: @escaping @Sendable (ExportEvent) -> Void) async throws {
        do {
            let manifest = try ExportManifest(destination: destination)
            try manifest.recordLayout(layout)
            let scanner = ICloudChecksumScanner(destination: destination, manifest: manifest, layout: layout)
            guard selection.isEverything else {
                try await runWithBridge(manifest: manifest, scanner: scanner, emit: emit)
                return
            }
            let runs = try await helperRuns()

            var isPrepared = false
            let prepare: (Int) -> Void = { total in
                if isPrepared {
                    if total > 0 { emit(.totalIncreased(by: total)) }
                } else {
                    isPrepared = true
                    emit(.prepared(total: total, alreadyExported: 0))
                }
            }

            for run in runs {
                await gate.waitWhilePaused()
                try Task.checkCancellation()
                try await perform(run, scanner: scanner, prepare: prepare, isPrepared: { isPrepared }, emit: emit)
            }
            if !isPrepared {
                // No albums, or icloudpd never announced a total: the run is still complete.
                prepare(0)
            }
            manifest.markRunFinished()
        } catch {
            throw mapped(error)
        }
    }

    /// The month layout is one run into the destination; the album layout is one run per album,
    /// each into a folder named the way the PhotoKit export names album folders.
    private func helperRuns() async throws -> [HelperRun] {
        let shared = ["--live-photo-mov-filename-policy", "original", "--log-level", "debug"]
            + (writesSidecars ? ["--xmp-sidecar"] : [])
        let common = ICloudHelperProcess.commonArguments(appleID: appleID)

        guard layout == .album else {
            return [HelperRun(
                folder: "",
                arguments: common + ["-d", destination.path(percentEncoded: false), "--folder-structure", "{:%Y/%m}"] + shared
            )]
        }
        let albums = try await ICloudLibrary.albums(appleID: appleID)
        var usedNames: Set<String> = []
        return albums.map { album in
            let folder = AlbumIndex.uniqueName(for: album, usedNames: &usedNames)
            let directory = destination.appending(path: folder, directoryHint: .isDirectory)
            return HelperRun(
                folder: folder,
                arguments: common + ["-a", album, "-d", directory.path(percentEncoded: false), "--folder-structure", "none"] + shared
            )
        }
    }

    private func perform(
        _ run: HelperRun,
        scanner: ICloudChecksumScanner,
        prepare: (Int) -> Void,
        isPrepared: () -> Bool,
        emit: @escaping @Sendable (ExportEvent) -> Void
    ) async throws {
        let folderURL = run.folder.isEmpty ? destination : destination.appending(path: run.folder, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)

        let (helper, events) = ICloudHelperProcess.nonInteractive(arguments: run.arguments, appleID: appleID)
        let gate = gate
        let pauseTask = Task {
            for await isPaused in gate.changes() {
                if isPaused {
                    // A pause right after launch can arrive before the process exists.
                    while helper.processIdentifier == nil, helper.exitStatus == nil, !Task.isCancelled {
                        try? await Task.sleep(for: .milliseconds(100))
                    }
                    if gate.isPaused {
                        helper.suspend()
                    }
                } else {
                    helper.resume()
                }
            }
        }
        defer { pauseTask.cancel() }

        var downloadsSinceScan = 0
        try await withTaskCancellationHandler {
            for try await event in events {
                switch event {
                case .totalAnnounced(let total):
                    prepare(total ?? 0)
                case .downloaded(let path):
                    if !isPrepared() { prepare(0) }
                    emit(.exported(name: Self.displayName(of: path), fileCount: 1))
                    downloadsSinceScan += 1
                    if downloadsSinceScan >= Self.scanInterval {
                        downloadsSinceScan = 0
                        // Files icloudpd touched in the last few seconds may still be being written.
                        try scanner.scan(folderURL, settledBefore: Date.now.addingTimeInterval(-10))
                    }
                case .alreadyExists:
                    if !isPrepared() { prepare(0) }
                    emit(.skipped)
                default:
                    break
                }
            }
        } onCancel: {
            helper.terminate()
        }
        try Task.checkCancellation()
        try scanner.scan(folderURL, settledBefore: nil)
    }

    // MARK: - Selected items

    /// Downloads the selection through the bridge: one request for the month layout, one per album
    /// otherwise, into the same folders the icloudpd runs use.
    private func runWithBridge(
        manifest: ExportManifest,
        scanner: ICloudChecksumScanner,
        emit: @escaping @Sendable (ExportEvent) -> Void
    ) async throws {
        let bridge = ICloudBridge.shared(appleID: appleID)
        let (mode, ids): (String, Set<String>) = switch selection {
        case .allExcept(let excluded): ("allExcept", excluded)
        case .only(let selected): ("only", selected)
        }

        var runs: [(folder: String, album: String?)] = [("", nil)]
        if layout == .album {
            var usedNames: Set<String> = []
            runs = try await bridge.albums().map { album in
                (AlbumIndex.uniqueName(for: album, usedNames: &usedNames), album)
            }
        }

        var isPrepared = false
        var failures = 0
        for run in runs {
            await gate.waitWhilePaused()
            try Task.checkCancellation()
            if mode == "only", ids.isEmpty {
                break
            }
            let folderURL = run.folder.isEmpty ? destination : destination.appending(path: run.folder, directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
            let request = ICloudBridgeRequest(
                cmd: "download",
                mode: mode,
                ids: ids.sorted(),
                dest: folderURL.path(percentEncoded: false),
                layout: layout == .album ? "album" : "month",
                album: run.album,
                xmp: writesSidecars,
                hints: layout == .album || mode != "only" ? nil : rankHints
            )

            let gate = gate
            let pauseTask = Task {
                for await isPaused in gate.changes() {
                    if isPaused {
                        if gate.isPaused { bridge.suspend() }
                    } else {
                        bridge.resume()
                    }
                }
            }
            defer {
                pauseTask.cancel()
                bridge.resume()
            }

            var runTotal = 0
            var downloadsSinceScan = 0
            try await withTaskCancellationHandler {
                for try await message in try await bridge.download(request) {
                    switch message.event {
                    case "progress":
                        let total = message.total ?? 0
                        if !isPrepared {
                            isPrepared = true
                            emit(.prepared(total: total, alreadyExported: 0))
                        } else if total != runTotal {
                            emit(.totalIncreased(by: total - runTotal))
                        }
                        runTotal = total
                    case "downloaded":
                        let paths = message.paths ?? message.path.map { [$0] } ?? []
                        emit(.exported(name: message.filename ?? Self.displayName(of: message.path ?? ""), fileCount: max(1, paths.count)))
                        downloadsSinceScan += 1
                        if downloadsSinceScan >= Self.scanInterval {
                            downloadsSinceScan = 0
                            try scanner.scan(folderURL, settledBefore: Date.now.addingTimeInterval(-10))
                        }
                    case "skipped":
                        emit(.skipped)
                    case "failed":
                        let reason = message.reason ?? "iCloud reported a problem."
                        try checkDestination(after: reason)
                        failures += 1
                        emit(.failed(name: message.filename ?? message.asset ?? "an item", reason: reason))
                    case "done" where message.cancelled == true:
                        throw CancellationError()
                    default:
                        break
                    }
                }
            } onCancel: {
                // Stops a download mid-file; the bridge restarts on its next request.
                bridge.terminate()
            }
            try Task.checkCancellation()
            try scanner.scan(folderURL, settledBefore: nil)
        }
        if !isPrepared {
            emit(.prepared(total: 0, alreadyExported: 0))
        }
        // Leave the run marked incomplete when items failed, so Resume retries them.
        if failures == 0 {
            manifest.markRunFinished()
        }
    }

    /// icloudpd logs a failed write as an IOError and moves on; a full or missing destination should stop the export instead.
    private func checkDestination(after reason: String) throws {
        let path = destination.path(percentEncoded: false)
        guard FileManager.default.fileExists(atPath: path) else {
            throw ExportError.destinationUnavailable
        }
        guard reason.contains("IOError") || reason.contains("No space left") || reason.contains("Errno 28") else { return }
        let capacity = try? destination.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage
        if let capacity, capacity < 100 * 1024 * 1024 {
            throw ExportError.destinationFull
        }
    }

    private static func displayName(of path: String) -> String {
        let name = (path as NSString).lastPathComponent
        return name.isEmpty ? path : name
    }

    /// Turns helper and file errors into the messages the export screen shows.
    private func mapped(_ error: Error) -> Error {
        if error is CancellationError || Task.isCancelled {
            return CancellationError()
        }
        if let error = error as? ICloudError, error == .signInRequired {
            return error
        }
        if error is ExportError {
            return error
        }
        if error.isOutOfSpace || Self.mentionsOutOfSpace(error) {
            return ExportError.destinationFull
        }
        if !FileManager.default.fileExists(atPath: destination.path(percentEncoded: false)) {
            return ExportError.destinationUnavailable
        }
        return error
    }

    /// icloudpd reports a full disk as Python's `OSError: [Errno 28] No space left on device`.
    private static func mentionsOutOfSpace(_ error: Error) -> Bool {
        guard let error = error as? ICloudError else { return false }
        let text: String
        switch error {
        case .failed(let failure):
            text = failure.message
        case .exited(_, let lastMessage?):
            text = lastMessage
        default:
            return false
        }
        return text.contains("No space left on device") || text.contains("Errno 28")
    }
}

/// Records checksums for files icloudpd has written that the manifest doesn't know yet.
/// Each new file becomes an `icloud:<relative path>` record with its SHA-256.
final class ICloudChecksumScanner {
    static let recordPrefix = "icloud:"

    private let destination: URL
    private let destinationPath: String
    private let manifest: ExportManifest
    private let layout: FolderLayout
    private var knownPaths: Set<String>

    init(destination: URL, manifest: ExportManifest, layout: FolderLayout) {
        self.destination = destination
        destinationPath = Self.normalizedPath(of: destination)
        self.manifest = manifest
        self.layout = layout
        knownPaths = Set(ExportManifest.checksums(in: destination).keys)
    }

    /// Hashes and records every new regular file under `folder`. Skips hidden files and folders
    /// (including `.photo-export`), icloudpd's `.part` downloads, and, when `settledBefore` is set,
    /// files modified after it. Returns how many files were recorded.
    @discardableResult
    func scan(_ folder: URL, settledBefore: Date?) throws -> Int {
        let keys: [URLResourceKey] = [.isRegularFileKey, .contentModificationDateKey]
        guard let enumerator = FileManager.default.enumerator(
            at: folder,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return 0 }

        var recorded = 0
        while let url = enumerator.nextObject() as? URL {
            try Task.checkCancellation()
            guard url.pathExtension.lowercased() != "part",
                  let relativePath = relativePath(of: url),
                  !knownPaths.contains(relativePath),
                  isDownloadPath(relativePath),
                  // Tabs and line breaks would corrupt the manifest's lines.
                  relativePath.rangeOfCharacter(from: .controlCharacters) == nil,
                  let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true
            else { continue }
            if let settledBefore, let modified = values.contentModificationDate, modified > settledBefore {
                continue
            }

            let digest: String
            do {
                digest = try FileHasher.sha256(of: url)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // Removed or unreadable since it was listed; a later scan picks it up if it's back.
                continue
            }
            try manifest.recordChecksums([relativePath: digest])
            try manifest.recordExport(of: Self.recordPrefix + relativePath, files: [relativePath])
            knownPaths.insert(relativePath)
            recorded += 1
        }
        return recorded
    }

    /// In the month layout icloudpd writes only to `YYYY/MM/name`; the user's own files elsewhere
    /// in the destination must not be recorded as downloads. Album runs scan only their own folder.
    private func isDownloadPath(_ relativePath: String) -> Bool {
        guard layout == .month else { return true }
        let parts = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        return parts.count == 3
            && parts[0].count == 4 && parts[0].allSatisfy(\.isASCII) && parts[0].allSatisfy(\.isNumber)
            && parts[1].count == 2 && parts[1].allSatisfy(\.isASCII) && parts[1].allSatisfy(\.isNumber)
    }

    private func relativePath(of url: URL) -> String? {
        let path = Self.normalizedPath(of: url)
        guard path.hasPrefix(destinationPath + "/") else { return nil }
        return String(path.dropFirst(destinationPath.count + 1))
    }

    private static func normalizedPath(of url: URL) -> String {
        var path = url.standardizedFileURL.path(percentEncoded: false)
        while path.count > 1 && path.hasSuffix("/") {
            path.removeLast()
        }
        return path
    }
}
