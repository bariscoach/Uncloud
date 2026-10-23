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

    /// The extra copies in one folder, for the folder's row and its include toggle.
    struct ExtraFolder: Identifiable, Equatable {
        let folder: String
        let copies: [DuplicateFinder.ExtraCopy]

        var id: String { folder }
        var fileCount: Int { copies.reduce(0) { $0 + $1.mediaPaths.count } }
        var byteCount: Int64 { copies.reduce(0) { $0 + $1.byteCount } }
    }

    /// Counts only, never file names: the diagnostic log is shared when people report problems.
    static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Uncloud", category: "duplicates")

    private(set) var state = State.ready
    /// The groups of the last scan, largest first. The user can change each group's keeper and include or exclude it.
    private(set) var groups: [DuplicateFinder.Group] = []
    /// Extra copies of items in the layout's folders, from the last scan.
    private(set) var extraCopies: [DuplicateFinder.ExtraCopy] = []
    /// iCloud items that share a file, from the last scan. They're deleted in Delete from iCloud, never here.
    private(set) var sharedItemGroups: [DuplicateFinder.SharedItemGroup] = []
    private(set) var notCheckedCount = 0
    /// The destination the groups were found in, so a changed destination never removes anything.
    private(set) var scannedDestination: URL?
    /// The last scan or removal that reached a terminal state. `reset()` keeps it, so the Tools pane can show it (this session only).
    private(set) var lastResult: ToolResult?
    @ObservationIgnored private var excludedGroupIDs: Set<String> = []
    @ObservationIgnored private var excludedExtraFolders: Set<String> = []
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
        clearResults()
    }

    private func clearResults() {
        groups = []
        extraCopies = []
        sharedItemGroups = []
        notCheckedCount = 0
        scannedDestination = nil
        excludedGroupIDs = []
        excludedExtraFolders = []
    }

    /// The groups the user kept in the removal.
    var includedGroups: [DuplicateFinder.Group] {
        groups.filter { !excludedGroupIDs.contains($0.id) }
    }

    /// The extra copies in the folders the user kept in the removal.
    var includedExtraCopies: [DuplicateFinder.ExtraCopy] {
        extraCopies.filter { !excludedExtraFolders.contains($0.folder) }
    }

    /// The extra copies by folder, largest folder first.
    var extraFolders: [ExtraFolder] {
        Dictionary(grouping: extraCopies, by: \.folder)
            .map { ExtraFolder(folder: $0.key, copies: $0.value.sorted { $0.recordID < $1.recordID }) }
            .sorted { a, b in a.byteCount != b.byteCount ? a.byteCount > b.byteCount : a.folder < b.folder }
    }

    /// Copies to move to the Trash: the same-folder duplicates and the extra copies the user kept.
    var duplicateCount: Int {
        includedGroups.reduce(0) { $0 + $1.duplicates.count } + includedExtraCopies.count
    }

    var duplicateBytes: Int64 {
        includedGroups.reduce(0) { $0 + $1.duplicateBytes } + includedExtraCopies.reduce(0) { $0 + $1.byteCount }
    }

    /// The copies in the folder are removed with the rest. Off keeps the folder's files.
    func isIncluded(_ folder: ExtraFolder) -> Bool {
        !excludedExtraFolders.contains(folder.folder)
    }

    func setIncluded(_ included: Bool, for folder: ExtraFolder) {
        if included {
            excludedExtraFolders.remove(folder.folder)
        } else {
            excludedExtraFolders.insert(folder.folder)
        }
    }

    /// Items that share a file, for Delete from iCloud: the extra items of every group.
    var sharedExtraItemCount: Int {
        sharedItemGroups.reduce(0) { $0 + $1.extraIDs.count }
    }

    /// Opens Delete from iCloud with the extra items of the shared groups selected. Nothing is deleted there until the
    /// user confirms. False when the library isn't open or nothing is selected.
    @discardableResult
    func reviewSharedItemsInCleanup() -> Bool {
        guard let cleanup = model.iCloudCleanup, model.source == .iCloud, !cleanup.isRunning else { return false }
        let ids = Set(sharedItemGroups.flatMap(\.extraIDs).map { String($0.dropFirst(ExportManifest.iCloudIDPrefix.count)) })
        guard !ids.isEmpty else { return false }
        cleanup.setMode(.library)
        cleanup.selection = .only(ids)
        model.pane = .cleanup
        return true
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
                extraCopies = result.extraCopies
                sharedItemGroups = result.sharedItemGroups
                notCheckedCount = result.notCheckedCount
                excludedGroupIDs = []
                excludedExtraFolders = []
                scannedDestination = destination
                let isEmpty = result.groups.isEmpty && result.extraCopies.isEmpty && result.sharedItemGroups.isEmpty
                state = isEmpty ? .noneFound(notChecked: result.notCheckedCount) : .found
                if isEmpty {
                    lastResult = ToolResult(date: .now, text: "No duplicates", isProblem: false)
                }
                Self.logger.info("Duplicate scan: \(result.groups.count, privacy: .public) groups, \(result.extraCopies.count, privacy: .public) extra copies, \(result.sharedItemGroups.count, privacy: .public) shared iCloud items, \(result.notCheckedCount, privacy: .public) not checked.")
            } catch is CancellationError {
                guard run == self.run else { return }
                state = .ready
            } catch {
                guard run == self.run else { return }
                state = .failed("The backup couldn’t be searched. \(error.localizedDescription)")
                lastResult = ToolResult(date: .now, text: "Couldn’t be searched", isProblem: true)
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
        let sizes = try recordedSizes(for: paths, in: destination, progress: progress)
        return DuplicateFinder.findGroups(
            records: records, checksums: checksums, sizes: sizes, exportOrder: order,
            layout: ExportManifest.layout(in: destination)
        )
    }

    /// The size of each recorded regular file, from one bulk listing per folder rather than one lookup per file. A path
    /// that isn't a regular file in the listing has no size, as a missing file never had one.
    nonisolated static func recordedSizes(
        for paths: [String],
        in destination: URL,
        progress: (Int, Int) -> Void
    ) throws -> [String: Int64] {
        var sizes: [String: Int64] = [:]
        let folders = Dictionary(grouping: paths) { ($0 as NSString).deletingLastPathComponent }
        var done = 0
        for folder in folders.keys.sorted() {
            try Task.checkCancellation()
            let group = folders[folder] ?? []
            // Every path in a group shares its folder, so the first path's folder is the one to list.
            if let sample = BackupFiles.containedURL(for: group[0], in: destination),
               let entries = try? BulkDirectoryLister.list(sample.deletingLastPathComponent()) {
                var sizeByName: [String: Int64] = [:]
                for entry in entries where entry.kind == .file {
                    sizeByName[entry.name] = entry.size
                }
                for path in group {
                    if let size = sizeByName[(path as NSString).lastPathComponent] {
                        sizes[path] = size
                    }
                    done += 1
                    if done % 1_000 == 0 {
                        try Task.checkCancellation()
                        progress(done, paths.count)
                    }
                }
            } else {
                done += group.count
            }
            progress(done, paths.count)
        }
        return sizes
    }

    // MARK: - Removing

    /// Moves the extra copies of the included groups to the Trash and re-points their records at the keepers.
    /// Call only after the user confirmed.
    func removeCopies() {
        guard canRemove, let destination = scannedDestination else { return }
        let included = includedGroups
        let extras = includedExtraCopies
        let total = duplicateCount
        let groupTotal = included.reduce(0) { $0 + $1.duplicates.count }
        let trash = trasher
        state = .removing(done: 0, total: total)

        task = Task {
            let result = await Task.detached(priority: .userInitiated) {
                var combined = DuplicateFinder.remove(groups: included, in: destination, trasher: trash) { done, count in
                    Task { @MainActor in
                        self.showRemovalProgress(done: done, total: count)
                    }
                }
                combined.add(DuplicateFinder.removeExtraCopies(extras, in: destination, trasher: trash) { done, _ in
                    Task { @MainActor in
                        self.showRemovalProgress(done: groupTotal + done, total: total)
                    }
                })
                return combined
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
        clearResults()
        state = .finished(RemovalSummary(result: result))
        lastResult = ToolResult(
            date: .now,
            text: countText(result.removedCopies, "duplicate") + " removed",
            isProblem: result.failedCopies > 0
        )
        model.refreshProgress()
    }
}
