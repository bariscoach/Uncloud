import Foundation
import Observation
import os

/// Deletes the chosen items from iCloud Photos in batches, through the account's bridge, or recovers the chosen items
/// from Recently Deleted. Deleted items move to Recently Deleted on every device, where they stay for 30 days. The
/// backup on the destination drive and its manifest are never touched.
///
/// A deletion starts only from `start(typed:)`, after the user has typed the number of items in the confirmation. A
/// recovery starts from `recover()`, with no number to type, since recovering isn't destructive. Both end when they
/// finish, when the user cancels them, or when the retries after Apple's throttle run out. Only one runs at a time.
@MainActor
@Observable
final class ICloudCleanup {
    /// Which items a run works on: the library (delete them) or Recently Deleted (recover them).
    enum Mode: String, CaseIterable, Identifiable, Sendable {
        case library
        case recentlyDeleted

        var id: Self { self }

        var title: String {
            switch self {
            case .library: "Library"
            case .recentlyDeleted: "Recently Deleted"
            }
        }

        var action: ICloudBridgeDeleteOptions.Action {
            switch self {
            case .library: .delete
            case .recentlyDeleted: .restore
            }
        }
    }

    enum State: Equatable {
        case idle
        case confirming
        case finding(done: Int, total: Int)
        case deleting(done: Int, total: Int, paused: Bool)
        /// Apple limited deletions. The items not yet reached are tried again at `until`, as retry `attempt`.
        case waitingAfterThrottle(until: Date, attempt: Int)
        case finished(Summary)
        case failed(String)
    }

    struct Summary: Equatable {
        /// Items deleted, or recovered when `action` is `.restore`.
        let deleted: Int
        let failures: [ICloudBridgeDeleteFailure]
        let missing: Int
        let cancelled: Bool
        /// Why the run stopped short, when it wasn't cancelled by the user. Nil otherwise.
        let stoppedMessage: String?
        /// What the run did, so the summary says "Deleted" or "Recovered" whatever the mode is now.
        var action: ICloudBridgeDeleteOptions.Action = .delete
    }

    /// What the cleanup needs from the rest of the app.
    struct Environment {
        /// True while an export runs or its engine is still stopping: nothing is deleted then.
        var isExportRunning: @MainActor () -> Bool
        /// The library's item count, once known.
        var libraryCount: @MainActor () -> Int?
        /// Where the given IDs were last seen, so a selection of a few items doesn't walk the whole library.
        var rankHints: @MainActor (Set<String>) async -> [String: Int]
        /// Called once a deletion that deleted something has ended. The app reloads what shows the library.
        var libraryDidChange: @MainActor (Set<String>) -> Void
        /// The number of items in Recently Deleted, once known.
        var recentlyDeletedCount: @MainActor () -> Int? = { nil }
        /// Where the given IDs were last seen in Recently Deleted, for `.only` recoveries.
        var recentlyDeletedRankHints: @MainActor (Set<String>) async -> [String: Int] = { _ in [:] }
        /// Called once a recovery that recovered something has ended. The app reloads both albums.
        var recoveryDidChange: @MainActor (Set<String>) -> Void = { _ in }
    }

    /// Waits before each retry after Apple's throttle: 1, 2, 5, 10, then 15 minutes.
    static let defaultRetryDelays: [TimeInterval] = [60, 120, 300, 600, 900]
    static let maxRetries = 8

    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Uncloud", category: "cleanup")

    let appleID: String
    private(set) var state: State = .idle
    /// The list the toolbar shows: the library, or Recently Deleted. Changes only while nothing runs.
    private(set) var mode: Mode = .library
    /// Each mode's own selection, so the items picked in one don't change the other.
    private(set) var selections: [Mode: LibrarySelection] = [.library: .only([]), .recentlyDeleted: .only([])]
    /// The mode the current or last run worked on.
    private(set) var runMode: Mode = .library
    /// The number the user must type to confirm: the items the selection covers when confirmation opened.
    private(set) var pendingCount = 0
    /// True from the user's Stop until the run has ended, after its batch in progress.
    private(set) var isStopping = false

    @ObservationIgnored private let bridge: ICloudBridge
    @ObservationIgnored private let environment: Environment
    @ObservationIgnored private let retryDelays: [TimeInterval]
    @ObservationIgnored private let batchSize: Int
    /// The IDs the run deleted (or recovered).
    @ObservationIgnored private var deleted: Set<String> = []
    @ObservationIgnored private var failures: [String: String] = [:]
    @ObservationIgnored private var missing = 0
    /// The request of the attempt in progress, and the request of the run before any retry.
    @ObservationIgnored private var attempted: ICloudBridgeDeleteOptions?
    /// The IDs the current attempt will try, once its targets are known.
    @ObservationIgnored private var attemptTargets: [String]?
    @ObservationIgnored private var retries = 0
    /// The count the user typed, sent with every request of the run. Never more than that is deleted.
    @ObservationIgnored private var confirmedCount = 0
    @ObservationIgnored private var pendingRetry: ICloudBridgeDeleteOptions?
    @ObservationIgnored private var runTask: Task<Void, Never>?
    @ObservationIgnored private var deletionID: Int?
    @ObservationIgnored private var isPaused = false
    @ObservationIgnored private var activity: NSObjectProtocol?
    @ObservationIgnored private var endWaiters: [CheckedContinuation<Void, Never>] = []

    init(
        appleID: String,
        bridge: ICloudBridge,
        environment: Environment,
        retryDelays: [TimeInterval] = ICloudCleanup.defaultRetryDelays,
        batchSize: Int = 100
    ) {
        self.appleID = appleID
        self.bridge = bridge
        self.environment = environment
        self.retryDelays = retryDelays.isEmpty ? ICloudCleanup.defaultRetryDelays : retryDelays
        self.batchSize = min(max(batchSize, 1), ICloudBridgeDeleteOptions.maxBatchSize)
    }

    /// True while a run is finding, deleting or waiting to retry. Exports wait for it, and it waits for no export.
    var isRunning: Bool {
        switch state {
        case .finding, .deleting, .waitingAfterThrottle: true
        case .idle, .confirming, .finished, .failed: false
        }
    }

    /// The selection of the current mode, which the toolbar and the grid show.
    var selection: LibrarySelection {
        get { selections[mode] ?? .only([]) }
        set { selections[mode] = newValue }
    }

    /// The items the selection covers, as the toolbar counts them. Zero until the count of the mode's list is known.
    var selectedCount: Int {
        selection.selectedCount(total: count(for: mode) ?? 0)
    }

    /// True when Clean Up can ask for confirmation: something is selected, nothing else is running.
    var canRequestConfirmation: Bool {
        !isRunning && !environment.isExportRunning() && count(for: mode) != nil && selectedCount > 0
    }

    /// Shows the library or Recently Deleted. Nothing changes while a run is going.
    func setMode(_ mode: Mode) {
        guard !isRunning, self.mode != mode else { return }
        if state == .confirming {
            cancelConfirmation()
        }
        self.mode = mode
    }

    private func count(for mode: Mode) -> Int? {
        switch mode {
        case .library: environment.libraryCount()
        case .recentlyDeleted: environment.recentlyDeletedCount()
        }
    }

    func requestConfirmation() {
        guard canRequestConfirmation else { return }
        pendingCount = selectedCount
        state = .confirming
    }

    func cancelConfirmation() {
        guard state == .confirming else { return }
        state = .idle
    }

    /// True when `typed` is the confirmed count, written plainly or with the locale's grouping ("1,234").
    static func typedNumberMatches(_ typed: String, count: Int) -> Bool {
        let text = typed.trimmingCharacters(in: .whitespaces)
        return text == String(count) || text == count.formatted()
    }

    /// Starts deleting the library's selection once the confirmation is open and `typed` matches it. False when it
    /// didn't start, including in Recently Deleted, which recovers instead (see `recover()`).
    @discardableResult
    func start(typed: String) -> Bool {
        guard mode == .library, Self.typedNumberMatches(typed, count: pendingCount) else { return false }
        return launch()
    }

    /// Starts recovering the Recently Deleted selection once the confirmation is open. No number is typed: recovering
    /// isn't destructive. False in the library, or when nothing was confirmed.
    @discardableResult
    func recover() -> Bool {
        guard mode == .recentlyDeleted else { return false }
        return launch()
    }

    private func launch() -> Bool {
        guard state == .confirming, !environment.isExportRunning(), count(for: mode) != nil else { return false }
        let selection = selection
        let mode = mode
        deleted = []
        failures = [:]
        missing = 0
        retries = 0
        confirmedCount = pendingCount
        isStopping = false
        runMode = mode
        state = .finding(done: 0, total: pendingCount)
        Self.logger.info("\(mode.action == .delete ? "Clean up" : "Recovery") started for \(self.pendingCount) items")
        runTask = Task { await begin(selection, mode: mode) }
        return true
    }

    /// Returns once the run has ended: finished, failed, or stopped. At once when nothing is running.
    func waitUntilEnded() async {
        guard isRunning else { return }
        await withCheckedContinuation { endWaiters.append($0) }
    }

    /// Stops a run at the next batch, or gives up on a retry that's waiting. A batch already sent is not recalled.
    func cancel() {
        switch state {
        case .confirming:
            cancelConfirmation()
        case .waitingAfterThrottle:
            runTask?.cancel()
            runTask = nil
            finish(cancelled: true, stoppedMessage: nil)
        case .finding, .deleting:
            guard !isStopping else { return }
            isStopping = true
            if let deletionID {
                bridge.cancelRequest(deletionID)
            }
        case .idle, .finished, .failed:
            break
        }
    }

    /// Holds or continues a run between batches. Browsing goes on meanwhile.
    func setPaused(_ paused: Bool) {
        guard case let .deleting(done, total, _) = state, let deletionID, !isStopping else { return }
        isPaused = paused
        if paused {
            bridge.pauseRequest(deletionID)
        } else {
            bridge.resumeRequest(deletionID)
        }
        state = .deleting(done: done, total: total, paused: paused)
    }

    /// Tries the items not yet reached now, instead of waiting for the retry.
    func retryNow() {
        guard case .waitingAfterThrottle = state, let next = pendingRetry else { return }
        runTask?.cancel()
        state = .finding(done: 0, total: pendingCount)
        runTask = Task { await attempt(next) }
    }

    /// Closes the summary or the failure, so the next run starts from a clean slate.
    func dismiss() {
        guard !isRunning else { return }
        state = .idle
        deleted = []
        failures = [:]
        missing = 0
    }

    // MARK: - Running

    private func begin(_ selection: LibrarySelection, mode: Mode) async {
        let options: ICloudBridgeDeleteOptions
        switch selection {
        case .only(let ids):
            // The bridge walks the album for the ones it has no hint for.
            let hints = await rankHints(for: mode, ids)
            options = ICloudBridgeDeleteOptions(
                mode: .only, confirmedCount: confirmedCount, action: mode.action,
                ids: ids.sorted(), rankHints: hints, batchSize: batchSize
            )
        case .allExcept(let excluded):
            options = ICloudBridgeDeleteOptions(
                mode: .allExcept, confirmedCount: confirmedCount, action: mode.action,
                ids: excluded.sorted(), batchSize: batchSize
            )
        }
        await attempt(options)
    }

    private func rankHints(for mode: Mode, _ ids: Set<String>) async -> [String: Int] {
        switch mode {
        case .library: await environment.rankHints(ids)
        case .recentlyDeleted: await environment.recentlyDeletedRankHints(ids)
        }
    }

    private func attempt(_ options: ICloudBridgeDeleteOptions) async {
        attempted = options
        attemptTargets = nil
        beginActivity()
        do {
            let deletion = try await bridge.delete(options)
            deletionID = deletion.id
            if isStopping {
                bridge.cancelRequest(deletion.id)
            }
            if isPaused {
                bridge.pauseRequest(deletion.id)
            }
            for try await event in deletion.events {
                handle(event)
            }
        } catch {
            // Only a throttle that the bridge reports as `throttled` is retried; any other failure ends the run.
            deletionID = nil
            Self.logger.error("Clean up's bridge request failed: \(String(describing: type(of: error)))")
            finish(cancelled: isStopping, stoppedMessage: error.localizedDescription)
        }
    }

    private func handle(_ event: ICloudBridgeDeleteEvent) {
        switch event {
        case let .finding(done, total):
            state = .finding(done: done, total: total)
        case let .targets(ids):
            attemptTargets = ids
        case let .deleted(ids):
            deleted.formUnion(ids)
            for id in ids {
                failures[id] = nil
            }
        case let .failed(items):
            for item in items {
                failures[item.id] = item.reason
            }
        case let .progress(done, total):
            state = .deleting(done: done, total: total, paused: isPaused)
        case let .done(_, _, missingCount, cancelled, stopped, message):
            deletionID = nil
            missing += missingCount
            if stopped == .throttled, !isStopping {
                scheduleRetry(message: message)
            } else {
                finish(cancelled: cancelled || isStopping, stoppedMessage: stopped == nil ? nil : message)
            }
        }
    }

    /// Waits, then tries again with only the items this run hasn't deleted yet. Nothing already deleted is sent again.
    private func scheduleRetry(message: String?) {
        retries += 1
        guard retries <= Self.maxRetries, let current = attempted else {
            finish(cancelled: false, stoppedMessage: message ?? "Apple is limiting deletions. Try Clean Up again later.")
            return
        }
        let next: ICloudBridgeDeleteOptions
        if let targets = attemptTargets {
            let remaining = targets.filter { !deleted.contains($0) }
            guard !remaining.isEmpty else {
                finish(cancelled: false, stoppedMessage: message)
                return
            }
            next = ICloudBridgeDeleteOptions(
                mode: .only, confirmedCount: remaining.count, action: current.action,
                ids: remaining, batchSize: current.batchSize
            )
        } else if current.mode == .only {
            let remaining = current.ids.filter { !deleted.contains($0) }
            guard !remaining.isEmpty else {
                finish(cancelled: false, stoppedMessage: message)
                return
            }
            next = ICloudBridgeDeleteOptions(
                mode: .only, confirmedCount: remaining.count, action: current.action, ids: remaining,
                rankHints: current.rankHints, batchSize: current.batchSize
            )
        } else {
            next = current
        }
        let delay = retryDelays[min(retries - 1, retryDelays.count - 1)]
        pendingRetry = next
        state = .waitingAfterThrottle(until: Date.now.addingTimeInterval(delay), attempt: retries)
        Self.logger.info("Clean up waiting to retry after a throttle, retry \(self.retries)")
        runTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            await self.attempt(next)
        }
    }

    private func finish(cancelled: Bool, stoppedMessage: String?) {
        endActivity()
        isPaused = false
        isStopping = false
        runTask = nil
        deletionID = nil
        pendingRetry = nil
        let action = runMode.action
        let summary = Summary(
            deleted: deleted.count,
            failures: failures.map { ICloudBridgeDeleteFailure(id: $0.key, reason: $0.value) }.sorted { $0.id < $1.id },
            missing: missing,
            cancelled: cancelled,
            stoppedMessage: stoppedMessage,
            action: action
        )
        Self.logger.info("Clean up ended: \(summary.deleted) changed, \(summary.failures.count) failed, \(summary.missing) missing")
        if !deleted.isEmpty {
            // Deleted items leave the library selection; recovered items leave the Recently Deleted one.
            selections[runMode] = (selections[runMode] ?? .only([])).forgetting(deleted)
            switch action {
            case .delete: environment.libraryDidChange(deleted)
            case .restore: environment.recoveryDidChange(deleted)
            }
        }
        if summary.deleted == 0, summary.failures.isEmpty, !cancelled, let stoppedMessage {
            state = .failed(stoppedMessage)
        } else {
            state = .finished(summary)
        }
        let waiters = endWaiters
        endWaiters = []
        waiters.forEach { $0.resume() }
    }

    /// Keeps the Mac awake for the whole run, including the waits between retries.
    private func beginActivity() {
        guard activity == nil else { return }
        activity = ProcessInfo.processInfo.beginActivity(
            options: .idleSystemSleepDisabled,
            reason: "Deleting items from iCloud Photos"
        )
    }

    private func endActivity() {
        if let activity {
            ProcessInfo.processInfo.endActivity(activity)
        }
        activity = nil
    }
}
