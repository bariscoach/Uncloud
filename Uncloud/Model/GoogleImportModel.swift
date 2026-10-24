import AppKit
import Foundation
import Observation
import UniformTypeIdentifiers

/// The Google Photos pane's state: the Takeout files the owner chose, and the import that copies them into the backup
/// folder. Owned by `ExportModel`, which can't start an export while an import runs, and which an import can't start
/// during. Both write the manifest.
@MainActor
@Observable
final class GoogleImportModel {
    struct Failure: Equatable, Sendable {
        let name: String
        let reason: String
    }

    struct Summary: Equatable, Sendable {
        let imported: Int
        /// Photos that were already in the backup: the ones an earlier import finished, and the ones this run skipped.
        let alreadyInBackup: Int
        let failedCount: Int
        /// The first failures, up to `SessionRecorder.failureLimit`. `failedCount` counts them all.
        let failures: [Failure]
        /// True when Stop ended the import. Importing again picks up where it stopped.
        let wasStopped: Bool
    }

    enum Phase: Equatable {
        case idle
        /// Reading the Takeout files, before the first photo is copied.
        case scanning
        case importing
        case paused
        case finished(Summary)
        case failed(String)
    }

    /// Why Import to Backup is unavailable, with the sentence the pane shows.
    enum BlockReason: Equatable {
        case noFolder
        case exporting
        case noFiles
        case destinationIssue(String)

        var message: String {
            switch self {
            case .noFolder: "Choose a backup folder in Export Settings first."
            case .exporting: "Wait for the export to finish."
            case .noFiles: "Choose the Takeout files you downloaded first."
            case .destinationIssue(let issue): issue
            }
        }
    }

    /// What the import reads from the app. Closures, so tests can stand in for the export model.
    struct Host {
        let destination: @MainActor () -> URL?
        let destinationIssue: @MainActor () -> String?
        let layout: @MainActor () -> FolderLayout
        /// True while an export runs, or its engine is still stopping.
        let isExporting: @MainActor () -> Bool
    }

    private(set) var inputs: [URL] = []
    /// The byte size of each input file. Folders have none.
    private(set) var sizes: [URL: Int64] = [:]
    private(set) var phase: Phase = .idle
    /// Items in the Takeout files, including the ones an earlier import finished.
    private(set) var total = 0
    /// Items handled so far, including the ones an earlier import finished.
    private(set) var done = 0
    private(set) var imported = 0
    private(set) var skipped = 0
    private(set) var failedCount = 0
    private(set) var failures: [Failure] = []
    /// The newest note from the engine, such as a Takeout part that couldn't be read.
    private(set) var notice: String?
    /// Set once Stop is chosen, until the run has really ended.
    private(set) var isStopping = false
    /// Finished photos that an earlier import had already done, reported when the run started.
    private var alreadyBeforeRun = 0

    @ObservationIgnored let host: Host
    /// Starts the engine. Tests replace it with a fake run.
    @ObservationIgnored var makeRun: @MainActor (TakeoutImporter) -> ExportRun = { $0.start() }
    /// Shows the file panel for `addInputs()`. Tests replace it, so they never open a panel.
    @ObservationIgnored var chooseInputs: @MainActor () -> [URL] = GoogleImportModel.openTakeoutPanel
    /// Called when a run ends, however it ends, so Browse Backup can show the new photos.
    @ObservationIgnored var onFinished: @MainActor () -> Void = {}
    @ObservationIgnored private var gate = PauseGate()
    @ObservationIgnored private var runTask: Task<Void, Never>?
    @ObservationIgnored private var consumeTask: Task<Void, Never>?
    /// Security-scoped URLs this run started accessing, stopped when it ends.
    @ObservationIgnored private var scopedURLs: [URL] = []

    init(host: Host) {
        self.host = host
    }

    // MARK: - State for the view

    var isRunning: Bool {
        switch phase {
        case .scanning, .importing, .paused: true
        case .idle, .finished, .failed: false
        }
    }

    var isPaused: Bool {
        phase == .paused
    }

    /// The backup folder's name, for "Photos go to <name>".
    var destinationName: String? {
        host.destination().map { FileManager.default.displayName(atPath: $0.path(percentEncoded: false)) }
    }

    /// Why Import to Backup is unavailable, or nil when it can start. Nil while a run is going.
    var blockReason: BlockReason? {
        guard !isRunning else { return nil }
        guard host.destination() != nil else { return .noFolder }
        if host.isExporting() { return .exporting }
        if let issue = host.destinationIssue() { return .destinationIssue(issue) }
        if inputs.isEmpty { return .noFiles }
        return nil
    }

    var canStart: Bool {
        !isRunning && blockReason == nil
    }

    /// Items handled, as a share of the total, for the progress bar.
    var fractionComplete: Double {
        total > 0 ? Double(done) / Double(total) : 0
    }

    /// Photos already in the backup, earlier ones and this run's skips together.
    var alreadyInBackup: Int {
        alreadyBeforeRun + skipped
    }

    // MARK: - Choosing files

    /// Adds the files and folders the owner picks. Selection is kept for this session only.
    func addInputs() {
        guard !isRunning else { return }
        for url in chooseInputs() where !inputs.contains(url) {
            inputs.append(url)
            sizes[url] = Self.byteCount(of: url)
        }
    }

    func remove(_ url: URL) {
        guard !isRunning else { return }
        inputs.removeAll { $0 == url }
        sizes[url] = nil
    }

    static func byteCount(of url: URL) -> Int64? {
        (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize.map(Int64.init)
    }

    /// The file panel: Takeout zip files and the folders Finder extracted from them, several at once.
    @MainActor
    static func openTakeoutPanel() -> [URL] {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.zip, .folder]
        panel.prompt = "Choose"
        panel.message = "Choose the .zip files or folders you downloaded from Google Takeout."
        guard panel.runModal() == .OK else { return [] }
        return panel.urls
    }

    // MARK: - Running

    /// Records the folder's layout when it has none, then starts the import. A folder that already has a layout keeps it.
    func start() {
        guard canStart, let destination = host.destination() else { return }
        let layout = host.layout()
        do {
            if ExportManifest.layout(in: destination) == nil {
                try ExportManifest(destination: destination, marksRun: false).recordLayout(layout)
            }
        } catch {
            phase = .failed(error.localizedDescription)
            return
        }

        resetCounts()
        scopedURLs = []
        for url in [destination] + inputs where url.startAccessingSecurityScopedResource() {
            scopedURLs.append(url)
        }
        phase = .scanning

        let gate = PauseGate()
        self.gate = gate
        let importer = TakeoutImporter(
            destination: destination,
            layout: layout,
            inputs: inputs,
            gate: gate,
            places: layout.usesPlaces ? PlaceResolver() : nil
        )
        let run = makeRun(importer)
        runTask = run.task
        let batches = ExportEventBatcher.batches(of: run.events)
        consumeTask = Task { await consume(batches) }
    }

    func pause() {
        guard phase == .importing else { return }
        gate.pause()
        phase = .paused
    }

    func resume() {
        guard phase == .paused else { return }
        phase = .importing
        gate.resume()
    }

    /// Stops the import. Photos already copied stay; the rest are imported by the next run.
    func stop() {
        guard isRunning, !isStopping else { return }
        isStopping = true
        // A paused import has to wake up to see the cancellation.
        gate.resume()
        runTask?.cancel()
    }

    // MARK: - Run events

    private func consume(_ batches: AsyncStream<ExportBatch>) async {
        for await batch in batches {
            apply(batch)
            if let ending = batch.ending {
                finish(ending)
                return
            }
        }
        // The events ended without an ending: the run was given up on.
        finish(.failure(CancellationError()))
    }

    private func apply(_ batch: ExportBatch) {
        if let prepared = batch.prepared {
            total = prepared.total
            alreadyBeforeRun = prepared.alreadyExported
            done = prepared.alreadyExported
            if phase == .scanning {
                phase = .importing
            }
        }
        done += batch.processed
        imported += batch.exported
        skipped += batch.skipped
        failedCount += batch.failed
        let room = SessionRecorder.failureLimit - failures.count
        if room > 0 {
            failures += batch.failures.prefix(room).map { Failure(name: $0.name, reason: $0.reason) }
        }
        if let entry = batch.recentEntries.last, entry.kind == .info {
            notice = entry.message
        }
    }

    private func finish(_ ending: Result<Void, Error>) {
        runTask = nil
        consumeTask = nil
        isStopping = false
        for url in scopedURLs {
            url.stopAccessingSecurityScopedResource()
        }
        scopedURLs = []
        switch ending {
        case .success:
            phase = .finished(summary(stopped: false))
        case .failure(let error) where error is CancellationError:
            phase = .finished(summary(stopped: true))
        case .failure(let error):
            phase = .failed(error.localizedDescription)
        }
        onFinished()
    }

    private func summary(stopped: Bool) -> Summary {
        Summary(
            imported: imported,
            alreadyInBackup: alreadyInBackup,
            failedCount: failedCount,
            failures: failures,
            wasStopped: stopped
        )
    }

    private func resetCounts() {
        total = 0
        done = 0
        imported = 0
        skipped = 0
        failedCount = 0
        failures = []
        notice = nil
        alreadyBeforeRun = 0
    }
}

extension GoogleImportModel.Summary {
    /// "Imported 4,988 photos and videos." The stopped import says how far it got.
    var headline: String {
        let count = imported.formatted()
        if wasStopped {
            return "Import stopped. Imported \(count) so far."
        }
        return imported == 1 ? "Imported 1 photo or video." : "Imported \(count) photos and videos."
    }

    /// "12 were already in your backup.", or nil when none were.
    var alreadyInBackupText: String? {
        guard alreadyInBackup > 0 else { return nil }
        let count = alreadyInBackup.formatted()
        return alreadyInBackup == 1 ? "1 was already in your backup." : "\(count) were already in your backup."
    }
}
