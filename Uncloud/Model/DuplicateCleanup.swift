import Foundation
import os

/// Finds items saved more than once in the destination, and moves the extra copies to the Trash when the user confirms.
@MainActor
@Observable
final class DuplicateCleanup {
    enum State {
        case ready
        case scanning(done: Int, total: Int)
        case noneFound(notChecked: Int)
        case found
        case removing(done: Int, total: Int)
        case finished(RemovalSummary)
        case failed(String)
    }

    struct RemovalSummary {
        let result: DuplicateFinder.RemovalResult
    }

    /// Counts only, never file names: the diagnostic log is shared when people report problems.
    static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Uncloud", category: "duplicates")

    private(set) var state = State.ready
    /// The groups of the last scan, largest first. The user can change each group's keeper and include or exclude it.
    private(set) var groups: [DuplicateFinder.Group] = []
    private(set) var notCheckedCount = 0
    /// The destination the groups were found in, so a changed destination never removes anything.
    private(set) var scannedDestination: URL?
    @ObservationIgnored private var excludedGroupIDs: Set<String> = []
    /// How files are moved to the Trash. Tests replace it, so they never touch the real Trash.
    @ObservationIgnored var trasher: @Sendable (URL) throws -> Void = DuplicateFinder.moveToTrash
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var run = 0
    private let model: ExportModel

    init(model: ExportModel) {
        self.model = model
    }

    var isBusy: Bool {
        switch state {
        case .scanning, .removing: true
        default: false
        }
    }

    var canStart: Bool {
        !isBusy && !model.isExporting && !model.isEngineRunning && model.destination != nil && model.destinationIssue == nil
    }

    /// Clears an earlier result so the sheet opens at the start.
    func reset() {
        guard !isBusy else { return }
        state = .ready
        groups = []
        notCheckedCount = 0
        scannedDestination = nil
        excludedGroupIDs = []
    }

    /// The groups the user kept in the removal.
    var includedGroups: [DuplicateFinder.Group] {
        groups.filter { !excludedGroupIDs.contains($0.id) }
    }

    var duplicateCount: Int {
        includedGroups.reduce(0) { $0 + $1.duplicates.count }
    }

    var duplicateBytes: Int64 {
        includedGroups.reduce(0) { $0 + $1.duplicateBytes }
    }

    func isIncluded(_ group: DuplicateFinder.Group) -> Bool {
        !excludedGroupIDs.contains(group.id)
    }

    func setIncluded(_ included: Bool, for group: DuplicateFinder.Group) {
        if included {
            excludedGroupIDs.remove(group.id)
        } else {
            excludedGroupIDs.insert(group.id)
        }
    }

    /// Makes `copyID` the copy to keep in its group, so the others become duplicates.
    func setKeeper(_ copyID: String, in group: DuplicateFinder.Group) {
        guard case .found = state, let index = groups.firstIndex(where: { $0.id == group.id }),
              groups[index].copies.contains(where: { $0.id == copyID }) else { return }
        groups[index].keeperID = copyID
    }

    /// Whether the scan's files are still the destination shown, and nothing else is running.
    var canRemove: Bool {
        guard case .found = state, duplicateCount > 0, !model.isExporting, !model.isEngineRunning,
              model.destinationIssue == nil, let destination = model.destination?.url else { return false }
        return destination == scannedDestination
    }

    // MARK: - Scanning

    func start() {
        guard canStart, let destination = model.destination?.url else { return }
        run += 1
        let run = run
        let throttle = ProgressThrottle()
        state = .scanning(done: 0, total: 0)

        task = Task {
            do {
                let result = try await Task.detached(priority: .utility) {
                    try Self.scan(destination: destination) { done, total in
                        guard throttle.shouldReport(done: done, total: total) else { return }
                        Task { @MainActor in
                            self.showProgress(done: done, total: total, run: run)
                        }
                    }
                }.value
                guard run == self.run else { return }
                groups = result.groups
                notCheckedCount = result.notCheckedCount
                excludedGroupIDs = []
                scannedDestination = destination
                state = result.groups.isEmpty ? .noneFound(notChecked: result.notCheckedCount) : .found
                Self.logger.info("Duplicate scan: \(result.groups.count, privacy: .public) groups, \(self.duplicateCount, privacy: .public) extra copies, \(result.notCheckedCount, privacy: .public) not checked.")
            } catch is CancellationError {
                guard run == self.run else { return }
                state = .ready
            } catch {
                guard run == self.run else { return }
                state = .failed("The backup couldn’t be searched. \(error.localizedDescription)")
            }
        }
    }

    /// Stops a scan that's in progress. Removing files isn't interrupted.
    func cancel() {
        guard case .scanning = state else { return }
        run += 1
        task?.cancel()
        task = nil
        state = .ready
    }

    private func showProgress(done: Int, total: Int, run: Int) {
        guard run == self.run, case let .scanning(shown, _) = state, done >= shown else { return }
        state = .scanning(done: done, total: total)
    }

    /// Reads the manifest, sizes every recorded file, and groups the duplicates. Reads no file contents.
    private nonisolated static func scan(
        destination: URL,
        progress: @Sendable (Int, Int) -> Void
    ) throws -> DuplicateFinder.Result {
        let records = ExportManifest.records(in: destination)
        let checksums = ExportManifest.checksums(in: destination)
        let order = ExportManifest.firstRecordPositions(in: destination)

        let paths = Array(Set(records.values.joined())).sorted()
        var sizes: [String: Int64] = [:]
        for (index, path) in paths.enumerated() {
            try Task.checkCancellation()
            if let url = BackupFiles.containedURL(for: path, in: destination),
               let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                sizes[path] = Int64(size)
            }
            progress(index + 1, paths.count)
        }
        return DuplicateFinder.findGroups(records: records, checksums: checksums, sizes: sizes, exportOrder: order)
    }

    // MARK: - Removing

    /// Moves the extra copies of the included groups to the Trash and re-points their records at the keepers.
    /// Call only after the user confirmed.
    func removeCopies() {
        guard canRemove, let destination = scannedDestination else { return }
        let included = includedGroups
        let total = duplicateCount
        let trash = trasher
        state = .removing(done: 0, total: total)

        task = Task {
            let result = await Task.detached(priority: .userInitiated) {
                DuplicateFinder.remove(groups: included, in: destination, trasher: trash) { done, count in
                    Task { @MainActor in
                        self.showRemovalProgress(done: done, total: count)
                    }
                }
            }.value

            Self.logger.info("Duplicate removal: \(result.removedCopies, privacy: .public) copies moved to the Trash, \(result.skippedCopies, privacy: .public) skipped, \(result.failedCopies, privacy: .public) failed.")
            finish(with: result)
        }
    }

    private func showRemovalProgress(done: Int, total: Int) {
        guard case let .removing(shown, _) = state, done >= shown else { return }
        state = .removing(done: done, total: total)
    }

    private func finish(with result: DuplicateFinder.RemovalResult) {
        // The groups described copies that are gone now, so they're dropped with the result.
        groups = []
        excludedGroupIDs = []
        scannedDestination = nil
        state = .finished(RemovalSummary(result: result))
        model.refreshProgress()
    }
}
