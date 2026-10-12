import AppKit
import Observation
import Photos
import UserNotifications

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

    /// The sidebar pane of the main window: the Library grid or the Backup pane.
    enum Pane: Hashable {
        case library
        case backup
    }

    /// The sheets of the welcome flow. The landing page replaces the first-run welcome; Help > Getting Started remains.
    enum IntroSheet: Identifiable {
        case gettingStarted

        var id: Self { self }
    }

    var pane: Pane = .library
    private(set) var phase: Phase = .idle
    private(set) var authorization = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    private(set) var destination: Destination?
    private(set) var destinationIssue: String?
    private(set) var totalCount = 0
    private(set) var processedCount = 0
    private(set) var failedCount = 0
    private(set) var hasIncompleteRun = false
    private(set) var previousLayout: FolderLayout?
    private(set) var estimatedTimeRemaining: Duration?
    private(set) var activity: [ActivityEntry] = []
    /// About how much space the current selection takes once exported; nil until known.
    private(set) var storageEstimate: StorageEstimate?
    /// True while the estimate is being worked out (or refined from a sample).
    private(set) var isEstimatingStorage = false
    /// The space the destination's volume has for new files, or nil when unknown.
    private(set) var destinationFreeBytes: Int64?
    var isChoosingDestination = false
    /// Set by the primary button when no folder is chosen yet: export as soon as the folder is picked.
    @ObservationIgnored private var startsAfterChoosingDestination = false
    /// The selection override for the export that waits for a folder, such as Export All Photos.
    @ObservationIgnored private var pendingExportSelection: LibrarySelection?
    var isShowingICloudSignIn = false
    /// Shows the one sign-out confirmation, from the sidebar footer or the File menu.
    var isConfirmingICloudSignOut = false
    /// Help > Getting Started.
    var introSheet: IntroSheet?
    var layout: FolderLayout {
        didSet { UserDefaults.standard.set(layout.rawValue, forKey: Self.layoutKey) }
    }
    var writesSidecars: Bool {
        didSet { UserDefaults.standard.set(writesSidecars, forKey: Self.writesSidecarsKey) }
    }
    /// Where photos come from. Can't change while an export runs.
    var source: LibrarySource {
        didSet {
            guard source != oldValue else { return }
            guard !isExporting else {
                source = oldValue
                return
            }
            UserDefaults.standard.set(source.rawValue, forKey: Self.sourceKey)
            sourceDidChange()
        }
    }
    /// Signing in to iCloud, for the sign-in sheet in iCloud mode.
    let signIn = ICloudSignIn()
    /// Browses the current source's whole library. Nil while iCloud is signed out.
    /// Replaced when the source or the iCloud account changes.
    private(set) var browser: LibraryBrowser?
    /// Which items of the current source exports and automatic backups include. Saved per source
    /// and account; replaced along with `browser`.
    var selection: LibrarySelection = .everything {
        didSet {
            guard selection != oldValue, !isRestoringSelection else { return }
            storage.selectionDidChange(selection)
            scheduleSelectionSave()
        }
    }

    /// Applies the running export's batched events on the main actor.
    @ObservationIgnored private var exportTask: Task<Void, Never>?
    /// The engine of the running export; cancelling it stops the export.
    @ObservationIgnored private var runTask: Task<Void, Never>?
    /// The engine of the last export until it has really ended (its helper has exited), which can be
    /// after the export shows as cancelled. No new export starts before then.
    @ObservationIgnored private let engine = EngineTracker()

    /// True while the last export's engine hasn't ended.
    var isEngineRunning: Bool { engine.isRunning }
    /// Identifies the current run, so a run that was given up on can't change the screen later.
    @ObservationIgnored private var runNumber = 0
    @ObservationIgnored private var gate: PauseGate?
    @ObservationIgnored private var clock = SessionClock()
    @ObservationIgnored private var isAccessingDestination = false
    @ObservationIgnored private var skippedThisRun = 0
    @ObservationIgnored private let selectionStore = LibrarySelectionStore()
    /// The source and account `selection` and `browser` belong to.
    @ObservationIgnored private var selectionOwner: (source: LibrarySource, account: String?)?
    @ObservationIgnored private var isRestoringSelection = false
    @ObservationIgnored private var selectionSaveTask: Task<Void, Never>?
    @ObservationIgnored private let storage = StorageEstimator()
    @ObservationIgnored private var freeSpaceReadAt: ContinuousClock.Instant?

    private static let bookmarkKey = "destinationBookmark"
    private static let layoutKey = "folderLayout"
    private static let writesSidecarsKey = "writeSidecars"
    private static let sourceKey = "librarySource"
    private static let maxActivityEntries = ExportBatch.maxEntries
    /// How often a running export updates the screen.
    static let progressInterval: Duration = .milliseconds(100)
    /// How long Cancel waits for the engine to report that it stopped before showing the export as cancelled anyway.
    static let cancelTimeout: Duration = .seconds(2)
    /// How often the destination's free space is read again while it's on screen.
    static let freeSpaceInterval: Duration = .seconds(30)

    init() {
        let defaults = UserDefaults.standard
        let source = defaults.string(forKey: Self.sourceKey).flatMap(LibrarySource.init) ?? Self.defaultSource()
        defaults.set(source.rawValue, forKey: Self.sourceKey)
        self.source = source
        let savedLayout = defaults.string(forKey: Self.layoutKey).flatMap(FolderLayout.init) ?? .month
        layout = savedLayout.isAvailable(for: source) ? savedLayout : .month
        writesSidecars = defaults.bool(forKey: Self.writesSidecarsKey)
        lastBackupDate = defaults.object(forKey: Self.lastBackupKey) as? Date
        storage.onChange = { [weak self] estimate, isEstimating in
            guard let self else { return }
            if storageEstimate != estimate {
                storageEstimate = estimate
            }
            if isEstimatingStorage != isEstimating {
                isEstimatingStorage = isEstimating
            }
        }
        restoreDestination()
        observeSignIn()
        updateBrowser()

        // An unfinished export opens on the Backup pane, where it can be resumed.
        let unfinished = isSourceReady && (destination.map { ExportManifest.hasIncompleteRun(in: $0.url) } ?? false)
        pane = unfinished ? .backup : .library
    }

    /// New installs use iCloud. An install that already exports from the Photos library keeps doing so.
    private static func defaultSource() -> LibrarySource {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        let hasAccess = status == .authorized || status == .limited
        return hasAccess && UserDefaults.standard.data(forKey: bookmarkKey) != nil ? .photosLibrary : .iCloud
    }

    /// The signed-in iCloud Apple ID. Reads the sign-in state so views update after signing in or out.
    var iCloudAppleID: String? {
        _ = signIn.state
        return ICloudAccount.appleID
    }

    var canSignOutICloud: Bool {
        iCloudAppleID != nil && !isExporting
    }

    func connectPhotoLibrary() {
        Task {
            if authorization == .notDetermined {
                authorization = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
            }
            refreshProgress()
        }
    }

    // MARK: - Library

    private func sourceDidChange() {
        if !layout.isAvailable(for: source) {
            layout = .month
        }
        totalCount = 0
        processedCount = 0
        failedCount = 0
        hasIncompleteRun = false
        previousLayout = nil
        estimatedTimeRemaining = nil
        updateBrowser()
        refreshProgress()
    }

    // MARK: - Browsing and selection

    /// Makes `browser` and `selection` match the current source and iCloud account: keeps them while
    /// those are unchanged, otherwise saves the old selection and loads the new one.
    private func updateBrowser() {
        let account = source == .iCloud ? ICloudAccount.appleID : nil
        if let owner = selectionOwner, owner.source == source, owner.account == account {
            return
        }
        saveSelectionNow()
        selectionOwner = (source, account)
        isRestoringSelection = true
        defer { isRestoringSelection = false }
        switch source {
        case .photosLibrary:
            browser = LibraryBrowser()
            selection = selectionStore.load(source: .photosLibrary, account: nil)
        case .iCloud:
            if let account {
                browser = LibraryBrowser(appleID: account)
                selection = selectionStore.load(source: .iCloud, account: account)
            } else {
                browser = nil
                selection = .everything
            }
        }
        storage.configure(source: source, account: account, browser: browser, selection: selection)
    }

    /// Saves the selection shortly after the last change, and updates the idle totals.
    private func scheduleSelectionSave() {
        selectionSaveTask?.cancel()
        selectionSaveTask = Task {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            saveSelectionNow()
            refreshProgress()
        }
    }

    private func saveSelectionNow() {
        selectionSaveTask?.cancel()
        selectionSaveTask = nil
        guard let owner = selectionOwner, owner.source == .photosLibrary || owner.account != nil else { return }
        let selection = selection
        let store = selectionStore
        do {
            try store.save(selection, source: owner.source, account: owner.account)
        } catch {
            record(.warning, "Couldn’t save your selection: \(error.localizedDescription)")
        }
    }

    /// Follows the sign-in state, so the library and progress update after signing in or out.
    private func observeSignIn() {
        withObservationTracking {
            _ = signIn.state
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                signInStateDidChange()
                observeSignIn()
            }
        }
    }

    private func signInStateDidChange() {
        guard source == .iCloud else { return }
        switch signIn.state {
        case .signedIn:
            updateBrowser()
            if browser?.state == .signInRequired {
                browser?.reload()
            }
            refreshProgress()
        case .idle where ICloudAccount.appleID == nil:
            // Signed out.
            updateBrowser()
            refreshProgress()
        default:
            break
        }
    }

    // MARK: - State

    var isExporting: Bool {
        [.preparing, .running, .paused, .cancelling].contains(phase)
    }

    /// True when the export shows as ended but its engine is still stopping, such as an icloudpd
    /// that takes a few seconds to exit after Cancel. The next export waits for it.
    var isFinishingUp: Bool {
        isEngineRunning && !isExporting
    }

    var hasPhotosAccess: Bool {
        authorization == .authorized || authorization == .limited
    }

    /// Whether the chosen source can be read: signed in to iCloud, or Photos library access.
    var isSourceReady: Bool {
        switch source {
        case .iCloud:
            // Reading the sign-in state lets views update when it changes.
            _ = signIn.state
            return ICloudAccount.appleID != nil
        case .photosLibrary:
            return hasPhotosAccess
        }
    }

    var isPhotosAccessBlocked: Bool {
        authorization == .denied || authorization == .restricted
    }

    /// Set by BackupTools: true while a backup check or library cleanup is running, so no export starts mid-check.
    @ObservationIgnored var isExportBlocked: () -> Bool = { false }

    var canStart: Bool {
        if phase == .paused { return true }
        return !isExporting && !isEngineRunning && !isExportBlocked()
            && destination != nil && destinationIssue == nil && isSourceReady
    }

    var canPause: Bool { phase == .running }

    var canCancel: Bool { [.preparing, .running, .paused].contains(phase) }

    /// The label of the Library's primary button. `total` is the library's item count, once known.
    /// "Export All Photos" when everything is selected, otherwise the number of selected items.
    func exportTitle(total: Int?) -> String {
        if phase == .paused { return "Resume" }
        if selection.isEverything { return "Export All Photos" }
        let count = selection.selectedCount(total: total ?? 0)
        return "Export \(count.formatted()) \(count == 1 ? "Item" : "Items")"
    }

    var fractionComplete: Double {
        totalCount > 0 ? Double(processedCount) / Double(totalCount) : 0
    }

    // MARK: - Export control

    /// Starts an export of the saved selection, or resumes a paused one.
    func startOrResume() {
        startRun(selection: nil)
    }

    /// Exports the whole library, ignoring the saved selection, which stays as it was.
    /// A paused run is resumed as it is.
    func exportAll() {
        guard destination != nil else {
            chooseFolderThenExport(selection: .everything)
            return
        }
        startRun(selection: .everything)
    }

    /// Opens the folder picker for a plain "choose folder". Clears any export that was waiting for a
    /// folder, so a picker cancelled earlier can't start one later.
    func beginChoosingDestination() {
        startsAfterChoosingDestination = false
        pendingExportSelection = nil
        isChoosingDestination = true
    }

    /// Asks for a backup folder, then starts the export once one is chosen. `selection` overrides the
    /// saved selection for that run only.
    func chooseFolderThenExport(selection: LibrarySelection? = nil) {
        guard !isExporting else { return }
        pendingExportSelection = selection
        startsAfterChoosingDestination = true
        isChoosingDestination = true
    }

    /// The primary action of the Library toolbar and the Export menu: picks a folder first when none is set.
    func performPrimaryAction() {
        if destination == nil {
            chooseFolderThenExport()
        } else {
            startOrResume()
        }
    }

    /// Title of the primary action, shared by the Library toolbar and the Export menu.
    func primaryExportTitle(total: Int?) -> String {
        if destination == nil, !isExporting { return "Choose Folder…" }
        return exportTitle(total: total)
    }

    /// Whether the primary action can run. Without a folder it only needs a ready source.
    func primaryExportEnabled(total: Int?) -> Bool {
        if destination == nil { return !isExporting && !isEngineRunning && !isExportBlocked() && isSourceReady }
        if phase == .paused { return canStart }
        return canStart && selection.selectedCount(total: total ?? 0) > 0
    }

    /// Whether Export All Photos can run. Without a folder, it asks for one first. Not while paused: Resume
    /// continues the paused run, and starting another export over it would replace it.
    var canExportAll: Bool {
        if phase == .paused { return false }
        return destination == nil ? !isExporting && !isEngineRunning && !isExportBlocked() && isSourceReady : canStart
    }

    private func startRun(selection: LibrarySelection?) {
        guard canStart else { return }
        if phase == .paused {
            resume()
        } else {
            // Ask first when the estimate says it won't fit. Export All covers at least the selection,
            // so the selection's warning holds for it too.
            if let warning = storageWarning {
                // One question at a time: a second Export from the menu while it's showing does nothing.
                guard !isConfirmingStorageWarning else { return }
                isConfirmingStorageWarning = true
                // Stays on the current pane, so the user can keep browsing; progress is in the Library toolbar and Backup.
                Task {
                    let proceed = await confirmExport(despite: warning)
                    isConfirmingStorageWarning = false
                    guard proceed else { return }
                    await startExport(selection: selection)
                }
            } else {
                Task { await startExport(selection: selection) }
            }
        }
    }

    /// True while the "may not be enough space" question is showing.
    @ObservationIgnored private var isConfirmingStorageWarning = false

    /// Asks whether to export although the destination looks too small.
    private func confirmExport(despite warning: String) async -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "There May Not Be Enough Space"
        alert.informativeText = "\(warning) The export stops if the drive fills up, and you can resume it after making room."
        alert.addButton(withTitle: "Export Anyway")
        alert.addButton(withTitle: "Cancel")
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            return await alert.beginSheetModal(for: window) == .alertFirstButtonReturn
        }
        return alert.runModal() == .alertFirstButtonReturn
    }

    func pause() {
        guard canPause, let gate else { return }
        gate.pause()
        clock.pause()
        estimatedTimeRemaining = nil
        phase = .paused
        record(.info, source == .iCloud ? "Paused." : "Paused. The item in progress will finish first.")
    }

    /// Stops the export. Events that arrived before the engine stopped are still counted, so the
    /// counts stay exact. The engine normally stops within moments (its helper is sent SIGTERM);
    /// if it hasn't after `cancelTimeout`, the export shows as cancelled anyway, and "Finishing up"
    /// (`isFinishingUp`) until the engine has ended, before which no new export starts.
    func cancel() {
        guard canCancel else { return }
        phase = .cancelling
        runTask?.cancel()
        // Let a paused engine wake up and observe the cancellation.
        gate?.resume()
        // Also covers a cancel while the export is still being set up: startExport claims the run
        // number before anything it awaits.
        let run = runNumber
        Task {
            try? await Task.sleep(for: Self.cancelTimeout)
            guard runNumber == run, phase == .cancelling else { return }
            record(.warning, "The export is still stopping in the background.")
            exportTask?.cancel()
            finish(.cancelled)
        }
    }

    /// For quitting: cancels the export, if one runs, and returns its engine's task, which ends once
    /// the engine has stopped (or nil when there's none). The manifest then shows the run as
    /// unfinished, so Resume continues it after the next launch.
    func stopForTermination() -> Task<Void, Never>? {
        if canCancel {
            cancel()
        }
        return engine.task
    }

    private func resume() {
        guard let gate else { return }
        clock.start()
        phase = .running
        gate.resume()
        record(.info, "Resumed.")
    }

    /// `selection` overrides the saved selection for this run only (Export All Photos).
    /// `automatic` marks the run as started by automatic backup, once it has really started.
    private func startExport(selection override: LibrarySelection? = nil, automatic: Bool = false) async {
        guard !isExporting, !isEngineRunning else { return }
        let previousPhase = phase
        phase = .preparing

        guard isSourceReady, let destination else {
            phase = previousPhase
            return
        }
        let appleID = ICloudAccount.appleID
        if source == .iCloud, appleID == nil {
            phase = previousPhase
            return
        }
        guard destination.isWritable() else {
            destinationIssue = Self.notWritableMessage(for: destination)
            phase = previousPhase
            return
        }

        failedCount = 0
        exportedThisRun = 0
        skippedThisRun = 0
        estimatedTimeRemaining = nil
        clock = SessionClock()
        record(.info, "\(hasIncompleteRun ? "Resuming" : "Starting") export to “\(destination.displayName)”, \(layout.title.lowercased()).")

        if !layout.isAvailable(for: source) {
            layout = .month
        }
        // Claimed before anything is awaited, so Cancel's watchdog covers this run from here on.
        runNumber += 1
        let number = runNumber
        isAutomaticRun = automatic
        let gate = PauseGate()
        self.gate = gate
        storage.exportDidStart()
        saveSelectionNow()
        let selection = override ?? selection
        let run: ExportRun
        switch source {
        case .photosLibrary:
            run = ExportEngine(
                destination: destination.url,
                layout: layout,
                writesSidecars: writesSidecars,
                gate: gate,
                selection: selection
            ).start()
        case .iCloud:
            var hints: [String: Int] = [:]
            if case .only(let ids) = selection, let browser {
                hints = await browser.rankHints(for: ids)
                // Cancelled while the browser looked up rank hints: don't start the engine at all.
                guard number == runNumber, phase == .preparing else {
                    if number == runNumber {
                        finish(.cancelled)
                    }
                    return
                }
            }
            run = ICloudExportEngine(
                destination: destination.url,
                layout: layout,
                writesSidecars: writesSidecars,
                appleID: appleID ?? "",
                gate: gate,
                selection: selection,
                rankHints: hints
            ).start()
        }
        runTask = run.task
        engine.track(run.task) { [weak self] in self?.refreshProgress() }
        exportTask = Task { await consume(ExportEventBatcher.batches(of: run.events, interval: Self.progressInterval), run: number) }
    }

    /// Applies the run's events in batches, a few times a second however fast they arrive, so a
    /// fast helper can neither flood the main actor nor build up a backlog that Cancel waits for.
    private func consume(_ batches: AsyncStream<ExportBatch>, run: Int) async {
        for await batch in batches {
            guard run == runNumber else { return }
            apply(batch)
            guard let ending = batch.ending else { continue }
            switch ending {
            case .success:
                finish(.completed)
            case .failure(let error):
                finish(phase == .cancelling || error is CancellationError ? .cancelled : .failed(error.localizedDescription))
            }
            return
        }
        // Only a run that was given up on ends without an ending.
        if run == runNumber {
            finish(.cancelled)
        }
    }

    private func apply(_ batch: ExportBatch) {
        if let prepared = batch.prepared {
            totalCount = prepared.total
            processedCount = prepared.alreadyExported
            // Cancel may already have been chosen while preparing.
            if phase == .preparing {
                phase = .running
                clock.start()
            }
        }
        totalCount += batch.totalIncrease
        processedCount += batch.processed
        skippedThisRun += batch.skipped
        exportedThisRun += batch.exported
        failedCount += batch.failed
        if batch.sawSkip {
            // Skips take almost no time, so keep them out of the rate the estimate uses.
            clock.discardSamples()
        }
        clock.itemsDidFinish(batch.sawSkip ? batch.finishedSinceSkip : batch.exported + batch.failed)
        let entries = batch.recentEntries
        if !entries.isEmpty {
            activity = Array((entries.reversed() + activity).prefix(Self.maxActivityEntries))
        }
        if phase == .running {
            estimatedTimeRemaining = clock.estimate(remainingItems: totalCount - processedCount)
        }
    }

    private func finish(_ result: Phase) {
        clock.pause()
        estimatedTimeRemaining = nil
        exportTask = nil
        runTask = nil
        runNumber += 1
        gate = nil
        phase = result
        if result == .completed {
            lastBackupDate = .now
        }
        storage.exportDidFinish()
        refreshDestinationFreeSpace(force: true)

        if skippedThisRun > 0, result != .idle {
            let noun = skippedThisRun == 1 ? "item was" : "items were"
            record(.info, "\(skippedThisRun.formatted()) \(noun) already in the destination.")
        }
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
        if isAutomaticRun {
            notifyBackupFinished(result)
            isAutomaticRun = false
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
        guard isSourceReady, let url = destination?.url else {
            totalCount = 0
            processedCount = 0
            hasIncompleteRun = false
            previousLayout = nil
            return
        }
        let source = source
        let selection = selection
        Task {
            let progress = await Task.detached {
                source == .iCloud
                    ? Self.iCloudProgress(toward: url, selection: selection)
                    : PhotoLibrary.progress(toward: url, selection: selection)
            }.value
            guard !isExporting, destination?.url == url, self.source == source, self.selection == selection else { return }
            totalCount = progress.total
            processedCount = progress.exported
            hasIncompleteRun = progress.hasIncompleteRun
            previousLayout = progress.previousLayout
        }
    }

    /// The selected part of the iCloud library's last known size, and how many files the destination's
    /// manifest records from iCloud.
    private nonisolated static func iCloudProgress(toward destination: URL, selection: LibrarySelection) -> LibraryProgress {
        let total = selection.selectedCount(total: ICloudLibrary.cachedLibraryCount ?? 0)
        let recorded = ExportManifest.exportedIDs(in: destination)
            .count { $0.hasPrefix(ICloudChecksumScanner.recordPrefix) }
        return LibraryProgress(
            total: total,
            exported: min(total, recorded),
            hasIncompleteRun: ExportManifest.hasIncompleteRun(in: destination),
            previousLayout: ExportManifest.layout(in: destination)
        )
    }

    // MARK: - Storage

    /// The estimate as the Library toolbar shows it, such as "about 412 GB", "estimating…" while
    /// it's worked out, or nil when there's nothing to show.
    var storageEstimateText: String? {
        if let storageEstimate {
            return storageEstimate.formatted
        }
        return isEstimatingStorage && isSourceReady ? "estimating…" : nil
    }

    /// What the estimate counts, and how it was arrived at.
    var storageEstimateNote: String? {
        guard let storageEstimate else { return nil }
        switch storageEstimate.basis {
        case .heuristic:
            return "Estimated from each item’s dimensions and length, including edited versions and Live Photo videos."
        case .scanned where storageEstimate.isExact:
            return "Originals and Live Photo videos, as sized by iCloud."
        case .scanned, .sampled:
            return "Originals and Live Photo videos, estimated from the items checked so far. Uncloud checks the rest in the background."
        }
    }

    /// The part of the estimate still to copy: items the destination already has are left out. In
    /// proportion to the item counts, so approximate when some are already there.
    var storageNeededBytes: Int64? {
        guard let storageEstimate else { return nil }
        return StorageCheck.remainingBytes(of: storageEstimate, selected: totalCount, exported: processedCount)
    }

    /// A warning when the export looks too big for the destination's free space.
    var storageWarning: String? {
        guard let destination, destinationIssue == nil, let storageEstimate else { return nil }
        return StorageCheck.warning(
            needed: storageNeededBytes,
            isExact: storageEstimate.isExact && processedCount == 0,
            free: destinationFreeBytes,
            destinationName: destination.displayName
        )
    }

    /// Reads the destination volume's free space off the main actor. Without `force`, at most once
    /// per `freeSpaceInterval`.
    func refreshDestinationFreeSpace(force: Bool = false) {
        guard let url = destination?.url, destinationIssue == nil else { return }
        if !force, let readAt = freeSpaceReadAt, readAt.duration(to: .now) < Self.freeSpaceInterval - .seconds(1) {
            return
        }
        freeSpaceReadAt = .now
        Task {
            let free = await Task.detached(priority: .utility) { StorageCheck.freeBytes(at: url) }.value
            guard destination?.url == url, destinationFreeBytes != free else { return }
            destinationFreeBytes = free
        }
    }

    // MARK: - Destination

    func chooseDestination(_ result: Result<URL, Error>) {
        let startsExport = startsAfterChoosingDestination
        let exportSelection = pendingExportSelection
        startsAfterChoosingDestination = false
        pendingExportSelection = nil
        switch result {
        case let .success(url):
            setDestination(url, persist: true)
            if startsExport {
                startRun(selection: exportSelection)
            }
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
        destinationFreeBytes = nil
        refreshDestinationFreeSpace(force: true)

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
            // Usually the drive isn't connected. Keep the bookmark so the folder reconnects once it's mounted.
            showUnavailableDestination(from: bookmark)
            return
        }
        setDestination(url, persist: isStale)
    }

    private func showUnavailableDestination(from bookmark: Data) {
        guard let path = URL.resourceValues(forKeys: [.pathKey], fromBookmarkData: bookmark)?.path else { return }
        if isAccessingDestination {
            destination?.url.stopAccessingSecurityScopedResource()
            isAccessingDestination = false
        }
        let destination = Destination(url: URL(filePath: path, directoryHint: .isDirectory))
        self.destination = destination
        destinationFreeBytes = nil
        destinationIssue = "“\(destination.displayName)” isn’t available. Connect the drive or choose a different folder."
    }

    private static func notWritableMessage(for destination: Destination) -> String {
        "You can’t save files to “\(destination.displayName)”. Choose a different folder."
    }

    // MARK: - Automatic backup

    private(set) var lastBackupDate: Date? {
        didSet { UserDefaults.standard.set(lastBackupDate, forKey: Self.lastBackupKey) }
    }

    @ObservationIgnored private var isAutomaticRun = false {
        didSet { isAutomaticRunInProgress = isAutomaticRun }
    }
    /// True while the current run was started by automatic backup rather than by the user.
    private(set) var isAutomaticRunInProgress = false
    @ObservationIgnored private var exportedThisRun = 0

    private static let lastBackupKey = "lastBackupDate"

    /// Whether a background run may start now: no export in progress, a ready source, and a destination.
    var canBackUpAutomatically: Bool {
        !isExporting && !isEngineRunning && !isExportBlocked() && isSourceReady && destination != nil
    }

    /// The volume that holds the destination, such as the external drive.
    var destinationVolumeURL: URL? {
        guard let url = destination?.url else { return nil }
        return (try? url.resourceValues(forKeys: [.volumeURLKey]))?.volume
    }

    /// Re-resolves the saved destination so a drive that was just mounted gets access again.
    func reconnectDestination() {
        guard !isExporting else { return }
        restoreDestination()
    }

    /// Copies new items without leaving the current screen.
    func backUpAutomatically(reason: String) {
        guard canBackUpAutomatically else { return }
        reconnectDestination()
        if let destinationIssue {
            record(.warning, "Automatic backup didn’t run: \(destinationIssue)")
            return
        }

        record(.info, "Automatic backup started (\(reason)).")
        Task {
            // The run is marked automatic only once startExport has actually started it.
            await startExport(automatic: true)
        }
    }

    private func notifyBackupFinished(_ result: Phase) {
        let name = destination?.displayName ?? "your destination"
        let body: String
        switch result {
        case .completed where failedCount > 0:
            body = "Backup finished, but \(failedCount.formatted()) items couldn’t be copied."
        case .completed where exportedThisRun == 0:
            body = "Your backup on “\(name)” is up to date."
        case .completed:
            let noun = exportedThisRun == 1 ? "item" : "items"
            body = "Backed up \(exportedThisRun.formatted()) new \(noun) to “\(name)”."
        case let .failed(message):
            body = message
        default:
            return
        }
        postNotification(body)
    }

    private func postNotification(_ body: String) {
        Task {
            let content = UNMutableNotificationContent()
            content.title = "Uncloud"
            content.body = body
            let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
            try? await UNUserNotificationCenter.current().add(request)
        }
    }

    // MARK: - Activity

    private func record(_ kind: ActivityEntry.Kind, _ message: String) {
        activity.insert(ActivityEntry(kind: kind, message: message), at: 0)
        if activity.count > Self.maxActivityEntries {
            activity.removeLast()
        }
    }
}

/// The engine of the latest export, until its task has really ended. Cancel can show an export as
/// cancelled before that (see `ExportModel.cancelTimeout`); a new export waits for `isRunning`.
@MainActor
@Observable
final class EngineTracker {
    private(set) var isRunning = false
    @ObservationIgnored private(set) var task: Task<Void, Never>?

    /// Follows `task` until it ends, then calls `onEnd` unless a newer task is followed by then.
    func track(_ task: Task<Void, Never>, onEnd: @escaping @MainActor () -> Void = {}) {
        self.task = task
        isRunning = true
        Task {
            await task.value
            guard self.task == task else { return }
            self.task = nil
            isRunning = false
            onEnd()
        }
    }
}
