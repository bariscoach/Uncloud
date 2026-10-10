import AppKit
import Observation
import Photos

@MainActor
@Observable
final class ExportModel {
    enum Phase: Equatable {
        case idle
        case preparing
        case running
        case paused
        case cancelling
        case completed
        case cancelled
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    private(set) var authorization = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    private(set) var destination: Destination?
    private(set) var destinationIssue: String?
    private(set) var totalCount = 0
    private(set) var processedCount = 0
    private(set) var failedCount = 0
    private(set) var hasIncompleteRun = false
    private(set) var estimatedTimeRemaining: Duration?
    private(set) var activity: [ActivityEntry] = []
    var isChoosingDestination = false

    @ObservationIgnored private var exportTask: Task<Void, Never>?
    @ObservationIgnored private var gate: PauseGate?
    @ObservationIgnored private var clock = SessionClock()
    @ObservationIgnored private var isAccessingDestination = false

    private static let bookmarkKey = "destinationBookmark"
    private static let maxActivityEntries = 500

    init() {
        restoreDestination()
    }

    // MARK: - State

    var isExporting: Bool {
        [.preparing, .running, .paused, .cancelling].contains(phase)
    }

    var hasPhotosAccess: Bool {
        authorization == .authorized || authorization == .limited
    }

    var isPhotosAccessBlocked: Bool {
        authorization == .denied || authorization == .restricted
    }

    var canStart: Bool {
        if phase == .paused { return true }
        return !isExporting && destination != nil && destinationIssue == nil && !isPhotosAccessBlocked
    }

    var canPause: Bool { phase == .running }

    var canCancel: Bool { [.preparing, .running, .paused].contains(phase) }

    var startTitle: String {
        phase == .paused || (hasIncompleteRun && !isExporting) ? "Resume" : "Start Export"
    }

    var fractionComplete: Double {
        totalCount > 0 ? Double(processedCount) / Double(totalCount) : 0
    }

    // MARK: - Export control

    func startOrResume() {
        guard canStart else { return }
        if phase == .paused {
            resume()
        } else {
            Task { await startExport() }
        }
    }

    func pause() {
        guard canPause, let gate else { return }
        gate.pause()
        clock.pause()
        estimatedTimeRemaining = nil
        phase = .paused
        record(.info, "Paused. The item in progress will finish first.")
    }

    func cancel() {
        guard canCancel else { return }
        phase = .cancelling
        exportTask?.cancel()
        // Let a paused engine wake up and observe the cancellation.
        gate?.resume()
    }

    private func resume() {
        guard let gate else { return }
        clock.start()
        phase = .running
        gate.resume()
        record(.info, "Resumed.")
    }

    private func startExport() async {
        guard !isExporting else { return }
        let previousPhase = phase
        phase = .preparing

        if authorization == .notDetermined {
            authorization = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        }
        guard hasPhotosAccess, let destination else {
            phase = previousPhase
            return
        }
        guard destination.isWritable() else {
            destinationIssue = Self.notWritableMessage(for: destination)
            phase = previousPhase
            return
        }

        failedCount = 0
        estimatedTimeRemaining = nil
        clock = SessionClock()
        record(.info, "\(hasIncompleteRun ? "Resuming" : "Starting") export to “\(destination.displayName)”.")

        let gate = PauseGate()
        self.gate = gate
        let events = ExportEngine(destination: destination.url, gate: gate).events()
        exportTask = Task { await consume(events) }
    }

    private func consume(_ events: AsyncThrowingStream<ExportEvent, Error>) async {
        do {
            for try await event in events {
                handle(event)
            }
            finish(Task.isCancelled ? .cancelled : .completed)
        } catch {
            finish(.failed(error.localizedDescription))
        }
    }

    private func handle(_ event: ExportEvent) {
        switch event {
        case let .prepared(total, alreadyExported):
            totalCount = total
            processedCount = alreadyExported
            phase = .running
            clock.start()
            if alreadyExported > 0 {
                record(.info, "Skipping \(alreadyExported.formatted()) items that were already exported.")
            }
        case let .exported(name, fileCount):
            processedCount += 1
            clock.itemFinished()
            record(.success, fileCount > 1 ? "Exported \(name) (\(fileCount) files)" : "Exported \(name)")
        case let .failed(name, reason):
            processedCount += 1
            failedCount += 1
            clock.itemFinished()
            record(.warning, "Couldn’t export \(name): \(reason)")
        }
        if phase == .running {
            estimatedTimeRemaining = clock.estimate(remainingItems: totalCount - processedCount)
        }
    }

    private func finish(_ result: Phase) {
        clock.pause()
        estimatedTimeRemaining = nil
        exportTask = nil
        gate = nil
        phase = result

        switch result {
        case .completed where failedCount > 0:
            record(.warning, "Export finished, but \(failedCount.formatted()) items couldn’t be exported. Choose Resume to try them again.")
        case .completed:
            record(.success, "Export complete.")
        case .cancelled:
            record(.info, "Export cancelled. Choose Resume to continue later.")
        case let .failed(message):
            record(.error, message)
        default:
            break
        }
        refreshProgress()
    }

    // MARK: - Photos access

    func refreshAuthorization() {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if status != authorization {
            authorization = status
        }
        refreshProgress()
    }

    func openPhotosPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Photos") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Updates the idle "X of Y items" figures from the library and the destination's manifest.
    func refreshProgress() {
        guard !isExporting else { return }
        guard hasPhotosAccess, let url = destination?.url else {
            totalCount = 0
            processedCount = 0
            hasIncompleteRun = false
            return
        }
        Task {
            let progress = await Task.detached { PhotoLibrary.progress(toward: url) }.value
            guard !isExporting, destination?.url == url else { return }
            totalCount = progress.total
            processedCount = progress.exported
            hasIncompleteRun = progress.hasIncompleteRun
        }
    }

    // MARK: - Destination

    func chooseDestination(_ result: Result<URL, Error>) {
        switch result {
        case let .success(url):
            setDestination(url, persist: true)
        case let .failure(error):
            record(.error, error.localizedDescription)
        }
    }

    func revealDestination() {
        guard let url = destination?.url else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func setDestination(_ url: URL, persist: Bool) {
        if isAccessingDestination {
            destination?.url.stopAccessingSecurityScopedResource()
        }
        isAccessingDestination = url.startAccessingSecurityScopedResource()

        let destination = Destination(url: url)
        self.destination = destination
        destinationIssue = destination.isWritable() ? nil : Self.notWritableMessage(for: destination)

        if persist, let bookmark = try? url.bookmarkData(options: .withSecurityScope) {
            UserDefaults.standard.set(bookmark, forKey: Self.bookmarkKey)
        }
        refreshProgress()
    }

    private func restoreDestination() {
        guard let bookmark = UserDefaults.standard.data(forKey: Self.bookmarkKey) else { return }
        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: bookmark,
            options: .withSecurityScope,
            bookmarkDataIsStale: &isStale
        ) else {
            UserDefaults.standard.removeObject(forKey: Self.bookmarkKey)
            return
        }
        setDestination(url, persist: isStale)
    }

    private static func notWritableMessage(for destination: Destination) -> String {
        "You can’t save files to “\(destination.displayName)”. Choose a different folder."
    }

    // MARK: - Activity

    private func record(_ kind: ActivityEntry.Kind, _ message: String) {
        activity.insert(ActivityEntry(kind: kind, message: message), at: 0)
        if activity.count > Self.maxActivityEntries {
            activity.removeLast()
        }
    }
}
