import Foundation

/// Downloads the iCloud Photos library into the destination.
///
/// - The whole library in the month and flat layouts goes through the bridge (`photo_bridge.py`), which
///   downloads with icloudpd's own download function, so files land exactly where icloudpd puts them and a
///   later plain icloudpd run finds them all "already exists". Each item is recorded by asset ID, and the run
///   continues from `.photo-export/resume.json` instead of walking the whole library again (`ICloudResumePlanner`).
///   The `iCloudFullExportsUseBridge` default (on unless set to false) switches this off; the icloudpd process
///   also takes over when the bridge can't start.
/// - The album layout runs icloudpd once per album. icloudpd decides what's already downloaded from its own file
///   paths, so the files it writes are never moved or renamed afterwards.
/// - A partial selection goes through the bridge, by ID.
struct ICloudExportEngine: Sendable {
    let destination: URL
    let layout: FolderLayout
    let writesSidecars: Bool
    let appleID: String
    let gate: PauseGate
    var selection: LibrarySelection = .everything
    /// Where selected items were last seen in icloudpd's order (from the browser), to find them quickly.
    var rankHints: [String: Int] = [:]
    /// Selected items the drive check found already on the drive, or nil when no check ran. After a check,
    /// progress starts from this count, and icloudpd's "already exists" reports aren't counted again: the
    /// check recorded every file at icloudpd's paths, so each one belongs to an item it counted. The album
    /// layout has one run per album, and an item can be in several, so it counts skips as before.
    var alreadyOnDrive: Int?
    /// Items the drive check just found missing or damaged (and forgot), so they're downloaded again even below
    /// the resume point.
    var missingItems: Set<String> = []
    /// Whole-library exports in the month and flat layouts go through the bridge; false runs icloudpd instead.
    var usesBridgeForEverything = ICloudExportEngine.fullExportsUseBridge
    var resumeSettings = ICloudResumeSettings()
    /// A whole-library export only looks for new photos at the top of the library, when a full check was
    /// done recently enough (see `ICloudQuickUpdate`). False runs the full check, as before.
    var quickUpdate = false

    /// The hidden switch for whole-library bridge exports (on unless set to false).
    static let fullExportsUseBridgeKey = "iCloudFullExportsUseBridge"
    static var fullExportsUseBridge: Bool {
        UserDefaults.standard.object(forKey: fullExportsUseBridgeKey) as? Bool ?? true
    }

    /// Downloads between checksum scans while a run is in progress.
    private static let scanInterval = 200

    /// One icloudpd invocation: the folder it fills, relative to the destination ("" for the destination itself).
    private struct HelperRun {
        let folder: String
        let arguments: [String]
    }

    /// Starts the export. Cancelling the run's task stops it; its events then finish once it has stopped.
    func start() -> ExportRun {
        ExportRun.start { emit in try await run(emit: emit) }
    }

    private func run(emit: @escaping @Sendable (ExportEvent) -> Void) async throws {
        do {
            let manifest = try ExportManifest(destination: destination)
            try manifest.recordLayout(layout)
            let scanner = ICloudChecksumScanner(destination: destination, manifest: manifest, layout: layout)
            guard selection.isEverything else {
                emit(.continuation(.init(strategy: .selection)))
                try await runWithBridge(manifest: manifest, scanner: scanner, emit: emit)
                return
            }
            var fallbackReason: String?
            if layout != .album, usesBridgeForEverything {
                let bridge = ICloudBridge.shared(appleID: appleID)
                do {
                    try await bridge.ready()
                } catch {
                    guard Self.isStartFailure(error) else { throw error }
                    fallbackReason = "A faster resume wasn’t possible, so Uncloud checked the whole library"
                }
                if fallbackReason == nil {
                    try await runEverythingWithBridge(bridge, manifest: manifest, scanner: scanner, emit: emit)
                    return
                }
            }
            emit(.continuation(.init(strategy: .fullWalk, startRank: nil, fallbackReason: fallbackReason)))
            let runs = try await helperRuns()

            let onDriveAtStart: Int? = layout == .album ? nil : alreadyOnDrive.map { max(0, $0) }
            var isPrepared = false
            var skips = SkipAbsorber(limit: onDriveAtStart == nil ? 0 : .max)
            let prepare: (Int) -> Void = { total in
                if isPrepared {
                    if total > 0 { emit(.totalIncreased(by: total)) }
                } else {
                    isPrepared = true
                    // Never more on the drive than icloudpd says there is, so progress can't pass 100 %.
                    let onDrive = onDriveAtStart.map { total > 0 ? min($0, total) : $0 } ?? 0
                    emit(.prepared(total: max(total, onDrive), alreadyExported: onDrive))
                }
            }

            for run in runs {
                await gate.waitWhilePaused()
                try Task.checkCancellation()
                try await perform(run, scanner: scanner, skips: &skips, prepare: prepare, isPrepared: { isPrepared }, emit: emit)
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
                arguments: common + ["-d", destination.path(percentEncoded: false), "--folder-structure", layout.icloudpdFolderStructure] + shared
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
        skips: inout SkipAbsorber,
        prepare: (Int) -> Void,
        isPrepared: () -> Bool,
        emit: @escaping @Sendable (ExportEvent) -> Void
    ) async throws {
        let folderURL = run.folder.isEmpty ? destination : destination.appending(path: run.folder, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)

        let (helper, events) = ICloudHelperProcess.nonInteractive(arguments: run.arguments, appleID: appleID)
        // icloudpd is this run's own process, so pausing stops it with SIGSTOP.
        let gate = gate
        let pauseTask = Task {
            for await _ in gate.changes() {
                if gate.isPaused {
                    // A pause right after launch can arrive before the process exists.
                    while helper.processIdentifier == nil, helper.exitStatus == nil, !Task.isCancelled {
                        try? await Task.sleep(for: .milliseconds(100))
                    }
                    if gate.isPaused, !Task.isCancelled, !helper.isTerminating {
                        helper.suspend()
                    }
                } else {
                    helper.resume()
                }
            }
        }
        /// Ends the pause task before the run does, so a late pause can't stop the helper, and
        /// leaves the helper running if it was stopped.
        func endPausing() async {
            pauseTask.cancel()
            await pauseTask.value
            helper.resume()
        }

        var downloadsSinceScan = 0
        // In the flat layout the user's own files sit next to the downloads: only the files icloudpd reports
        // are recorded and hashed, never the folder's other files (plan 7c).
        let isFlat = layout == .flat
        var reported: [String] = []
        do {
            try await withTaskCancellationHandler {
                for try await event in events {
                    switch event {
                    case .totalAnnounced(let total):
                        prepare(total ?? 0)
                    case .downloaded(let path):
                        if !isPrepared() { prepare(0) }
                        let bytes = ExportEngine.totalSize(of: [URL(filePath: path)])
                        emit(.exported(name: Self.displayName(of: path), fileCount: 1, bytes: bytes))
                        if isFlat {
                            reported += relativePaths([path])
                        }
                        downloadsSinceScan += 1
                        if downloadsSinceScan >= Self.scanInterval {
                            downloadsSinceScan = 0
                            if isFlat {
                                scanner.noteReported(reported)
                                try scanner.hash(reported)
                                reported = []
                            } else {
                                // Files icloudpd touched in the last few seconds may still be being written.
                                try scanner.scan(folderURL, settledBefore: Date.now.addingTimeInterval(-10))
                            }
                        }
                    case .alreadyExists(let path):
                        if !isPrepared() { prepare(0) }
                        if isFlat {
                            reported += relativePaths([path])
                        }
                        if !skips.absorb() {
                            emit(.skipped)
                        }
                    default:
                        break
                    }
                }
            } onCancel: {
                helper.terminate()
            }
            try Task.checkCancellation()
        } catch {
            await endPausing()
            // Whatever ended the run (cancel, a failed write or scan, or the helper itself), icloudpd is
            // stopped and waited for before the error propagates: the run only ends once it has exited,
            // so a new run can't overlap it. SIGKILL follows SIGTERM after 5 seconds, so this is bounded.
            helper.terminate()
            _ = await helper.waitUntilExit(timeout: .seconds(6))
            throw error
        }
        await endPausing()
        if isFlat {
            scanner.noteReported(reported)
            try scanner.hash(reported)
        } else {
            try scanner.scan(folderURL, settledBefore: nil)
        }
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

        // Items already recorded by ID are counted from the start, and their skips aren't counted again. Not in
        // the album layout, where an item can be in several albums' runs.
        var known: Set<String> = []
        var alreadyCounted = 0
        if layout != .album {
            known = Self.knownItems(in: destination, layout: layout)
            alreadyCounted = switch selection {
            case .only(let selected): selected.count { known.contains($0) }
            case .allExcept(let excluded): known.count { !excluded.contains($0) }
            }
        }
        var tally = BridgeTally(known: known, alreadyCounted: alreadyCounted)
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
                layout: layout == .album ? "album" : (layout == .flat ? "none" : "month"),
                album: run.album,
                xmp: writesSidecars,
                hints: layout == .album || mode != "only" ? nil : rankHints
            )

            let download = try await bridge.download(request)
            // The bridge is shared with browsing, so it's never stopped with a signal: the download
            // is held between chunks instead, and browsing goes on.
            let gate = gate
            let pauseTask = Task {
                for await _ in gate.changes() {
                    if gate.isPaused {
                        bridge.pauseDownload(download.id)
                    } else {
                        bridge.resumeDownload(download.id)
                    }
                }
            }

            do {
                try await receive(download, folderURL: folderURL, manifest: manifest, scanner: scanner,
                                  tally: &tally, failures: &failures, emit: emit)
                try Task.checkCancellation()
            } catch {
                pauseTask.cancel()
                // However the run ended, leaving the stream asks the bridge to stop the download after its
                // current chunk (removing that file's partial download). Report the end once it has, so a
                // new run can't overlap it. The bridge keeps running: browsing shares it, and restarting it
                // would mean signing in again.
                await bridge.waitUntilEnded(download.id, timeout: .seconds(5))
                await pauseTask.value
                throw error
            }
            pauseTask.cancel()
            await pauseTask.value
            if layout == .flat {
                try scanner.hashRecorded()
            } else {
                try scanner.scan(folderURL, settledBefore: nil)
            }
        }
        if !tally.isPrepared {
            emit(.prepared(total: 0, alreadyExported: 0))
        }
        // Leave the run marked incomplete when items failed, so Resume retries them.
        if failures == 0 {
            manifest.markRunFinished()
        }
    }

    /// How a bridge export counts: whether it has announced its total, and which items were on the drive
    /// (recorded by ID) before it started, which progress already includes.
    private struct BridgeTally {
        let known: Set<String>
        let alreadyCounted: Int
        var isPrepared = false
    }

    /// Turns one bridge download's messages into export events, and records each finished item by its asset
    /// ID with every file it has on the drive (`icloud-id:`). An item that failed partway, such as a Live Photo
    /// whose movie didn't download, is recorded as partial instead, and its files are kept out of the checksum
    /// scanner's path records, so it never counts as done.
    private func receive(
        _ download: ICloudBridgeDownload,
        folderURL: URL,
        manifest: ExportManifest,
        scanner: ICloudChecksumScanner,
        tally: inout BridgeTally,
        failures: inout Int,
        emit: @escaping @Sendable (ExportEvent) -> Void
    ) async throws {
        var runTotal = 0
        var downloadsSinceScan = 0
        for try await message in download.messages {
            if message.event == "done", message.cancelled == true {
                throw CancellationError()
            }
            guard let event = ICloudBridgeDownloadEvent(message) else { continue }
            switch event {
            case .progress(_, let total):
                if !tally.isPrepared {
                    tally.isPrepared = true
                    let counted = min(tally.alreadyCounted, total)
                    emit(.prepared(total: total, alreadyExported: counted))
                } else if total != runTotal {
                    emit(.totalIncreased(by: total - runTotal))
                }
                runTotal = total
            case .downloaded(let item):
                let files = relativePaths(item.files)
                try record(item, files: files, manifest: manifest, scanner: scanner)
                let bytes = ExportEngine.totalSize(of: item.paths.map { URL(filePath: $0) })
                emit(.exported(name: item.filename, fileCount: max(1, item.paths.count), bytes: bytes))
                downloadsSinceScan += 1
                if downloadsSinceScan >= Self.scanInterval {
                    downloadsSinceScan = 0
                    if layout == .flat {
                        try scanner.hashRecorded()
                    } else {
                        try scanner.scan(folderURL, settledBefore: Date.now.addingTimeInterval(-10))
                    }
                }
            case .skipped(let item):
                try record(item, files: relativePaths(item.files), manifest: manifest, scanner: scanner)
                // Already counted when the run started.
                if !tally.known.contains(item.asset) {
                    emit(.skipped)
                }
            case .failed(let asset, _, let filename, let reason):
                try checkDestination(after: reason)
                let written = relativePaths(message.paths ?? [])
                if !written.isEmpty {
                    scanner.exclude(written)
                    try? manifest.recordPartialICloudItem(id: asset, paths: written)
                }
                failures += 1
                emit(.failed(name: filename, reason: reason))
            case .done, .walked:
                break
            }
        }
    }

    /// Records a finished item by ID. Its files then get checksums from the scanner, but no path records.
    private func record(_ item: ICloudBridgeItemResult, files: [String], manifest: ExportManifest,
                        scanner: ICloudChecksumScanner) throws {
        guard !files.isEmpty else { return }
        do {
            try manifest.recordICloudItem(id: item.asset, paths: files)
        } catch ManifestError.unrecordableField {
            // A name the manifest can't hold; the scanner records it by path, as before.
            return
        }
        scanner.noteRecordedByID(files)
    }

    /// The bridge's absolute paths, relative to the destination. Paths outside it are dropped.
    private func relativePaths(_ paths: [String]) -> [String] {
        let roots = Set([destination.standardizedFileURL, destination.resolvingSymlinksInPath()]
            .map { ICloudChecksumScanner.normalizedPath(of: $0) })
        return paths.compactMap { path in
            let url = URL(filePath: path)
            for candidate in [ICloudChecksumScanner.normalizedPath(of: url),
                              ICloudChecksumScanner.normalizedPath(of: url.resolvingSymlinksInPath())] {
                for root in roots where candidate.hasPrefix(root + "/") {
                    let relative = String(candidate.dropFirst(root.count + 1))
                    return ExportManifest.isSafeRelativePath(relative) ? relative : nil
                }
            }
            return nil
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

// MARK: - The whole library through the bridge

extension ICloudExportEngine {
    /// Errors that mean the bridge itself couldn't run, so icloudpd takes over. Apple's answers (throttling,
    /// sign-in, a lost connection) aren't: icloudpd would get the same.
    static func isStartFailure(_ error: Error) -> Bool {
        switch error as? ICloudError {
        case .helperMissing?, .exited?, .interrupted?: true
        default: false
        }
    }

    /// Items recorded by asset ID whose files are where this layout puts them. Items saved in another layout
    /// don't count: icloudpd only looks at the new layout's paths, so they're downloaded again (plan 7e).
    static func knownItems(in destination: URL, layout: FolderLayout) -> Set<String> {
        Set(ExportManifest.iCloudItems(in: destination).filter { ICloudDownloadPaths.isItem(paths: $0.value, in: layout) }.keys)
    }

    /// The whole library, by month or in one folder, through the bridge. Without a usable resume point: a walk
    /// from rank 0. With one: new items found at the top first (by ID), then the walk from just past the anchor
    /// to the end, then the closing walk from rank 0 back down to the anchor, so a run that gets through all of
    /// it has visited every rank (see `ICloudResumePlanner`). Saves the next resume point every few hundred
    /// items and however the run ends.
    func runEverythingWithBridge(
        _ bridge: ICloudBridge,
        manifest: ExportManifest,
        scanner: ICloudChecksumScanner,
        emit: @escaping @Sendable (ExportEvent) -> Void
    ) async throws {
        let libraryCount = try await bridge.count()
        let known = Self.knownItems(in: destination, layout: layout)
        let account = ExportSession.accountHash(appleID: appleID)
        let now = Date()
        let stored = ICloudResumePoint.load(in: destination)
        let previous = stored.flatMap { $0.account == account && $0.layout == layout.rawValue ? $0 : nil }
        if quickUpdate {
            let eligible = ICloudQuickUpdate.isEligible(
                point: previous, account: account, layout: layout, known: known, missing: missingItems.subtracting(known),
                now: now, maxAge: resumeSettings.fullCheckInterval
            )
            if eligible {
                let quick = try await ICloudQuickUpdate.plan(
                    libraryCount: libraryCount, known: known, settings: resumeSettings,
                    fetch: { offset, limit in try await bridge.page(offset: offset, limit: limit).map(\.id) }
                )
                switch quick {
                case .only(let items):
                    try await runQuickUpdate(items, bridge: bridge, manifest: manifest, scanner: scanner, known: known, emit: emit)
                    return
                case .fullCheck(let reason):
                    emit(.note(reason))
                }
            } else if !known.isEmpty {
                // Nothing to look for quickly when nothing was exported before; a first export is just a full check.
                emit(.note(ICloudQuickUpdate.reasonDue))
            }
        }
        let plan = try await ICloudResumePlanner.plan(
            .init(point: previous, account: account, layout: layout, now: now, libraryCount: libraryCount,
                  known: known, missing: missingItems.subtracting(known), settings: resumeSettings),
            fetch: { offset, limit in try await bridge.page(offset: offset, limit: limit).map(\.id) }
        )

        var coverage: ICloudCoverage
        var only: [String: Int] = [:]
        var startRank = 0
        /// The closing walk stops here: the anchor the walk continued from.
        var closingStop: String?
        switch plan {
        case .fullWalk(let reason):
            emit(.continuation(.init(strategy: .fullWalk, startRank: 0, fallbackReason: reason)))
            if reason != nil {
                emit(.note("Your library changed since the last export, so Uncloud is checking all of it. Photos already in your backup are skipped."))
            }
            coverage = ICloudCoverage(libraryCount: libraryCount, base: nil)
        case .fromRank(let from):
            emit(.continuation(.init(strategy: .fromRank, startRank: from.startRank, fallbackReason: nil)))
            let newText = from.newItems == 0 ? "" : ", after \(from.newItems.formatted()) new \(from.newItems == 1 ? "photo" : "photos")"
            emit(.note("Continuing from photo \(min(from.startRank + 1, libraryCount).formatted()) of \(libraryCount.formatted())\(newText)."))
            coverage = ICloudCoverage(libraryCount: libraryCount, base: .init(id: from.anchorID, rank: from.anchorRank))
            only = from.only
            startRank = from.startRank
            closingStop = from.anchorID
        }

        // Progress starts from what the drive check found; it never passes the total.
        let onDrive = min(max(0, alreadyOnDrive ?? known.count), max(libraryCount, known.count))
        var total = max(libraryCount, onDrive)
        var processed = onDrive
        emit(.prepared(total: total, alreadyExported: onDrive))
        // Files from icloudpd runs and older versions have no ID record; the check counted them by path.
        var legacySkips = SkipAbsorber(limit: max(0, onDrive - known.count))
        func count(_ event: ExportEvent) {
            processed += 1
            if processed > total {
                emit(.totalIncreased(by: processed - total))
                total = processed
            }
            emit(event)
        }

        let destination = destination
        let layout = layout
        var visitedEverything: Date?
        // The last complete walk's gap (see `ICloudResumePoint.unlistedCount`); kept until this run completes one.
        var unlistedCount = previous?.unlistedCount
        func savePoint() {
            guard let point = coverage.point(account: account, layout: layout, previous: previous,
                                             visitedEverything: visitedEverything, unlistedCount: unlistedCount, now: Date()) else { return }
            try? point.save(in: destination)
        }

        var failures = 0
        var pendingHashes: [String] = []
        var sinceHash = 0
        /// Items this run has finished, so a later walk in the same run passes over them without a file check.
        var doneThisRun: Set<String> = []
        func finished(_ item: ICloudBridgeItemResult, downloaded: Bool) throws {
            let files = relativePaths(item.files)
            try record(item, files: files, manifest: manifest, scanner: scanner)
            pendingHashes += files
            if downloaded {
                let bytes = ExportEngine.totalSize(of: item.paths.map { URL(filePath: $0) })
                count(.exported(name: item.filename, fileCount: max(1, item.paths.count), bytes: bytes))
            } else if !known.contains(item.asset) && !doneThisRun.contains(item.asset) && !legacySkips.absorb() {
                count(.skipped)
            }
            doneThisRun.insert(item.asset)
            sinceHash += 1
            if sinceHash >= Self.scanInterval {
                sinceHash = 0
                try scanner.hash(pendingHashes)
                pendingHashes = []
            }
        }
        func failed(_ message: ICloudBridgeMessage, asset: String, filename: String, reason: String) throws {
            try checkDestination(after: reason)
            let written = relativePaths(message.paths ?? [])
            if !written.isEmpty {
                scanner.exclude(written)
                try? manifest.recordPartialICloudItem(id: asset, paths: written)
            }
            failures += 1
            count(.failed(name: filename, reason: reason))
        }

        // Built when a download starts and dropped once its request is sent: the excluded IDs (a few MB for a
        // large library) aren't held for the length of the download.
        let options = { (mode: ICloudBridgeDownloadOptions.Mode, ids: [String], hints: [String: Int]?, start: Int, stopAt: String?) in
            ICloudBridgeDownloadOptions(
                mode: mode, ids: ids, destination: destination, layout: layout == .flat ? .none : .month,
                writesSidecars: writesSidecars, rankHints: hints, startRank: start, stopAt: stopAt
            )
        }

        do {
            // New items at the top, by ID with their current ranks.
            if !only.isEmpty {
                try await download({ options(.only, only.keys.sorted(), only, 0, nil) }, bridge: bridge) { message, event in
                    switch event {
                    case .downloaded(let item), .skipped(let item):
                        try finished(item, downloaded: { if case .downloaded = event { true } else { false } }())
                    case .failed(let asset, _, let filename, let reason):
                        try failed(message, asset: asset, filename: filename, reason: reason)
                    default:
                        break
                    }
                }
            }

            // Then the walk, from just past the anchor (or from the top). Items on the drive cost no file check.
            // When the anchor is the last item, there's nothing past it, so the IDs aren't sent at all.
            var sinceSave = 0
            var walkFailed = false
            if startRank < libraryCount {
                try await download({ options(.allExcept, known.union(doneThisRun).sorted(), nil, startRank, nil) }, bridge: bridge) { message, event in
                    switch event {
                    case .downloaded(let item), .skipped(let item):
                        try finished(item, downloaded: { if case .downloaded = event { true } else { false } }())
                        coverage.finished(asset: item.asset, rank: item.rank)
                        sinceSave += 1
                        if sinceSave >= Self.scanInterval {
                            sinceSave = 0
                            savePoint()
                        }
                    case .walked(let rank):
                        emit(.checked(done: min(rank + 1, libraryCount), total: libraryCount))
                    case .failed(let asset, _, let filename, let reason):
                        coverage.failed()
                        walkFailed = true
                        try failed(message, asset: asset, filename: filename, reason: reason)
                    default:
                        break
                    }
                }
            }
            // The walk reached the end of the library: the last item is the anchor, even when it was already there.
            // Not when the library's size changed during the walk: a removal above a page boundary can hide an
            // item from it, so the end isn't recorded and the anchor stays where the walk last finished an item.
            let endCount = (try? await bridge.count()) ?? -1
            if !walkFailed, !coverage.isFrozen, endCount == libraryCount, endCount > 0,
               let last = try? await bridge.page(offset: endCount - 1, limit: 1).first {
                coverage.reachedEnd(anchor: .init(id: last.id, rank: endCount - 1), libraryCount: endCount)
            }
            savePoint()

            // The closing walk: everything above the anchor again, from rank 0, since anything can have changed
            // there since the walk last went through it. It runs even when items failed, so the rest of the
            // library is always gone through; it never moves R (the failed item stays where the next run starts).
            if let closingStop {
                try await download({ options(.allExcept, known.union(doneThisRun).sorted(), nil, 0, closingStop) }, bridge: bridge) { message, event in
                    switch event {
                    case .downloaded(let item), .skipped(let item):
                        try finished(item, downloaded: { if case .downloaded = event { true } else { false } }())
                    case .walked(let rank):
                        emit(.checked(done: min(rank + 1, libraryCount), total: libraryCount))
                    case .failed(let asset, _, let filename, let reason):
                        try failed(message, asset: asset, filename: filename, reason: reason)
                    default:
                        break
                    }
                }
            }
            // Every rank was visited in this run. Not when the library's size changed meanwhile: a walk can't be
            // sure it saw every item of a library that changed under it (the next run goes through it again).
            let finalCount = closingStop == nil ? endCount : ((try? await bridge.count()) ?? -1)
            if finalCount == libraryCount && endCount == libraryCount {
                visitedEverything = now
            }
        } catch {
            savePoint()
            _ = try? scanner.hash(pendingHashes)
            throw error
        }
        // A complete walk with nothing failed: the count beyond what the library lists is what can never be exported.
        if visitedEverything != nil, failures == 0 {
            unlistedCount = max(0, libraryCount - Self.knownItems(in: destination, layout: layout).count)
        }
        savePoint()
        try scanner.hash(pendingHashes)
        // Leave the run marked incomplete when items failed, so Resume retries them.
        if failures == 0 {
            manifest.markRunFinished()
        }
    }

    /// A quick update: downloads the new items found at the top of the library, by ID, and nothing else. It doesn't
    /// walk, and it never saves a resume point, so the last full check's point and `lastFullWalkAt` stay as they were.
    private func runQuickUpdate(
        _ items: [String: Int],
        bridge: ICloudBridge,
        manifest: ExportManifest,
        scanner: ICloudChecksumScanner,
        known: Set<String>,
        emit: @escaping @Sendable (ExportEvent) -> Void
    ) async throws {
        emit(.continuation(.init(strategy: .quick, startRank: nil, fallbackReason: nil)))
        // Progress starts from what is on the drive already, as in a full check.
        let onDrive = max(0, alreadyOnDrive ?? known.count)
        emit(.prepared(total: onDrive + items.count, alreadyExported: onDrive))
        guard !items.isEmpty else {
            emit(.note("No new photos since your last export."))
            manifest.markRunFinished()
            return
        }
        emit(.note("Looking for new photos only. Your backup folder is checked in full about once a month."))

        var failures = 0
        var pendingHashes: [String] = []
        // Files from icloudpd runs and older versions have no ID record; the check counted them by path.
        var legacySkips = SkipAbsorber(limit: max(0, onDrive - known.count))
        do {
            try await download({
                ICloudBridgeDownloadOptions(
                    mode: .only, ids: items.keys.sorted(), destination: destination, layout: layout == .flat ? .none : .month,
                    writesSidecars: writesSidecars, rankHints: items, startRank: 0, stopAt: nil
                )
            }, bridge: bridge) { message, event in
                switch event {
                case .downloaded(let item):
                    let files = relativePaths(item.files)
                    try record(item, files: files, manifest: manifest, scanner: scanner)
                    pendingHashes += files
                    let bytes = ExportEngine.totalSize(of: item.paths.map { URL(filePath: $0) })
                    emit(.exported(name: item.filename, fileCount: max(1, item.paths.count), bytes: bytes))
                case .skipped(let item):
                    let files = relativePaths(item.files)
                    try record(item, files: files, manifest: manifest, scanner: scanner)
                    pendingHashes += files
                    if !legacySkips.absorb() {
                        emit(.skipped)
                    }
                case .failed(let asset, _, let filename, let reason):
                    try checkDestination(after: reason)
                    let written = relativePaths(message.paths ?? [])
                    if !written.isEmpty {
                        scanner.exclude(written)
                        try? manifest.recordPartialICloudItem(id: asset, paths: written)
                    }
                    failures += 1
                    emit(.failed(name: filename, reason: reason))
                default:
                    break
                }
            }
        } catch {
            _ = try? scanner.hash(pendingHashes)
            throw error
        }
        try scanner.hash(pendingHashes)
        // Leave the run marked incomplete when items failed, so Resume retries them.
        if failures == 0 {
            manifest.markRunFinished()
        }
    }

    /// Runs one bridge download to its end, held while the export is paused, and hands each message to `handle`
    /// with its typed event. Throws `CancellationError` when the download was cancelled, and the bridge's
    /// run-ending error (a throttle, a lost connection) as it is; returns once the bridge has stopped it.
    private func download(
        _ options: () -> ICloudBridgeDownloadOptions,
        bridge: ICloudBridge,
        handle: (ICloudBridgeMessage, ICloudBridgeDownloadEvent) throws -> Void
    ) async throws {
        await gate.waitWhilePaused()
        try Task.checkCancellation()
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let download = try await bridge.download(options().request)
        let gate = gate
        let pauseTask = Task {
            for await _ in gate.changes() {
                if gate.isPaused {
                    bridge.pauseDownload(download.id)
                } else {
                    bridge.resumeDownload(download.id)
                }
            }
        }
        do {
            for try await message in download.messages {
                guard let event = ICloudBridgeDownloadEvent(message) else { continue }
                if case .done(_, _, _, true) = event {
                    throw CancellationError()
                }
                try handle(message, event)
            }
            try Task.checkCancellation()
        } catch {
            pauseTask.cancel()
            // Leaving the stream asks the bridge to stop the download after its current chunk; the run ends
            // only once it has, so a new run can't overlap it. The bridge keeps running for browsing.
            await bridge.waitUntilEnded(download.id, timeout: .seconds(5))
            await pauseTask.value
            throw error
        }
        pauseTask.cancel()
        await pauseTask.value
    }
}

/// Swallows icloudpd's "already exists" reports for items the drive check already counted, so they aren't
/// counted a second time; reports past `limit` are counted as skips.
struct SkipAbsorber {
    let limit: Int
    private(set) var absorbed = 0

    init(limit: Int) {
        self.limit = limit
    }

    /// True if this skip was already counted.
    mutating func absorb() -> Bool {
        guard absorbed < limit else { return false }
        absorbed += 1
        return true
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
    /// Files of items that failed partway: never recorded as downloads by this scanner.
    private var excludedPaths: Set<String> = []
    /// Files already recorded under an asset ID: they get a checksum, but no `icloud:` path record.
    private var idPaths: Set<String> = []
    /// Flat layout: files icloudpd reported writing or finding. Only these and `idPaths` are ever recorded there.
    private var reportedPaths: Set<String> = []

    init(destination: URL, manifest: ExportManifest, layout: FolderLayout) {
        self.destination = destination
        destinationPath = Self.normalizedPath(of: destination)
        self.manifest = manifest
        self.layout = layout
        knownPaths = Set(ExportManifest.checksums(in: destination).keys)
    }

    /// Keeps these files (relative paths) out of every later scan's records.
    func exclude(_ relativePaths: [String]) {
        excludedPaths.formUnion(relativePaths)
    }

    /// These files are recorded under an asset ID already; scans add only their checksums.
    func noteRecordedByID(_ relativePaths: [String]) {
        idPaths.formUnion(relativePaths)
        excludedPaths.subtract(relativePaths)
    }

    /// Files icloudpd reported (relative paths): in the flat layout, the only unrecorded files a scan may record.
    func noteReported(_ relativePaths: [String]) {
        reportedPaths.formUnion(relativePaths)
    }

    /// Hashes and records the given files (relative paths) that have no checksum yet, without listing any
    /// folder. Files recorded by ID get only a checksum; others an `icloud:` record too. Returns how many.
    @discardableResult
    func hash(_ relativePaths: [String]) throws -> Int {
        var recorded = 0
        for relativePath in relativePaths {
            try Task.checkCancellation()
            guard !knownPaths.contains(relativePath),
                  !excludedPaths.contains(relativePath),
                  ExportManifest.isSafeRelativePath(relativePath),
                  relativePath.rangeOfCharacter(from: .controlCharacters) == nil
            else { continue }
            let url = destination.appending(path: relativePath, directoryHint: .notDirectory)
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            let digest: String
            do {
                digest = try FileHasher.sha256(of: url)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                continue
            }
            try manifest.recordChecksums([relativePath: digest])
            if !idPaths.contains(relativePath) {
                try manifest.recordExport(of: Self.recordPrefix + relativePath, files: [relativePath])
            }
            knownPaths.insert(relativePath)
            recorded += 1
        }
        return recorded
    }

    /// Hashes the files recorded by ID so far that have no checksum yet.
    @discardableResult
    func hashRecorded() throws -> Int {
        try hash(idPaths.subtracting(knownPaths).sorted())
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
                  !excludedPaths.contains(relativePath),
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
            if !idPaths.contains(relativePath) {
                try manifest.recordExport(of: Self.recordPrefix + relativePath, files: [relativePath])
            }
            knownPaths.insert(relativePath)
            recorded += 1
        }
        return recorded
    }

    /// In the month layout icloudpd writes only to `YYYY/MM/name`; the user's own files elsewhere
    /// in the destination must not be recorded as downloads. Album runs scan only their own folder.
    /// In the flat layout only files the engine reported are downloads (plan 7c).
    private func isDownloadPath(_ relativePath: String) -> Bool {
        switch layout {
        case .month: ICloudDownloadPaths.isMonthPath(relativePath)
        case .flat: idPaths.contains(relativePath) || reportedPaths.contains(relativePath)
        default: true
        }
    }

    private func relativePath(of url: URL) -> String? {
        let path = Self.normalizedPath(of: url)
        guard path.hasPrefix(destinationPath + "/") else { return nil }
        return String(path.dropFirst(destinationPath.count + 1))
    }

    static func normalizedPath(of url: URL) -> String {
        var path = url.standardizedFileURL.path(percentEncoded: false)
        while path.count > 1 && path.hasSuffix("/") {
            path.removeLast()
        }
        return path
    }
}
