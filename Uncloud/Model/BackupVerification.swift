import Foundation

/// Checks the backup and, when asked, re-exports items with problems. Two kinds of check:
/// - **Quick**: every recorded file is there and the right size, from one listing per folder. Seconds.
/// - **Full**: every file is read and compared with its checksum. Hours on a large backup. It keeps a checkpoint, so
///   a stopped full check continues where it stopped.
@MainActor
@Observable
final class BackupVerification {
    struct Summary {
        let destination: URL
        let checkedFileCount: Int
        let verifiedCount: Int
        let damagedCount: Int
        let unverifiableCount: Int
        /// Nil when the library couldn't be read.
        let notBackedUpCount: Int?
        /// Missing or damaged files, up to `affectedFileLimit`.
        let affectedFiles: [String]
        let affectedFileCount: Int
        /// Damaged or unverifiable items that are still in the library, so they can be exported again.
        let reexportIDs: Set<String>
        /// Damaged or unverifiable items that are no longer in the library. Their files are never touched.
        let notInLibraryCount: Int
        /// True when this pass continued from a saved checkpoint.
        let resumedFromCheckpoint: Bool
        /// Set when a checkpoint existed but no longer matched the export records, so the check started over.
        let restartReason: String?
    }

    struct QuickSummary: Equatable {
        let destination: URL
        let report: QuickVerifyReport
        /// Missing, empty or changed files, up to `affectedFileLimit`.
        let affectedFiles: [String]
        let affectedFileCount: Int
    }

    /// How a check was asked to run.
    enum Check: Equatable {
        case quick
        case full
        /// Only these items (a quick check's problems). Never uses the checkpoint.
        case items(Set<String>)
    }

    /// What a run is doing right now. `done` counts from the start of the pass, including files a resumed pass already
    /// had, so the rate is measured from `baseline`.
    struct Progress: Equatable {
        var check: Check
        var done: Int
        var total: Int
        var bytesRead: Int64
        var startedAt: Date
        var baseline: Int

        /// Seconds left at the rate measured in this run, or nil until there's enough to measure.
        func secondsRemaining(now: Date) -> TimeInterval? {
            VerifyEstimate.secondsRemaining(
                done: done, baseline: baseline, total: total, elapsed: now.timeIntervalSince(startedAt)
            )
        }
    }

    /// What the saved full-check checkpoint means for the next full check.
    enum SavedCheck: Equatable {
        case none
        /// The checkpoint still matches the export records: a full check continues from here.
        case resumable(percentDone: Int, checkedFiles: Int)
        /// The checkpoint no longer matches the export records: the next full check starts over.
        case stale
    }

    enum State {
        case ready
        case checking(Progress)
        case quickFinished(QuickSummary)
        case finished(Summary)
        case failed(String)
        case reexporting
        case reexported(message: String, isProblem: Bool)
    }

    static let affectedFileLimit = 20

    private(set) var state: State
    /// The saved full check, read when the sheet opens and again after a full check stops or finishes.
    private(set) var savedCheck: SavedCheck
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var run = 0
    private let model: ExportModel

    /// `initialState` and `savedCheck` are for previews and snapshot tests.
    init(model: ExportModel, initialState: State = .ready, savedCheck: SavedCheck? = nil) {
        self.model = model
        state = initialState
        self.savedCheck = .none
        if let savedCheck {
            self.savedCheck = savedCheck
        } else {
            refreshSavedCheck()
        }
    }

    var isBusy: Bool {
        switch state {
        case .checking, .reexporting: true
        default: false
        }
    }

    var isChecking: Bool {
        if case .checking = state { true } else { false }
    }

    var canStart: Bool {
        !isBusy && !model.isExporting && !model.isEngineRunning && model.destination != nil && model.destinationIssue == nil
    }

    /// Whether a full check would continue from a saved checkpoint.
    var canContinueFullCheck: Bool {
        if case .resumable = savedCheck { true } else { false }
    }

    /// Clears an earlier result so the sheet opens at the start, and reads the saved full check.
    func reset() {
        guard !isBusy else { return }
        state = .ready
        refreshSavedCheck()
    }

    /// Reads the saved full check for the current destination. Skipped while a check runs.
    func refreshSavedCheck() {
        guard !isChecking, let destination = model.destination?.url else {
            savedCheck = .none
            return
        }
        savedCheck = Self.savedCheck(for: destination, store: .standard(for: destination))
    }

    /// Reads the checkpoint at `store` against the journal of `destination`.
    nonisolated static func savedCheck(for destination: URL, store: VerifyCheckpointStore) -> SavedCheck {
        switch VerifyCheckpoint.resumability(of: store.load(), destination: destination) {
        case .none:
            return .none
        case .restart:
            return .stale
        case let .resume(checkpoint):
            let items = ExportManifest.records(in: destination).keys.filter { !$0.hasPrefix(ExportManifest.iCloudPartialPrefix) }.count
            let percent = items > 0 ? min(100, checkpoint.nextItemIndex * 100 / items) : 0
            return .resumable(percentDone: percent, checkedFiles: checkpoint.checkedFileCount)
        }
    }

    func start(_ check: Check) {
        guard canStart, let destination = model.destination?.url else { return }
        run += 1
        let run = run
        // iCloud backups have no Photos library to compare against.
        let readsLibrary = model.source == .photosLibrary && model.hasPhotosAccess
        let throttle = ProgressThrottle()
        let counter = VerifyByteCount()
        var baseline = 0
        if check == .full, case let .resumable(_, checked) = savedCheck {
            baseline = checked
        }
        let initial = Progress(
            check: check, done: baseline, total: 0, bytesRead: 0, startedAt: Date(), baseline: baseline
        )
        state = .checking(initial)

        if check == .quick {
            task = Task {
                do {
                    let report = try await Self.runQuick(destination: destination)
                    guard run == self.run else { return }
                    state = .quickFinished(Self.quickSummary(of: report, destination: destination))
                } catch is CancellationError {
                    guard run == self.run else { return }
                    state = .ready
                } catch {
                    guard run == self.run else { return }
                    state = .failed("The backup couldn’t be checked. \(error.localizedDescription)")
                }
            }
            return
        }

        let itemIDs: Set<String>?
        let store: VerifyCheckpointStore?
        switch check {
        case .quick:
            itemIDs = nil
            store = nil
        case .full:
            itemIDs = nil
            store = .standard(for: destination)
        case let .items(ids):
            itemIDs = ids
            store = nil
        }

        task = Task {
            do {
                let libraryIDs = readsLibrary
                    ? await Task.detached(priority: .utility) { BackupFiles.allLibraryIDs() }.value
                    : nil
                try Task.checkCancellation()
                let report = try await BackupVerifier.verify(
                    destination: destination,
                    itemIDs: itemIDs,
                    libraryIDs: libraryIDs,
                    checkpoint: store,
                    bytes: counter
                ) { done, total in
                    guard throttle.shouldReport(done: done, total: total) else { return }
                    Task { @MainActor in
                        self.showProgress(done: done, total: total, bytes: counter.value, run: run)
                    }
                }
                guard run == self.run else { return }
                state = .finished(Self.summary(of: report, destination: destination, libraryIDs: libraryIDs))
                refreshSavedCheck()
            } catch is CancellationError {
                guard run == self.run else { return }
                state = .ready
                refreshSavedCheck()
            } catch {
                guard run == self.run else { return }
                state = .failed("The backup couldn’t be checked. \(error.localizedDescription)")
            }
        }
    }

    /// Continues a stopped full check, or starts one when there's nothing to continue.
    func continueFullCheck() {
        start(.full)
    }

    /// Forgets the saved full check, then starts a full check from the first file.
    func startFullCheckOver() {
        guard canStart, let destination = model.destination?.url else { return }
        VerifyCheckpointStore.standard(for: destination).remove()
        savedCheck = .none
        start(.full)
    }

    /// Full check of only the items a quick check flagged.
    func checkProblemsFully() {
        guard case let .quickFinished(quick) = state, !quick.report.problemItemIDs.isEmpty else { return }
        start(.items(quick.report.problemItemIDs))
    }

    /// Stops a check that's in progress. Removing files for a re-export isn't interrupted. A stopped full check keeps
    /// its checkpoint, so `canContinueFullCheck` is true again once it has been saved.
    func cancel() {
        guard isChecking else { return }
        run += 1
        let stopped = task
        task?.cancel()
        task = nil
        state = .ready
        Task { @MainActor in
            await stopped?.value
            self.refreshSavedCheck()
        }
    }

    private func showProgress(done: Int, total: Int, bytes: Int64, run: Int) {
        guard run == self.run, case let .checking(shown) = state, done >= shown.done else { return }
        var next = shown
        next.done = done
        next.total = total
        next.bytesRead = bytes
        state = .checking(next)
    }

    /// Runs the quick check off the main actor. Cancelling the caller stops the listing between folders.
    private static func runQuick(destination: URL) async throws -> QuickVerifyReport {
        let work = Task.detached(priority: .utility) {
            try QuickVerifier.check(destination: destination)
        }
        return try await withTaskCancellationHandler {
            try await work.value
        } onCancel: {
            work.cancel()
        }
    }

    private static func quickSummary(of report: QuickVerifyReport, destination: URL) -> QuickSummary {
        let affected = Array(Set(report.missingFiles + report.emptyFiles + report.changedFiles)).sorted()
        return QuickSummary(
            destination: destination,
            report: report,
            affectedFiles: Array(affected.prefix(affectedFileLimit)),
            affectedFileCount: affected.count
        )
    }

    private static func summary(of report: VerificationReport, destination: URL, libraryIDs: Set<String>?) -> Summary {
        let problemIDs = report.damagedItemIDs.union(report.unverifiableItemIDs)
        // Without the library we can't tell which items can be exported again, so none are offered.
        let reexportIDs = libraryIDs.map { problemIDs.intersection($0) } ?? []
        let affected = (report.missingFiles + report.damagedFiles).sorted()
        return Summary(
            destination: destination,
            checkedFileCount: report.checkedFileCount,
            verifiedCount: report.verifiedItemIDs.count,
            damagedCount: report.damagedItemIDs.count,
            unverifiableCount: report.unverifiableItemIDs.count,
            notBackedUpCount: libraryIDs == nil ? nil : report.notBackedUpCount,
            affectedFiles: Array(affected.prefix(affectedFileLimit)),
            affectedFileCount: affected.count,
            reexportIDs: reexportIDs,
            notInLibraryCount: libraryIDs == nil ? 0 : problemIDs.count - reexportIDs.count,
            resumedFromCheckpoint: report.resumedFromCheckpoint,
            restartReason: report.checkpointRestartReason
        )
    }

    // MARK: - Re-export

    var canReexport: Bool {
        guard case let .finished(summary) = state else { return false }
        return !summary.reexportIDs.isEmpty && !model.isExporting && !model.isEngineRunning
            && model.destination?.url == summary.destination && model.destinationIssue == nil
    }

    /// Deletes the remaining files of the damaged and unverifiable items, forgets them, and starts an export.
    /// Call only after the user confirmed.
    func reexport() {
        guard canReexport, case let .finished(summary) = state else { return }
        let destination = summary.destination
        let requestedIDs = summary.reexportIDs
        state = .reexporting

        task = Task {
            let removal = await Task.detached(priority: .userInitiated) {
                // Only items that are still in the library right now; anything else keeps its files.
                let ids = BackupFiles.existingLibraryIDs(requestedIDs)
                return BackupFiles.removeRecordedFiles(for: ids, in: destination)
            }.value

            // Back on the main actor, no export can start until this finishes.
            guard !model.isExporting, !model.isEngineRunning, model.destination?.url == destination else {
                state = .reexported(
                    message: "An export started, so nothing was changed. Verify again when it finishes.",
                    isProblem: true
                )
                return
            }
            do {
                try ExportManifest.forget(removal.clearedIDs, in: destination)
            } catch {
                state = .reexported(
                    message: "The damaged files were removed, but Uncloud couldn’t update its records. \(error.localizedDescription)",
                    isProblem: true
                )
                return
            }
            model.refreshProgress()

            var message: String
            if removal.clearedIDs.isEmpty {
                message = "Nothing needed exporting again."
            } else if model.canStart {
                model.startOrResume()
                message = "Exporting \(countText(removal.clearedIDs.count, "photo")) again."
            } else {
                message = "\(countText(removal.clearedIDs.count, "photo")) \(removal.clearedIDs.count == 1 ? "is" : "are") ready to export again. Click Export in Backup."
            }
            let skipped = requestedIDs.count - removal.clearedIDs.count
            if skipped > 0 {
                message += " \(countText(skipped, "photo")) couldn’t be prepared and were left as they are."
            }
            state = .reexported(message: message, isProblem: skipped > 0 || removal.clearedIDs.isEmpty)
        }
    }
}

/// The time left in a check, from the rate measured in this run.
enum VerifyEstimate {
    /// Files and seconds needed before a rate is trusted, so the first second doesn't flash a wild estimate.
    static let minimumFiles = 20
    static let minimumSeconds: TimeInterval = 3

    /// Seconds left at the rate of files checked in this run, or nil until there's enough to measure.
    static func secondsRemaining(done: Int, baseline: Int, total: Int, elapsed: TimeInterval) -> TimeInterval? {
        let checkedHere = done - baseline
        guard total > done, checkedHere >= minimumFiles, elapsed >= minimumSeconds else { return nil }
        let rate = Double(checkedHere) / elapsed
        return Double(total - done) / rate
    }

    /// "Less than a minute left", "About 13 min left", "About 2 hr 5 min left".
    static func timeLeftText(seconds: TimeInterval) -> String {
        if seconds < 60 { return "Less than a minute left" }
        let minutes = Int((seconds / 60).rounded())
        if minutes < 60 { return "About \(minutes) min left" }
        let hours = minutes / 60
        let rest = minutes % 60
        return rest == 0 ? "About \(hours) hr left" : "About \(hours) hr \(rest) min left"
    }
}
