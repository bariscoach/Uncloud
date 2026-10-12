import Foundation
import Photos

/// Finds library items that are verified in the backup and, only when the user confirms, removes them from the library.
@MainActor
@Observable
final class LibraryCleanup {
    enum AgeLimit: Int, CaseIterable, Identifiable, Sendable {
        case oneYear = 1
        case twoYears = 2
        case fiveYears = 5
        case anyAge = 0

        var id: Self { self }

        var title: String {
            switch self {
            case .oneYear: "1 year"
            case .twoYears: "2 years"
            case .fiveYears: "5 years"
            case .anyAge: "Any age"
            }
        }
    }

    struct Filters: Sendable {
        /// Items must be created before this date. Nil means any age.
        let cutoff: Date?
        let keepFavorites: Bool
        let keepHidden: Bool

        /// Whether the item passes the age, favorite and hidden options.
        func allows(_ asset: PHAsset) -> Bool {
            if let cutoff {
                guard let created = asset.creationDate, created < cutoff else { return false }
            }
            return !(keepFavorites && asset.isFavorite) && !(keepHidden && asset.isHidden)
        }
    }

    struct Skipped: Sendable {
        var notVerified = 0
        var edited = 0
        var favorites = 0
        var hidden = 0
    }

    struct Plan: Sendable {
        let destination: URL
        let filters: Filters
        /// The recorded paths and file details of each eligible item, as they were when it was verified.
        let eligible: [String: (paths: [String], details: BackupFiles.FileDetails)]
        let byteCount: Int64
        let skipped: Skipped
    }

    enum State {
        case ready
        case finding
        case checking(done: Int, total: Int)
        case found(Plan)
        case removing
        case finished(message: String, removedAny: Bool)
        case failed(String)
    }

    var ageLimit = AgeLimit.oneYear { didSet { discardPlan() } }
    var keepFavorites = true { didSet { discardPlan() } }
    var keepHidden = true { didSet { discardPlan() } }

    private(set) var state = State.ready
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var run = 0
    private let model: ExportModel

    init(model: ExportModel) {
        self.model = model
    }

    var isBusy: Bool {
        switch state {
        case .finding, .checking, .removing: true
        default: false
        }
    }

    /// The conditions for finding or removing anything: the Photos library source with access, a usable destination,
    /// and no export running.
    var isAllowed: Bool {
        model.source == .photosLibrary && model.hasPhotosAccess && !model.isExporting && model.destination != nil && model.destinationIssue == nil
    }

    func reset() {
        guard !isBusy else { return }
        state = .ready
    }

    private func discardPlan() {
        switch state {
        case .found, .finished, .failed: state = .ready
        default: break
        }
    }

    // MARK: - Finding items

    func findItems() {
        guard isAllowed, !isBusy, let destination = model.destination?.url else { return }
        run += 1
        let run = run
        let filters = currentFilters()
        let throttle = ProgressThrottle()
        state = .finding

        task = Task {
            do {
                let gathered = try await Task.detached(priority: .utility) {
                    try Self.gatherCandidates(destination: destination, filters: filters)
                }.value
                guard run == self.run else { return }
                var skipped = gathered.skipped

                var verifiedIDs = Set<String>()
                if !gathered.candidates.isEmpty {
                    state = .checking(done: 0, total: 0)
                    let report = try await BackupVerifier.verify(
                        destination: destination,
                        itemIDs: Set(gathered.candidates.keys)
                    ) { done, total in
                        guard throttle.shouldReport(done: done, total: total) else { return }
                        Task { @MainActor in
                            self.showProgress(done: done, total: total, run: run)
                        }
                    }
                    verifiedIDs = report.verifiedItemIDs
                }
                guard run == self.run else { return }

                skipped.notVerified += gathered.candidates.count - verifiedIDs.count
                let eligible = gathered.candidates.filter { verifiedIDs.contains($0.key) }
                state = .found(Plan(
                    destination: destination,
                    filters: filters,
                    eligible: eligible,
                    byteCount: eligible.values.reduce(0) { $0 + $1.details.byteCount },
                    skipped: skipped
                ))
            } catch is CancellationError {
                guard run == self.run else { return }
                state = .ready
            } catch {
                guard run == self.run else { return }
                state = .failed("Items couldn’t be checked. \(error.localizedDescription)")
            }
        }
    }

    /// Stops finding items. Removal can't be cancelled here; macOS asks for confirmation instead.
    func cancel() {
        switch state {
        case .finding, .checking:
            run += 1
            task?.cancel()
            task = nil
            state = .ready
        default:
            break
        }
    }

    private func currentFilters() -> Filters {
        let cutoff = ageLimit == .anyAge
            ? nil
            : Calendar.current.date(byAdding: .year, value: -ageLimit.rawValue, to: .now)
        return Filters(cutoff: cutoff, keepFavorites: keepFavorites, keepHidden: keepHidden)
    }

    private func showProgress(done: Int, total: Int, run: Int) {
        guard run == self.run, case let .checking(shown, _) = state, done >= shown else { return }
        state = .checking(done: done, total: total)
    }

    /// Library items in the backup that match the options and weren't edited after they were exported.
    private nonisolated static func gatherCandidates(
        destination: URL,
        filters: Filters
    ) throws -> (candidates: [String: (paths: [String], details: BackupFiles.FileDetails)], skipped: Skipped) {
        let records = ExportManifest.records(in: destination)
        var candidates: [String: (paths: [String], details: BackupFiles.FileDetails)] = [:]
        var skipped = Skipped()
        var wasCancelled = false

        PhotoLibrary.allAssets().enumerateObjects { asset, _, stop in
            if Task.isCancelled {
                wasCancelled = true
                stop.pointee = true
                return
            }
            guard let paths = records[asset.localIdentifier] else { return }
            if let cutoff = filters.cutoff {
                guard let created = asset.creationDate, created < cutoff else { return }
            }
            if filters.keepFavorites, asset.isFavorite {
                skipped.favorites += 1
                return
            }
            if filters.keepHidden, asset.isHidden {
                skipped.hidden += 1
                return
            }
            let details = BackupFiles.details(of: paths, in: destination)
            guard details.allPresent, let newest = details.newestModification else {
                skipped.notVerified += 1
                return
            }
            // Edited after the backup: the backup doesn't have the edit.
            if let modified = asset.modificationDate, modified > newest {
                skipped.edited += 1
                return
            }
            candidates[asset.localIdentifier] = (paths, details)
        }
        if wasCancelled {
            throw CancellationError()
        }
        return (candidates, skipped)
    }

    // MARK: - Removing items

    var canRemove: Bool {
        guard case let .found(plan) = state else { return false }
        return !plan.eligible.isEmpty && isAllowed && model.destination?.url == plan.destination
    }

    /// Removes the eligible items from the photo library. Call only after the user confirmed;
    /// macOS then asks once more. Eligibility is checked again just before deleting.
    func removeItems() {
        guard canRemove, case let .found(plan) = state else { return }
        state = .removing

        task = Task {
            let stillEligible = await Task.detached(priority: .userInitiated) {
                Self.stillEligibleIDs(in: plan)
            }.value

            // Back on the main actor: the conditions must still hold right before deleting.
            guard isAllowed, model.destination?.url == plan.destination else {
                finish(message: "Nothing was removed, because an export started or the backup folder changed.", removedAny: false)
                return
            }
            guard !stillEligible.isEmpty else {
                finish(message: "Nothing was removed. The items changed since they were checked. Choose Find Items again.", removedAny: false)
                return
            }

            var failure: Error?
            do {
                try await PHPhotoLibrary.shared().performChanges {
                    let assets = PHAsset.fetchAssets(withLocalIdentifiers: stillEligible, options: BackupFiles.libraryFetchOptions())
                    PHAssetChangeRequest.deleteAssets(assets)
                }
            } catch {
                failure = error
            }

            let remaining = await Task.detached(priority: .userInitiated) {
                BackupFiles.existingLibraryIDs(stillEligible).count
            }.value
            let removed = stillEligible.count - remaining
            let changed = plan.eligible.count - stillEligible.count

            var message: String
            if removed > 0 {
                message = "Removed \(countText(removed, "item")) from your photo library. They’re in Recently Deleted in Photos for 30 days."
                if remaining > 0 {
                    message += " \(countText(remaining, "item")) couldn’t be removed."
                }
            } else if let failure, Self.isUserCancellation(failure) {
                message = "Nothing was removed."
            } else if let failure {
                message = "Nothing was removed. \(failure.localizedDescription)"
            } else {
                message = "Nothing was removed."
            }
            if changed > 0 {
                message += " \(countText(changed, "item")) changed since they were checked, so they were kept."
            }
            finish(message: message, removedAny: removed > 0)
        }
    }

    private func finish(message: String, removedAny: Bool) {
        state = .finished(message: message, removedAny: removedAny)
        model.refreshProgress()
    }

    /// Re-fetches the planned items and keeps only those that still match the options,
    /// weren't edited, and whose backup files are unchanged since they were verified.
    private nonisolated static func stillEligibleIDs(in plan: Plan) -> [String] {
        let records = ExportManifest.records(in: plan.destination)
        var ids: [String] = []
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: Array(plan.eligible.keys), options: BackupFiles.libraryFetchOptions())
        assets.enumerateObjects { asset, _, _ in
            let id = asset.localIdentifier
            guard let planned = plan.eligible[id],
                  records[id] == planned.paths,
                  plan.filters.allows(asset) else { return }
            let details = BackupFiles.details(of: planned.paths, in: plan.destination)
            guard details.allPresent, details == planned.details, let newest = details.newestModification else { return }
            if let modified = asset.modificationDate, modified > newest { return }
            ids.append(id)
        }
        return ids
    }

    private nonisolated static func isUserCancellation(_ error: Error) -> Bool {
        let error = error as NSError
        return (error.domain == PHPhotosErrorDomain && error.code == PHPhotosError.userCancelled.rawValue)
            || (error.domain == NSCocoaErrorDomain && error.code == NSUserCancelledError)
    }
}
