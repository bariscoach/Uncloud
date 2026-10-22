import Foundation
import Observation
import Photos

/// Keeps the storage estimate of the current selection up to date, for `ExportModel`.
///
/// iCloud: the account's saved size table loads first, topped up with the sizes of the pages the
/// browser has loaded, so a sampled estimate shows within moments. A background walk of the library
/// (the bridge's `stats`) then fills in every item's size and saves the table, after which the
/// estimate is exact. The walk stops while an export runs and resumes afterwards.
///
/// Photos library: every item's size is estimated once from its metadata (`PhotoSizeHeuristic`).
///
/// Selection changes only re-sum the table, on `AssetSizeIndex`, never on the main actor.
@MainActor
final class StorageEstimator {
    private enum Owner: Equatable {
        case photosLibrary
        case iCloud(String)
    }

    /// Walks an account's library into the index; `ICloudSizeScanner.scan` through the account's bridge.
    typealias Scan = @Sendable (
        _ account: String,
        _ index: AssetSizeIndex,
        _ libraryCount: Int?,
        _ onProgress: @escaping @Sendable () async -> Void
    ) async -> ICloudSizeScanner.Outcome

    /// Reports a new estimate (nil while unknown) and whether work toward one is under way.
    var onChange: ((StorageEstimate?, _ isEstimating: Bool) -> Void)?

    private var owner: Owner?
    private var index: AssetSizeIndex?
    private weak var browser: LibraryBrowser?
    private var selection: LibrarySelection = .everything
    private var isPaused = false
    private var isPreparing = false
    private var isScanning = false
    private var estimate: StorageEstimate?
    private var generation = 0
    private var prepareTask: Task<Void, Never>?
    private var recomputeTask: Task<Void, Never>?
    private var scanTask: Task<Void, Never>?
    /// Identifies the current walk, so a cancelled walk that ends late can't touch a newer one.
    private var scanToken = 0
    private var retryTask: Task<Void, Never>?
    private var scanFailures = 0
    private let store: AssetSizeStore
    /// Off when unit tests host the app: the walk would read the user's real iCloud library.
    private let allowsScanning: Bool
    private let scan: Scan
    /// How long after an export, or a walk the bridge stopped, before the walk starts again.
    private let resumeDelay: Duration

    /// How long selection changes settle before the estimate is summed again.
    private static let recomputeDelay: Duration = .milliseconds(250)
    private static let retryDelay: Duration = .seconds(30)
    private static let maxScanFailures = 3

    init(
        store: AssetSizeStore = AssetSizeStore(),
        allowsScanning: Bool = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil,
        resumeDelay: Duration = .seconds(5),
        scan: @escaping Scan = { account, index, libraryCount, onProgress in
            await ICloudSizeScanner.scan(
                bridge: .shared(appleID: account),
                index: index,
                libraryCount: libraryCount,
                catalog: ICloudCatalogStore.shared(appleID: account),
                onProgress: onProgress
            )
        }
    ) {
        self.store = store
        self.allowsScanning = allowsScanning
        self.resumeDelay = resumeDelay
        self.scan = scan
    }

    /// Starts over for a source and account. `browser` is nil while iCloud is signed out.
    func configure(source: LibrarySource, account: String?, browser: LibraryBrowser?, selection: LibrarySelection) {
        let owner: Owner? = switch source {
        case .photosLibrary: browser == nil ? nil : .photosLibrary
        case .iCloud: account.map(Owner.iCloud)
        }
        self.selection = selection
        guard owner != self.owner || browser !== self.browser else { return }
        generation += 1
        prepareTask?.cancel()
        recomputeTask?.cancel()
        scanTask?.cancel()
        retryTask?.cancel()
        scanTask = nil
        isScanning = false
        scanFailures = 0
        self.owner = owner
        self.browser = browser
        index = nil
        estimate = nil
        guard let owner, browser != nil else {
            isPreparing = false
            report()
            return
        }
        isPreparing = true
        report()
        observeLibraryCount()

        let generation = generation
        switch owner {
        case .photosLibrary:
            let index = AssetSizeIndex(table: AssetSizeTable(kind: .heuristic))
            self.index = index
            prepareTask = Task {
                await rebuildPhotosTable(index)
                guard generation == self.generation else { return }
                isPreparing = false
                recompute(after: .zero)
            }
        case .iCloud(let account):
            let index = AssetSizeIndex(
                table: AssetSizeTable(kind: .measured),
                store: store,
                account: account,
                maySave: { ICloudAccount.appleID == account }
            )
            self.index = index
            prepareTask = Task {
                await index.loadSaved()
                guard generation == self.generation else { return }
                isPreparing = false
                recompute(after: .zero)
                startScanIfNeeded()
            }
        }
    }

    /// Measures the iCloud library again from nothing, after its contents changed (items were deleted from iCloud).
    /// Other sources and accounts are left alone.
    func libraryContentsDidChange() {
        guard case .iCloud(let account)? = owner, let browser else { return }
        self.owner = nil
        self.browser = nil
        configure(source: .iCloud, account: account, browser: browser, selection: selection)
    }

    func selectionDidChange(_ selection: LibrarySelection) {
        guard selection != self.selection else { return }
        self.selection = selection
        recompute(after: Self.recomputeDelay)
    }

    /// Stops the walk, so it doesn't compete with the export for the bridge and the network.
    func exportDidStart() {
        isPaused = true
        retryTask?.cancel()
        scanTask?.cancel()
        scanTask = nil
        isScanning = false
    }

    /// Resumes the walk, and re-estimates a Photos library that the export may have seen change.
    func exportDidFinish() {
        isPaused = false
        scanFailures = 0
        let generation = generation
        retryTask?.cancel()
        retryTask = Task {
            try? await Task.sleep(for: resumeDelay)
            guard !Task.isCancelled, generation == self.generation else { return }
            switch owner {
            case .photosLibrary:
                if let index {
                    await rebuildPhotosTable(index)
                    guard generation == self.generation else { return }
                    recompute(after: .zero)
                }
            case .iCloud:
                startScanIfNeeded()
            case nil:
                break
            }
        }
    }

    // MARK: - Estimating

    private var libraryCount: Int? {
        if let count = browser?.count {
            return count
        }
        if case .iCloud = owner {
            return ICloudLibrary.cachedLibraryCount
        }
        return nil
    }

    /// Re-sums the estimate after `delay`; a newer call replaces a pending one.
    private func recompute(after delay: Duration) {
        guard let index else { return }
        recomputeTask?.cancel()
        let generation = generation
        let selection = selection
        let count = libraryCount
        let browser = browser
        var samplesBrowser = false
        if case .iCloud = owner {
            samplesBrowser = true
        }
        recomputeTask = Task {
            if delay > .zero {
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled else { return }
            }
            if samplesBrowser, let browser, await !index.isComplete {
                await index.addSamples(browser.knownBytes())
            }
            let estimate = await index.estimate(for: selection, libraryCount: count)
            guard !Task.isCancelled, generation == self.generation else { return }
            self.estimate = estimate
            report()
        }
    }

    private func report() {
        onChange?(estimate, isPreparing || (estimate == nil && isScanning))
    }

    private func rebuildPhotosTable(_ index: AssetSizeIndex) async {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .authorized || status == .limited else { return }
        let table = await Task.detached(priority: .utility) { PhotoSizeHeuristic.libraryTable() }.value
        await index.replace(with: table)
    }

    /// Re-estimates when the browser learns or relearns the library's size.
    private func observeLibraryCount() {
        guard let browser else { return }
        let generation = generation
        withObservationTracking {
            _ = browser.count
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, generation == self.generation else { return }
                libraryCountDidChange()
                observeLibraryCount()
            }
        }
    }

    private func libraryCountDidChange() {
        guard !isPreparing, let index else { return }
        switch owner {
        case .photosLibrary:
            // The library changed; estimate it again.
            let generation = generation
            prepareTask = Task {
                if await index.libraryCount != libraryCount {
                    await rebuildPhotosTable(index)
                }
                guard generation == self.generation else { return }
                recompute(after: .zero)
            }
        case .iCloud:
            recompute(after: .zero)
            startScanIfNeeded()
        case nil:
            break
        }
    }

    // MARK: - Scanning iCloud

    private func startScanIfNeeded() {
        guard allowsScanning, case .iCloud(let account) = owner, !isPaused, !isPreparing, scanTask == nil,
              scanFailures < Self.maxScanFailures, let index else { return }
        retryTask?.cancel()
        let generation = generation
        let count = libraryCount
        scanToken += 1
        let token = scanToken
        let scan = scan
        isScanning = true
        report()
        scanTask = Task(priority: .background) { [weak self] in
            let outcome = await scan(account, index, count) { [weak self] in
                await self?.scanDidProgress(generation: generation)
            }
            self?.scanDidEnd(outcome, generation: generation, token: token)
        }
    }

    /// True while a walk of the library runs, for tests.
    var isScanRunning: Bool { scanTask != nil }

    private func scanDidProgress(generation: Int) {
        guard generation == self.generation else { return }
        scanFailures = 0
        recompute(after: .zero)
    }

    private func scanDidEnd(_ outcome: ICloudSizeScanner.Outcome, generation: Int, token: Int) {
        // A walk cancelled by an export that has since finished can end after a newer walk started.
        guard generation == self.generation, token == scanToken else { return }
        let wasCancelled = scanTask == nil
        scanTask = nil
        isScanning = false
        recompute(after: .zero)
        report()
        guard !wasCancelled, !isPaused else { return }
        let delay: Duration
        switch outcome {
        case .complete:
            scanFailures = 0
            return
        case .interrupted:
            // The bridge yielded to a download or restarted; try again shortly. A walk that keeps
            // stopping without progress gives up after a few tries, like a failing one.
            scanFailures += 1
            delay = resumeDelay
        case .failed(let error):
            if let error = error as? ICloudError, error == .signInRequired { return }
            scanFailures += 1
            delay = Self.retryDelay
        }
        retryTask = Task {
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, generation == self.generation else { return }
            startScanIfNeeded()
        }
    }
}
