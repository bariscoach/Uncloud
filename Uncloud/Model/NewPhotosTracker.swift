import AppKit
import Observation
import Photos
import UserNotifications

/// Keeps the new-photos count for the current folder and source, saves the watermark after complete exports,
/// and posts the reminder. Counting walks the library, so every refresh is a cancellable task, and a refresh
/// that arrives while another runs replaces it.
@MainActor
@Observable
final class NewPhotosTracker {
    /// What is new for `statusContext`. Nil when there's no complete export yet.
    private(set) var status: NewPhotosStatus?
    private(set) var statusContext: NewPhotosContext?
    /// The last refresh found the iCloud session needs signing in. Background checks skip then; nothing prompts.
    private(set) var needsSignIn = false

    @ObservationIgnored let store: NewPhotosStore
    @ObservationIgnored var now: @Sendable () -> Date = { Date() }
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var refreshGeneration = 0
    @ObservationIgnored private var lastRefreshAt: Date?
    /// Without `force`, a refresh for the same context waits at least this long after the last one.
    static let minimumRefreshInterval: TimeInterval = 60

    init(store: NewPhotosStore = .standard()) {
        self.store = store
    }

    /// Recounts for `context`. Returns the task, so a caller can wait for the result.
    @discardableResult
    func refresh(_ context: NewPhotosContext, force: Bool) -> Task<Void, Never> {
        let current = now()
        if !force, statusContext == context, let last = lastRefreshAt,
           current.timeIntervalSince(last) < Self.minimumRefreshInterval {
            return refreshTask ?? Task {}
        }
        refreshTask?.cancel()
        refreshGeneration += 1
        let generation = refreshGeneration
        lastRefreshAt = current
        let store = store
        let task = Task { [weak self] in
            let outcome = await Self.count(context, store: store)
            guard let self, !Task.isCancelled, generation == self.refreshGeneration else { return }
            self.apply(outcome, for: context)
        }
        refreshTask = task
        return task
    }

    /// Stops a refresh in progress, such as when an export starts.
    func cancelRefresh() {
        refreshTask?.cancel()
        refreshTask = nil
        refreshGeneration += 1
    }

    /// Sets the figures without counting, for previews and the design snapshots.
    func setStatusForPreview(_ status: NewPhotosStatus?, context: NewPhotosContext) {
        self.status = status
        statusContext = context
        // Counts as fresh, so a non-forced refresh doesn't replace the preview figures.
        lastRefreshAt = .distantFuture
    }

    /// Saves the watermark for a complete export of everything: the library's state as the export finished.
    /// Counts from then on are new since this moment.
    func recordWatermark(_ context: NewPhotosContext) {
        // Under the test host, a finished export must not call iCloud or write the user's Application Support.
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        let store = store
        let date = now()
        Task { [weak self] in
            do {
                let watermark = try await Self.snapshot(context, at: date)
                if let ids = watermark.ids {
                    try store.saveLibraryIDs(ids, for: context)
                }
                try store.save(watermark.value, for: context)
            } catch {
                // Nothing is saved, so the next complete export tries again. Only the fact is logged, not the
                // error, which can name the folder.
                NSLog("Uncloud: couldn’t save the new-photos watermark (%@).", String(describing: type(of: error)))
            }
            self?.refresh(context, force: true)
        }
    }

    /// Refreshes the count, then posts the reminder if it's due. `connected` says the destination folder is there.
    func checkForReminder(
        _ context: NewPhotosContext,
        connected: Bool,
        automaticBackupOn: Bool,
        frequency: NewPhotosReminderFrequency,
        lastReminder: Date?,
        isEnabled: Bool
    ) async -> NewPhotosReminder.Decision {
        await refresh(context, force: true).value
        guard statusContext == context else {
            return .skip(.nothingNew)
        }
        let input = NewPhotosReminder.Input(
            isEnabled: isEnabled,
            count: status?.count ?? 0,
            isAtLeast: status?.isAtLeast ?? false,
            destinationConnected: connected,
            automaticBackupOn: automaticBackupOn,
            signInNeeded: needsSignIn,
            frequency: frequency,
            lastReminder: lastReminder,
            now: now()
        )
        let decision = NewPhotosReminder.decide(input)
        if case let .remind(body) = decision {
            await Self.post(body)
        }
        return decision
    }

    // MARK: - Counting

    private enum Outcome: Sendable {
        case counted(NewPhotosStatus?)
        case signInNeeded
        case cancelled
        case failed
    }

    private func apply(_ outcome: Outcome, for context: NewPhotosContext) {
        switch outcome {
        case let .counted(result):
            needsSignIn = false
            status = result
            statusContext = context
        case .signInNeeded:
            // Keep the last figures; a background check never asks for sign-in.
            needsSignIn = true
        case .cancelled:
            break
        case .failed:
            break
        }
    }

    private nonisolated static func count(_ context: NewPhotosContext, store: NewPhotosStore) async -> Outcome {
        guard let watermark = store.watermark(for: context) else {
            return .counted(nil)
        }
        let since = watermark.exportedAt
        switch context.source {
        case .photosLibrary:
            guard let exported = store.libraryIDs(for: context) else { return .counted(nil) }
            let current = await Task.detached(priority: .utility) { BackupFiles.allLibraryIDs() }.value
            guard !Task.isCancelled else { return .cancelled }
            let count = NewPhotosCounter.countLibrary(current: current, exported: exported)
            return .counted(NewPhotosStatus(count: count, isAtLeast: false, since: since))
        case .iCloud:
            guard let appleID = context.appleID else { return .counted(nil) }
            let fetcher = ICloudBridgeFetcher(bridge: .shared(appleID: appleID))
            do {
                let result = try await NewPhotosCounter.countICloud(since: watermark, fetcher: fetcher)
                return .counted(NewPhotosStatus(count: result.count, isAtLeast: result.isAtLeast, since: since))
            } catch is CancellationError {
                return .cancelled
            } catch ICloudError.signInRequired {
                return .signInNeeded
            } catch {
                return .failed
            }
        }
    }

    /// The watermark for the library as it is now. The Photos library also saves its identifiers.
    private struct Snapshot: Sendable {
        let value: NewPhotosWatermark
        let ids: Set<String>?
    }

    private nonisolated static func snapshot(_ context: NewPhotosContext, at date: Date) async throws -> Snapshot {
        switch context.source {
        case .photosLibrary:
            let ids = await Task.detached(priority: .utility) { BackupFiles.allLibraryIDs() }.value
            return Snapshot(value: NewPhotosWatermark(exportedAt: date, libraryCount: ids.count), ids: ids)
        case .iCloud:
            guard let appleID = context.appleID else { throw ICloudError.signInRequired }
            let newest = try await ICloudBridgeFetcher(bridge: .shared(appleID: appleID)).assets(offset: 0, limit: 1).first
            let value = NewPhotosWatermark(
                exportedAt: date,
                libraryCount: ICloudLibrary.cachedLibraryCount,
                newestAssetID: newest?.id,
                newestAddedDate: newest?.added
            )
            return Snapshot(value: value, ids: nil)
        }
    }

    // MARK: - Notification

    private nonisolated static func post(_ body: String) async {
        let content = UNMutableNotificationContent()
        content.title = NewPhotosReminder.title
        content.body = body
        let request = UNNotificationRequest(identifier: NewPhotosReminder.notificationIdentifier, content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }
}

/// Opens the Backup pane when the new-photos reminder is clicked. Other notifications are left alone.
final class NewPhotosNotificationDelegate: NSObject, UNUserNotificationCenterDelegate, Sendable {
    static let shared = NewPhotosNotificationDelegate()

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        if response.notification.request.identifier == NewPhotosReminder.notificationIdentifier {
            Task { @MainActor in
                AppDelegate.model?.pane = .backup
                NSApp.activate()
            }
        }
        completionHandler()
    }
}
