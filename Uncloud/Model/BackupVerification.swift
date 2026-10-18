import Foundation

/// Checks the backup against its recorded checksums and, when asked, re-exports items with problems.
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
    }

    enum State {
        case ready
        case checking(done: Int, total: Int)
        case finished(Summary)
        case failed(String)
        case reexporting
        case reexported(message: String, isProblem: Bool)
    }

    static let affectedFileLimit = 20

    private(set) var state = State.ready
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var run = 0
    private let model: ExportModel

    init(model: ExportModel) {
        self.model = model
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

    /// Clears an earlier result so the sheet opens at the start.
    func reset() {
        guard !isBusy else { return }
        state = .ready
    }

    func start() {
        guard canStart, let destination = model.destination?.url else { return }
        run += 1
        let run = run
        // iCloud backups have no Photos library to compare against.
        let readsLibrary = model.source == .photosLibrary && model.hasPhotosAccess
        let throttle = ProgressThrottle()
        state = .checking(done: 0, total: 0)

        task = Task {
            do {
                let libraryIDs = readsLibrary
                    ? await Task.detached(priority: .utility) { BackupFiles.allLibraryIDs() }.value
                    : nil
                try Task.checkCancellation()
                let report = try await BackupVerifier.verify(
                    destination: destination,
                    itemIDs: nil,
                    libraryIDs: libraryIDs
                ) { done, total in
                    guard throttle.shouldReport(done: done, total: total) else { return }
                    Task { @MainActor in
                        self.showProgress(done: done, total: total, run: run)
                    }
                }
                guard run == self.run else { return }
                state = .finished(Self.summary(of: report, destination: destination, libraryIDs: libraryIDs))
            } catch is CancellationError {
                guard run == self.run else { return }
                state = .ready
            } catch {
                guard run == self.run else { return }
                state = .failed("The backup couldn’t be checked. \(error.localizedDescription)")
            }
        }
    }

    /// Stops a check that's in progress. Removing files for a re-export isn't interrupted.
    func cancel() {
        guard case .checking = state else { return }
        run += 1
        task?.cancel()
        task = nil
        state = .ready
    }

    private func showProgress(done: Int, total: Int, run: Int) {
        guard run == self.run, case let .checking(shown, _) = state, done >= shown else { return }
        state = .checking(done: done, total: total)
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
            notInLibraryCount: libraryIDs == nil ? 0 : problemIDs.count - reexportIDs.count
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
