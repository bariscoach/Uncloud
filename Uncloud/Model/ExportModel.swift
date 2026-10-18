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
        case cleanup
        case browse
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
    /// True when the unfinished run was Export All, as its session recorded. Resume Export continues it with everything.
    private(set) var interruptedRunWasExportAll = false
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
    /// The folder layout. Every change goes through `requestLayoutChange(to:)`, which asks first when the change
    /// would download an iCloud library again.
    private(set) var layout: FolderLayout {
        didSet {
            UserDefaults.standard.set(layout.rawValue, forKey: Self.layoutKey)
            if layout != oldValue {
                layoutDidChange()
            }
        }
    }
    var writesSidecars: Bool {
        didSet { UserDefaults.standard.set(writesSidecars, forKey: Self.writesSidecarsKey) }
    }
    /// Where photos come from. Can't change while an export runs.
    var source: LibrarySource {
        didSet {
            guard source != oldValue else { return }
            guard !isExporting, iCloudCleanup?.isRunning != true else {
                source = oldValue
                return
            }
            UserDefaults.standard.set(source.rawValue, forKey: Self.sourceKey)
            sourceDidChange()
        }
    }
    /// Signing in to iCloud, for the sign-in sheet in iCloud mode.
    let signIn = ICloudSignIn()
    /// The new-photos count and watermark. See ExportModel+NewPhotos.swift.
    let newPhotos = NewPhotosTracker()
    /// Browses the current source's whole library. Nil while iCloud is signed out.
    /// Replaced when the source or the iCloud account changes.
    private(set) var browser: LibraryBrowser?
    /// Browses Recently Deleted, the iCloud album of items deleted from iCloud Photos. Nil while iCloud is signed out.
    /// Replaced with `browser`.
    private(set) var recentlyDeletedBrowser: LibraryBrowser?
    /// Deletes items from iCloud Photos, and recovers them from Recently Deleted, for the current account; nil while
    /// iCloud is signed out. Replaced with `browser`.
    private(set) var iCloudCleanup: ICloudCleanup?
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

    /// The export that stopped for a reason that usually passes, and when it starts again by itself.
    /// The phase stays `.failed` meanwhile; views show it as waiting.
    private(set) var autoResume: AutoResume?
    /// True while the current run was started by an automatic resume, which, like an automatic backup,
    /// doesn't announce itself.
    private(set) var isAutoResumedRunInProgress = false
    /// How long automatic resumes wait. Tests shorten it.
    @ObservationIgnored var autoResumeTiming = AutoResumeTiming()
    /// The wall clock automatic resumes are scheduled against. Tests move it forward.
    @ObservationIgnored var currentDate: @MainActor () -> Date = { Date() }
    /// Sleeps until the pending resume is due, then starts it, re-checking the clock at least every `recheckInterval`.
    @ObservationIgnored private var autoResumeTask: Task<Void, Never>?
    /// Wake and mount observers, while a resume is pending.
    @ObservationIgnored private var autoResumeObservers: [NSObjectProtocol] = []
    /// How the current run was started, so a retryable failure can start it again the same way.
    @ObservationIgnored private var currentRun: (selection: LibrarySelection?, automatic: Bool, resumeAttempt: Int?)?

    // MARK: Sessions and the drive check (state for the views)

    /// What "Check the drive" is doing, or what it last found.
    enum DriveCheckState: Equatable {
        case notChecked
        /// Listing the drive: files so far, and the last check's file count when there was one.
        case checking(filesListed: Int, expectedFiles: Int?, mode: DriveInventory.Mode)
        case checked(DriveCheckReport)
        case failed(String)
    }

    /// The drive check's state. Runs before every export (quick), when a folder is chosen or reconnected
    /// (quick), and on `checkDrive()` (full by default).
    private(set) var driveCheckState: DriveCheckState = .notChecked
    /// The last finished check's report for this destination, kept while a new check runs.
    private(set) var lastDriveCheck: DriveCheckReport?
    /// The report of a check the person started with Check Drive, until its results sheet is dismissed.
    private(set) var lastManualDriveCheck: DriveCheckReport?
    /// When the last check of this destination finished, this launch. Nil until one has.
    private(set) var lastDriveCheckedAt: Date?
    /// This destination's export sessions, oldest first, as read from `.photo-export/sessions/` and kept
    /// up to date by the running export. Empty while the drive isn't connected.
    private(set) var sessions: [ExportSession] = []
    /// One per app launch; tells this launch's running sessions from orphaned ones.
    static let launchID = UUID()
    /// How often a running export's session file gets its heartbeat during long waits.
    @ObservationIgnored var sessionHeartbeatInterval: Duration = .seconds(30)
    /// The running export's session.
    @ObservationIgnored private var recorder: SessionRecorder?
    /// The session of the last export this launch ran, for chaining an automatic resume to it.
    @ObservationIgnored private var lastSession: ExportSession?
    @ObservationIgnored private var heartbeatTask: Task<Void, Never>?
    /// The running export's destination, while it's in `exportingDestinations`.
    @ObservationIgnored private var exportingURL: URL?
    /// The drive check in progress, so Cancel and a starting export can stop it.
    @ObservationIgnored private var driveCheckTask: Task<DriveCheckReport?, Never>?
    @ObservationIgnored private var driveCheckToken = UUID()
    /// The watermark the running export of everything will save if it completes. Captured before its walk starts.
    @ObservationIgnored var newPhotosCandidate: NewPhotosCandidate?

    static let bookmarkKey = "destinationBookmark"
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
        cancelAutoResume()
        if !layout.isAvailable(for: source) {
            layout = .month
        }
        totalCount = 0
        processedCount = 0
        failedCount = 0
        hasIncompleteRun = false
        interruptedRunWasExportAll = false
        previousLayout = nil
        estimatedTimeRemaining = nil
        isOnDriveCountApproximate = false
        lastDriveCheck = nil
        lastManualDriveCheck = nil
        lastDriveCheckedAt = nil
        driveCheckState = .notChecked
        iCloudItemsByLayout = [:]
        iCloudItemsByLayoutFolder = nil
        updateBrowser()
        refreshProgress()
        checkDriveWhenIdle()
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
            recentlyDeletedBrowser = nil
            iCloudCleanup = nil
            selection = selectionStore.load(source: .photosLibrary, account: nil)
        case .iCloud:
            if let account {
                let newBrowser = LibraryBrowser(appleID: account)
                let trash = LibraryBrowser(appleID: account, album: .recentlyDeleted)
                browser = newBrowser
                recentlyDeletedBrowser = trash
                iCloudCleanup = makeICloudCleanup(appleID: account, browser: newBrowser, recentlyDeleted: trash)
                selection = selectionStore.load(source: .iCloud, account: account)
            } else {
                browser = nil
                recentlyDeletedBrowser = nil
                iCloudCleanup = nil
                selection = .everything
            }
        }
        storage.configure(source: source, account: account, browser: browser, selection: selection)
    }

    private func makeICloudCleanup(appleID: String, browser: LibraryBrowser, recentlyDeleted: LibraryBrowser) -> ICloudCleanup {
        ICloudCleanup(appleID: appleID, bridge: .shared(appleID: appleID), environment: ICloudCleanup.Environment(
            isExportRunning: { [weak self] in self.map { $0.isExporting || $0.isEngineRunning } ?? false },
            libraryCount: { [weak browser] in browser?.count },
            rankHints: { [weak browser] ids in await browser?.rankHints(for: ids) ?? [:] },
            libraryDidChange: { [weak self, weak browser, weak recentlyDeleted] deleted in
                Self.iCloudAlbumsDidChange(browser: browser, recentlyDeleted: recentlyDeleted)
                self?.iCloudItemsDeleted(deleted)
            },
            recentlyDeletedCount: { [weak recentlyDeleted] in recentlyDeleted?.count },
            recentlyDeletedRankHints: { [weak recentlyDeleted] ids in await recentlyDeleted?.rankHints(for: ids) ?? [:] },
            recoveryDidChange: { [weak self, weak browser, weak recentlyDeleted] _ in
                Self.iCloudAlbumsDidChange(browser: browser, recentlyDeleted: recentlyDeleted)
                // Recovered items join the library, but the export selection is left as it is.
                self?.storage.libraryContentsDidChange()
            }
        ))
    }

    /// After items moved between the library and Recently Deleted: both albums count again, and the saved sizes,
    /// which were measured for the library before, are measured again.
    private static func iCloudAlbumsDidChange(browser: LibraryBrowser?, recentlyDeleted: LibraryBrowser?) {
        browser?.reload()
        recentlyDeleted?.reload()
        AssetSizeStore().removeAll()
    }

    /// After items were deleted from iCloud Photos: the export selection forgets them, and the size estimate
    /// measures the library again. The backup on the destination drive is not touched.
    func iCloudItemsDeleted(_ ids: Set<String>) {
        selection = selection.forgetting(ids)
        storage.libraryContentsDidChange()
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
            cancelAutoResume()
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
        if offersResumeExport { return "Resume Export" }
        if selection.isEverything { return "Export All Photos" }
        let count = selection.selectedCount(total: total ?? 0)
        return "Export \(count.formatted()) \(count == 1 ? "Item" : "Items")"
    }

    var fractionComplete: Double {
        totalCount > 0 ? Double(processedCount) / Double(totalCount) : 0
    }

    // MARK: - Export control

    /// True while an unfinished run waits to be resumed by hand, after it stopped, failed or was cancelled. Then the
    /// primary action continues it instead of starting over. Not while exporting, or while an automatic resume is counting down.
    var offersResumeExport: Bool {
        Self.offersResumeExport(phase: phase, hasIncompleteRun: hasIncompleteRun, autoResume: autoResume)
    }

    nonisolated static func offersResumeExport(phase: Phase, hasIncompleteRun: Bool, autoResume: AutoResume?) -> Bool {
        switch phase {
        case .idle, .cancelled, .failed:
            hasIncompleteRun && autoResume == nil
        case .preparing, .running, .paused, .cancelling, .completed:
            false
        }
    }

    /// Starts an export of the saved selection, resumes a paused one, or, when an unfinished run waits, continues
    /// it with the selection it used (Export All, else the saved one). A resumed run is recorded as resumed by hand.
    func startOrResume() {
        if offersResumeExport {
            startRun(selection: interruptedRunWasExportAll ? .everything : nil, resumesInterrupted: true)
        } else {
            startRun(selection: nil)
        }
    }

    /// Starts a new export with the current selection instead of resuming. Nothing is deleted; files already
    /// on the drive are skipped.
    func startNewExport() {
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
        layoutAfterChoosingFolder = nil
        isChoosingDestination = true
    }

    /// Asks for a backup folder, then starts the export once one is chosen. `selection` overrides the
    /// saved selection for that run only.
    func chooseFolderThenExport(selection: LibrarySelection? = nil) {
        guard !isExporting else { return }
        layoutAfterChoosingFolder = nil
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
        NewPhotosTitle.primary(
            isPaused: phase == .paused,
            hasInterruptedRun: hasIncompleteRun,
            needsFolder: destination == nil && !isExporting,
            isEverything: selection.isEverything,
            hasNewPhotosStatus: newPhotosStatus != nil,
            fallback: exportTitle(total: total)
        )
    }

    /// Whether the primary action can run. Without a folder it only needs a ready source.
    func primaryExportEnabled(total: Int?) -> Bool {
        if destination == nil { return !isExporting && !isEngineRunning && !isExportBlocked() && isSourceReady }
        if phase == .paused || offersResumeExport { return canStart }
        return canStart && selection.selectedCount(total: total ?? 0) > 0
    }

    /// Whether Export All Photos can run. Without a folder, it asks for one first. Not while paused or while an
    /// interrupted run awaits Resume Export: those continue the run, and starting another export over it would replace it.
    var canExportAll: Bool {
        if phase == .paused || offersResumeExport { return false }
        return destination == nil ? !isExporting && !isEngineRunning && !isExportBlocked() && isSourceReady : canStart
    }

    private func startRun(selection: LibrarySelection?, resumesInterrupted: Bool = false) {
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
                    let proceed = await (storageWarningConfirmation ?? confirmExport(despite:))(warning)
                    isConfirmingStorageWarning = false
                    guard proceed else { return }
                    await startExport(selection: selection, resumesInterrupted: resumesInterrupted)
                }
            } else {
                Task { await startExport(selection: selection, resumesInterrupted: resumesInterrupted) }
            }
        }
    }

    /// Replaces the "may not be enough space" alert, for tests.
    @ObservationIgnored var storageWarningConfirmation: (@MainActor (String) async -> Bool)?

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
        recorder?.checkpoint()
        record(.info, source == .iCloud ? "Paused." : "Paused. The item in progress will finish first.")
    }

    /// Stops the export. Events that arrived before the engine stopped are still counted, so the
    /// counts stay exact. The engine normally stops within moments (its helper is sent SIGTERM);
    /// if it hasn't after `cancelTimeout`, the export shows as cancelled anyway, and "Finishing up"
    /// (`isFinishingUp`) until the engine has ended, before which no new export starts.
    func cancel() {
        cancelAutoResume()
        guard canCancel else { return }
        phase = .cancelling
        driveCheckTask?.cancel()
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
        cancelAutoResume()
        // The history says why this run stopped; the manifest keeps it resumable.
        recorder?.finish(status: .interrupted, reason: "Uncloud quit while exporting")
        if canCancel {
            cancel()
        }
        return engine.task
    }

    /// Waits until session files handed to the background writer are on disk, for quitting.
    func flushSessionWrites() async {
        await (recorder ?? lastSessionRecorder)?.flush()
    }

    /// The last finished run's recorder, until its writes are flushed at quit.
    @ObservationIgnored private var lastSessionRecorder: SessionRecorder?

    private func resume() {
        guard let gate else { return }
        clock.start()
        phase = .running
        gate.resume()
        recorder?.checkpoint()
        record(.info, "Resumed.")
    }

    /// `selection` overrides the saved selection for this run only (Export All Photos).
    /// `automatic` marks the run as started by automatic backup, once it has really started.
    /// `resumeAttempt` marks it as an automatic resume; any other run replaces a pending resume.
    /// `resumesInterrupted` marks it as Resume Export, which continues the unfinished run whatever its age.
    /// Returns whether the run started.
    @discardableResult
    private func startExport(
        selection override: LibrarySelection? = nil,
        automatic: Bool = false,
        resumeAttempt: Int? = nil,
        resumesInterrupted: Bool = false
    ) async -> Bool {
        guard !isExporting, !isEngineRunning else { return false }
        cancelNewPhotosRefresh()
        newPhotosCandidate = nil
        let previousPhase = phase
        phase = .preparing

        guard isSourceReady, let destination else {
            phase = previousPhase
            return false
        }
        let appleID = ICloudAccount.appleID
        if source == .iCloud, appleID == nil {
            phase = previousPhase
            return false
        }
        guard destination.isWritable() else {
            destinationIssue = Self.notWritableMessage(for: destination)
            phase = previousPhase
            return false
        }
        if resumeAttempt == nil {
            // This run replaces a pending automatic resume.
            cancelAutoResume()
        }

        failedCount = 0
        exportedThisRun = 0
        skippedThisRun = 0
        estimatedTimeRemaining = nil
        clock = SessionClock()
        let isResuming = hasIncompleteRun
        record(.info, "\(isResuming ? "Resuming" : "Starting") export to “\(destination.displayName)”, \(layout.title.lowercased()).")

        if !layout.isAvailable(for: source) {
            layout = .month
        }
        // Claimed before anything is awaited, so Cancel's watchdog covers this run from here on.
        runNumber += 1
        let number = runNumber
        isAutomaticRun = automatic
        isAutoResumedRunInProgress = resumeAttempt != nil
        currentRun = (override, automatic, resumeAttempt)
        let gate = PauseGate()
        self.gate = gate
        storage.exportDidStart()
        saveSelectionNow()
        let selection = override ?? selection
        exportingURL = destination.url.standardizedFileURL
        exportingURL.map { _ = Self.exportingDestinations.insert($0) }
        beginSession(
            destination: destination.url,
            selection: selection,
            override: override,
            automatic: automatic,
            resumeAttempt: resumeAttempt,
            isResuming: isResuming,
            resumesInterrupted: resumesInterrupted,
            appleID: appleID
        )

        // Check the drive first, so the run starts from what is already there. An idle check gives way.
        await stopDriveCheck()
        var report: DriveCheckReport?
        if number == runNumber, phase == .preparing {
            let mode: DriveInventory.Mode = layout == .flat ? .full : .quick
            let folder = recorder.map { SessionStore.baseName(for: $0.session) } ?? Self.checkFolderName()
            // Held in driveCheckTask, so Cancel stops it.
            let check = Task<DriveCheckReport?, Never> { [weak self] in
                await self?.performDriveCheck(mode: mode, setAsideFolder: folder)
            }
            driveCheckTask = check
            report = await check.value
            if driveCheckTask == check {
                driveCheckTask = nil
            }
        }
        // Cancelled while checking: don't start the engine at all.
        guard number == runNumber, phase == .preparing else {
            if number == runNumber {
                finish(.cancelled)
            }
            return true
        }
        // The watermark is captured before the walk, so items added during the run stay new afterwards.
        newPhotosCandidate = await captureNewPhotosCandidate(for: selection)
        guard number == runNumber, phase == .preparing else {
            if number == runNumber {
                finish(.cancelled)
            }
            return true
        }
        if let report {
            recorder?.update { $0.driveCheck = report.summary }
            recorder?.checkpoint()
            if report.selectedCount > 0 {
                totalCount = report.selectedCount
            }
            processedCount = report.onDrive
            if report.onDrive > 0 {
                record(.info, "Continuing from where the last export stopped: \(report.isApproximate ? "about " : "")\(report.onDrive.formatted()) already on this drive.")
            }
        }

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
            // Files the check found missing are fetched again by ID, near where the browser last saw them.
            let missing = selection.isEverything ? Set(report?.forgottenItemIDs ?? []) : []
            var hintIDs: Set<String>?
            if case .only(let ids) = selection {
                hintIDs = ids
            } else if !missing.isEmpty {
                hintIDs = missing
            }
            if let hintIDs, let browser {
                hints = await browser.rankHints(for: hintIDs)
                // Cancelled while the browser looked up rank hints: don't start the engine at all.
                guard number == runNumber, phase == .preparing else {
                    if number == runNumber {
                        finish(.cancelled)
                    }
                    return true
                }
            }
            run = ICloudExportEngine(
                destination: destination.url,
                layout: layout,
                writesSidecars: writesSidecars,
                appleID: appleID ?? "",
                gate: gate,
                selection: selection,
                rankHints: hints,
                alreadyOnDrive: report?.onDrive,
                missingItems: missing,
                resumeSettings: iCloudResumeSettings
            ).start()
        }
        runTask = run.task
        engine.track(run.task) { [weak self] in self?.refreshProgress() }
        exportTask = Task { await consume(ExportEventBatcher.batches(of: run.events, interval: Self.progressInterval), run: number) }
        return true
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
                if phase == .cancelling || error is CancellationError {
                    finish(.cancelled)
                } else {
                    finish(.failed(error.localizedDescription), error: error)
                }
            }
            return
        }
        // Only a run that was given up on ends without an ending.
        if run == runNumber {
            finish(.cancelled)
        }
    }

    private func apply(_ batch: ExportBatch) {
        if let recorder {
            if let prepared = batch.prepared {
                let source = source
                recorder.update { session in
                    // The engine knows the selection's size exactly; the session only guessed it.
                    if session.selection.kind != .only {
                        session.selection.count = prepared.total
                    }
                    if source == .photosLibrary, session.selection.kind == .everything {
                        session.libraryCount = prepared.total
                    }
                }
                recorder.markPrepared()
            }
            if let continuation = batch.continuation {
                recorder.update { $0.continuation = continuation }
            }
            recorder.record(exported: batch.exported, skipped: batch.skipped, failures: batch.failures,
                            failedCount: batch.failed, bytes: batch.bytes)
        }
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

    /// `error` is what ended a failed run, which decides whether it's resumed automatically.
    private func finish(_ result: Phase, error: Error? = nil) {
        let run = currentRun
        currentRun = nil
        isAutoResumedRunInProgress = false
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
        recordNewPhotosWatermark(result, selection: run?.selection ?? selection)
        storage.exportDidFinish()
        refreshDestinationFreeSpace(force: true)

        if skippedThisRun > 0, result != .idle {
            let noun = skippedThisRun == 1 ? "item was" : "items were"
            record(.info, "\(skippedThisRun.formatted()) \(noun) already in the destination.")
        }
        switch result {
        case .completed where failedCount > 0:
            record(.warning, "Export finished, but \(failedCount.formatted()) items couldn’t be \(source.copiedVerb). Choose Resume to try them again.")
        case .completed:
            record(.success, "Export complete.")
        case .cancelled:
            record(.info, "Export cancelled. Choose Resume to continue later.")
        case let .failed(message):
            record(.error, message)
        default:
            break
        }
        var notifies = isAutomaticRun
        var scheduled: AutoResume?
        if case .failed = result, let error, let run, let reason = AutoResumePolicy.reason(for: error) {
            // Notified only if Uncloud gives up, not for each pause.
            notifies = false
            if let attempt = AutoResumePolicy.nextAttempt(after: run.resumeAttempt, downloaded: exportedThisRun, timing: autoResumeTiming) {
                scheduled = AutoResume(
                    attempt: attempt,
                    resumeAt: currentDate().addingTimeInterval(autoResumeTiming.delay(beforeAttempt: attempt).timeInterval),
                    reason: reason,
                    selection: run.selection,
                    automatic: run.automatic
                )
                scheduled.map(scheduleAutoResume)
            } else {
                phase = .failed(AutoResumePolicy.gaveUpMessage)
                record(.error, AutoResumePolicy.gaveUpMessage)
                postNotification(AutoResumePolicy.gaveUpMessage)
            }
        }
        finishSession(result, error: error, scheduled: scheduled)
        if notifies {
            notifyBackupFinished(result)
        }
        isAutomaticRun = false
        refreshProgress()
    }

    // MARK: - Export sessions

    /// Starts the session file for a run attempt. An automatic resume continues the chain of the attempt it
    /// resumes; Resume within a day, with the same source, account, layout and kind of selection, continues
    /// the chain of the export that didn't finish. Anything else starts a new chain.
    private func beginSession(
        destination url: URL,
        selection: LibrarySelection,
        override: LibrarySelection?,
        automatic: Bool,
        resumeAttempt: Int?,
        isResuming: Bool,
        resumesInterrupted: Bool,
        appleID: String?
    ) {
        heartbeatTask?.cancel()
        let now = currentDate()
        let account = source == .iCloud ? appleID.map { ExportSession.accountHash(appleID: $0) } : nil
        let summary = Self.selectionSummary(
            selection, libraryTotal: source == .iCloud ? ICloudLibrary.cachedLibraryCount : nil
        )
        var trigger: ExportSession.Trigger = automatic ? .automaticBackup : (override?.isEverything == true ? .exportAll : .manual)
        var previous: ExportSession?
        let newest = sessions.last { $0.kind == .export && !$0.isReadOnly }
        if resumeAttempt != nil {
            trigger = .autoResume
            previous = newest
        } else if isResuming, let newest, newest.isFinished,
                  newest.source == source, newest.account == account, newest.layout == layout,
                  // Resume Export continues the interrupted run however old it is; other resumes only within a day.
                  resumesInterrupted || (now.timeIntervalSince(newest.endedAt ?? newest.updatedAt) <= 24 * 3600
                      && newest.selection.kind == summary.kind) {
            trigger = .resume
            previous = newest
        }

        var session = ExportSession(
            chainID: previous?.chainID,
            attempt: (previous?.attempt ?? 0) + 1,
            trigger: trigger,
            startedAt: now,
            appVersion: Self.appVersion,
            launchID: Self.launchID,
            source: source,
            account: account,
            layout: layout,
            writesSidecars: writesSidecars,
            selection: summary
        )
        session.libraryCount = source == .iCloud ? ICloudLibrary.cachedLibraryCount : nil
        let recorder = SessionRecorder(session: session, store: SessionStore(destination: url), now: { Date() })
        recorder.onWriteFailure = { [weak self] message in
            self?.record(.warning, message)
        }
        recorder.onSave = { [weak self] saved in
            self?.upsertSession(saved, destination: url)
        }
        self.recorder = recorder
        recorder.start()

        let interval = sessionHeartbeatInterval
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled, let self, let recorder = self.recorder else { return }
                recorder.heartbeat()
            }
        }
    }

    /// Ends the running attempt's session with the run's outcome.
    private func finishSession(_ result: Phase, error: Error?, scheduled: AutoResume?) {
        heartbeatTask?.cancel()
        heartbeatTask = nil
        if let exportingURL {
            Self.exportingDestinations.remove(exportingURL)
            self.exportingURL = nil
        }
        guard let recorder else { return }
        self.recorder = nil
        var reason: String?
        var retryable: Bool?
        let status: ExportSession.Status
        switch result {
        case .completed:
            status = failedCount > 0 ? .completedWithFailures : .completed
        case let .failed(message):
            status = .failed
            reason = error.flatMap { AutoResumePolicy.reason(for: $0) } ?? message
            retryable = error.map { AutoResumePolicy.isRetryable($0) } ?? false
        default:
            status = .cancelled
        }
        recorder.finish(
            status: status,
            reason: reason,
            retryable: retryable,
            autoResume: scheduled.map { ExportSession.AutoResumeNote(attempt: $0.attempt, resumeAt: $0.resumeAt) }
        )
        lastSession = recorder.session
        lastSessionRecorder = recorder
    }

    private func upsertSession(_ session: ExportSession, destination url: URL) {
        guard destination?.url == url else { return }
        if let index = sessions.lastIndex(where: { $0.id == session.id }) {
            sessions[index] = session
        } else {
            sessions.append(session)
        }
    }

    /// Reads the destination's sessions, after ending as interrupted any that an earlier launch left running.
    /// Runs when a folder is chosen, restored at launch, or its drive is connected.
    private func loadSessions() {
        guard let url = destination?.url, destinationIssue == nil else {
            sessions = []
            return
        }
        let launch = Self.launchID
        Task {
            let loaded = await Task.detached(priority: .utility) { () -> [ExportSession] in
                let store = SessionStore(destination: url)
                _ = try? store.markInterrupted(currentLaunch: launch)
                return store.list()
            }.value
            guard destination?.url == url else { return }
            // Sessions this launch wrote meanwhile are newer in memory than on disk (the writer may still
            // have them queued), and the running attempt's state is newer than its last checkpoint.
            var merged = loaded
            var ours = sessions.filter { $0.launchID == Self.launchID }
            if let current = recorder?.session {
                ours.removeAll { $0.id == current.id }
                ours.append(current)
            }
            for session in ours {
                if let index = merged.firstIndex(where: { $0.id == session.id }) {
                    merged[index] = session
                } else {
                    merged.append(session)
                }
            }
            sessions = merged.sorted { $0.startedAt < $1.startedAt }
        }
    }

    /// Export History: this destination's sessions grouped into chains, newest first. The newest chain reads
    /// "Resuming at HH:MM" while its automatic resume is pending.
    var exportHistory: [ExportHistoryChain] {
        ExportHistory.chains(from: sessions, pendingResume: autoResume)
    }

    /// Shown instead of the history while the destination's drive isn't connected.
    var exportHistoryUnavailableText: String? {
        guard let destination, destinationIssue != nil else { return nil }
        return "Connect “\(destination.displayName)” to see its export history."
    }

    /// Reveals `.photo-export/sessions` in Finder, with the newest session file selected.
    func showSessionsInFinder() {
        guard let url = destination?.url else { return }
        let store = SessionStore(destination: url)
        if let newest = store.newestFileURL() {
            NSWorkspace.shared.activateFileViewerSelecting([newest])
        } else if FileManager.default.fileExists(atPath: store.directory.path(percentEncoded: false)) {
            NSWorkspace.shared.activateFileViewerSelecting([store.directory])
        }
    }

    /// Whether the unfinished run was Export All, judged by its session: the newest export session, when it hasn't
    /// completed. Sessions record only the selection's kind and count, not its IDs, so Export All (`everything`) is
    /// the one selection that can be resumed exactly. Any other run resumes with the saved selection.
    nonisolated static func interruptedRunWasExportAll(sessions: [ExportSession]) -> Bool {
        guard let newest = sessions.last(where: { $0.kind == .export && !$0.isReadOnly }) else { return false }
        let completed: Set<ExportSession.Status> = [.completed, .completedWithFailures]
        return !completed.contains(newest.result.status) && newest.selection.kind == .everything
    }

    private static func selectionSummary(_ selection: LibrarySelection, libraryTotal: Int?) -> ExportSession.SelectionSummary {
        switch selection {
        case .only(let ids):
            return ExportSession.SelectionSummary(kind: .only, count: ids.count)
        case .allExcept(let excluded):
            let count = libraryTotal.map { max(0, $0 - excluded.count) } ?? 0
            return ExportSession.SelectionSummary(kind: excluded.isEmpty ? .everything : .allExcept, count: count)
        }
    }

    /// "0.1.4 (14)".
    static var appVersion: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }

    // MARK: - Checking the drive

    /// Whether a drive check can start: a reachable destination, a ready source, and no export, no export
    /// still stopping, and no backup tool running.
    var canCheckDrive: Bool {
        guard let url = destination?.url else { return false }
        return !isExporting && !isEngineRunning && !isExportBlocked() && destinationIssue == nil
            && isSourceReady && driveCheckTask == nil && !Self.exportingDestinations.contains(url.standardizedFileURL)
    }

    /// Destinations an export of this app is writing to. A check never runs on one, even from another model
    /// (tests and previews make several), since it may rewrite the manifest the export appends to.
    private static var exportingDestinations: Set<URL> = []

    var isCheckingDrive: Bool {
        if case .checking = driveCheckState { true } else { false }
    }

    /// "41,000 of about 93,000 files" while checking; nil otherwise.
    var driveCheckProgressText: String? {
        guard case let .checking(listed, expected, _) = driveCheckState else { return nil }
        if let expected, expected > 0 {
            return "\(listed.formatted()) of about \(max(expected, listed).formatted()) files"
        }
        return "\(listed.formatted()) files"
    }

    /// Already on this drive, for the current selection: from the last drive check, or (idle) the manifest.
    var onDriveCount: Int? {
        guard destination != nil, isSourceReady else { return nil }
        return processedCount
    }

    /// Still to export, for the current selection.
    var toGoCount: Int? {
        guard onDriveCount != nil, totalCount > 0 else { return nil }
        return max(0, totalCount - processedCount)
    }

    /// True when the on-drive count includes items counted from file paths ("about 9,200").
    private(set) var isOnDriveCountApproximate = false

    /// "9,207 already on this drive · 83,808 to go", with "about" when counted from file paths.
    var onDriveSummaryText: String? {
        guard let onDrive = onDriveCount, let toGo = toGoCount else { return nil }
        let about = isOnDriveCountApproximate ? "about " : ""
        return "\(about)\(onDrive.formatted()) already on this drive · \(about)\(toGo.formatted()) to go"
    }

    /// Checks the drive now: `full` stats every file (Backup Tools > Check Drive); otherwise only folders
    /// that changed since the last check. Does nothing while an export or another check runs.
    func checkDrive(full: Bool = true) {
        guard let task = startDriveCheck(full: full, changesDrive: true) else { return }
        Task {
            // Only a finished check gets a results sheet; a cancelled one leaves nothing to show.
            if let report = await task.value {
                lastManualDriveCheck = report
            }
        }
    }

    /// Clears `lastManualDriveCheck` once its results sheet is dismissed.
    func dismissManualDriveCheck() {
        lastManualDriveCheck = nil
    }

    @discardableResult
    private func startDriveCheck(full: Bool, changesDrive: Bool) -> Task<DriveCheckReport?, Never>? {
        guard canCheckDrive else { return nil }
        let mode: DriveInventory.Mode = full || layout == .flat ? .full : .quick
        let task = Task<DriveCheckReport?, Never> { [weak self] in
            guard let self else { return nil }
            return await performDriveCheck(mode: mode, setAsideFolder: Self.checkFolderName(), changesDrive: changesDrive)
        }
        driveCheckTask = task
        Task {
            _ = await task.value
            if driveCheckTask == task {
                driveCheckTask = nil
            }
        }
        return task
    }

    /// Stops a check that's in progress. Nothing on the drive has changed while it is still listing.
    func cancelDriveCheck() {
        driveCheckTask?.cancel()
    }

    /// The quick check when a folder is chosen, restored or reconnected, so its figures are current.
    private func checkDriveWhenIdle() {
        guard canCheckDrive else { return }
        // Only reports: the drive isn't changed until the person exports or chooses Check Drive.
        startDriveCheck(full: false, changesDrive: false)
    }

    /// Cancels an idle check and waits until it has stopped, so nothing else touches the manifest meanwhile.
    private func stopDriveCheck() async {
        guard let task = driveCheckTask else { return }
        task.cancel()
        _ = await task.value
        if driveCheckTask == task {
            driveCheckTask = nil
        }
    }

    /// Runs the check against the current destination, source, layout and selection, and updates
    /// `driveCheckState` and the on-drive figures. Nil when cancelled or when the check failed.
    private func performDriveCheck(
        mode: DriveInventory.Mode,
        setAsideFolder: String,
        changesDrive: Bool = true
    ) async -> DriveCheckReport? {
        guard let url = destination?.url else { return nil }
        let token = UUID()
        driveCheckToken = token
        let source = source
        let selection = selection(forCheckDuring: phase)
        let hadSnapshot = await Task.detached(priority: .utility) { ExportManifest.filesSnapshot(in: url) != nil }.value
        driveCheckState = .checking(filesListed: 0, expectedFiles: nil, mode: mode)
        if !hadSnapshot, phase == .preparing {
            record(.info, "First check of this drive takes a little longer.")
        }

        let input: DriveCheck.Input
        switch source {
        case .iCloud:
            input = DriveCheck.Input(
                destination: url, source: source, layout: layout, selection: selection,
                selectedCount: selection.selectedCount(total: ICloudLibrary.cachedLibraryCount ?? 0),
                libraryIDs: nil, setAsideFolder: setAsideFolder, changesDrive: changesDrive
            )
        case .photosLibrary:
            let ids = await Task.detached(priority: .utility) { () -> Set<String> in
                var ids: Set<String> = []
                PhotoLibrary.allAssets().enumerateObjects { asset, _, _ in ids.insert(asset.localIdentifier) }
                return ids
            }.value
            input = DriveCheck.Input(
                destination: url, source: source, layout: layout, selection: selection,
                selectedCount: ids.count { selection.contains($0) },
                libraryIDs: ids, setAsideFolder: setAsideFolder, changesDrive: changesDrive
            )
        }

        do {
            let report = try await DriveCheck.run(input, mode: mode) { [weak self] progress in
                Task { @MainActor [weak self] in
                    guard let self, driveCheckToken == token, case .checking = driveCheckState else { return }
                    driveCheckState = .checking(filesListed: progress.filesListed, expectedFiles: progress.expectedFiles, mode: mode)
                }
            }
            guard driveCheckToken == token else { return report }
            driveCheckState = .checked(report)
            lastDriveCheck = report
            lastDriveCheckedAt = currentDate()
            if destination?.url == url, self.source == source {
                if report.selectedCount > 0 {
                    totalCount = report.selectedCount
                }
                processedCount = report.onDrive
                isOnDriveCountApproximate = report.isApproximate
            }
            if report.foundProblems, report.missingFiles.count + report.damagedFiles.count > report.setAsideFailures.count {
                // A damaged file that couldn't be moved aside isn't downloaded again; it's reported below.
                let count = report.missingFiles.count + report.damagedFiles.count - report.setAsideFailures.count
                let files = count == 1 ? "file is" : "files are"
                record(.warning, changesDrive
                    ? "\(count.formatted()) \(files) missing or damaged and will be \(source.copiedVerb) again."
                    : "\(count.formatted()) \(files) missing or damaged. They’ll be fixed when you export or choose Check Drive.")
            }
            if !report.setAsideFiles.isEmpty {
                record(.info, "Moved \(report.setAsideFiles.count.formatted()) damaged \(report.setAsideFiles.count == 1 ? "file" : "files") to .photo-export/set-aside on the drive.")
            }
            if let first = report.setAsideFailures.first {
                let count = report.setAsideFailures.count
                record(.error, "Couldn’t move \(count.formatted()) damaged \(count == 1 ? "file" : "files") aside, such as “\(first.path)”: \(first.reason) "
                    + "\(count == 1 ? "It stays" : "They stay") where \(count == 1 ? "it is" : "they are") and will be checked again next time.")
            }
            if !report.changedFiles.isEmpty {
                let count = report.changedFiles.count
                record(.info, "\(count.formatted()) \(count == 1 ? "file" : "files") that Uncloud can’t tell it saved changed size since the last check, such as “\(report.changedFiles[0])”. \(count == 1 ? "It was" : "They were") left as \(count == 1 ? "it is" : "they are").")
            }
            return report
        } catch {
            guard driveCheckToken == token else { return nil }
            if error is CancellationError || Task.isCancelled {
                driveCheckState = lastDriveCheck.map { .checked($0) } ?? .notChecked
            } else {
                driveCheckState = .failed("Couldn’t check “\(destination?.displayName ?? "the drive")”: \(error.localizedDescription)")
            }
            return nil
        }
    }

    /// The selection a check counts: the running export's (such as Export All Photos), else the saved one.
    private func selection(forCheckDuring phase: Phase) -> LibrarySelection {
        if phase == .preparing, let override = currentRun?.selection {
            return override
        }
        return selection
    }

    /// The set-aside folder name for a check outside an export: "check-2026-10-12T14-03-27Z".
    private static func checkFolderName() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        return "check-" + formatter.string(from: Date()).replacingOccurrences(of: ":", with: "-")
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
        refreshNewPhotos()
        refreshFlatFolderCheck()
        guard isSourceReady, let url = destination?.url else {
            totalCount = 0
            processedCount = 0
            hasIncompleteRun = false
            interruptedRunWasExportAll = false
            previousLayout = nil
            // Signed out of iCloud: the layout question still needs the folder's items by layout.
            if source == .iCloud, let url = destination?.url {
                Task { await loadICloudItemsByLayout(for: url) }
            }
            return
        }
        let source = source
        let selection = selection
        let layout = layout
        Task {
            let (progress, byLayout) = await Task.detached { () -> ((progress: LibraryProgress, isApproximate: Bool), [FolderLayout: Int]?) in
                guard source == .iCloud else {
                    return ((PhotoLibrary.progress(toward: url, selection: selection), false), [:])
                }
                let records = ExportManifest.records(in: url)
                // Read from the folder itself: an unplugged drive has no records to read, which isn't "no items".
                let isReadable = FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
                return (Self.iCloudProgress(toward: url, selection: selection, layout: layout, records: records),
                        isReadable ? ICloudItemCount.itemsByLayout(records: records) : nil)
            }.value
            if source == .iCloud, let byLayout, destination?.url == url, destinationIssue == nil, self.source == source {
                if iCloudItemsByLayout != byLayout {
                    iCloudItemsByLayout = byLayout
                }
                if iCloudItemsByLayoutFolder != url {
                    iCloudItemsByLayoutFolder = url
                }
            }
            // Only read while a run is unfinished: its session says which selection it used.
            let wasExportAll = progress.progress.hasIncompleteRun
                ? await Task.detached(priority: .utility) { Self.interruptedRunWasExportAll(sessions: SessionStore(destination: url).list()) }.value
                : false
            guard !isExporting, destination?.url == url, self.source == source, self.selection == selection,
                  self.layout == layout else { return }
            totalCount = progress.progress.total
            processedCount = progress.progress.exported
            isOnDriveCountApproximate = progress.isApproximate
            hasIncompleteRun = progress.progress.hasIncompleteRun
            interruptedRunWasExportAll = wasExportAll
            previousLayout = progress.progress.previousLayout
        }
    }

    /// The selected part of the iCloud library's last known size, and how many selected items the destination's
    /// manifest records. Items, not files: items recorded by asset ID count exactly, and path-only records are
    /// grouped (a Live Photo's movie and XMP sidecars don't count), which makes the figure approximate.
    /// With `layout`, only items saved in that layout count (other layouts' items are downloaded again).
    nonisolated static func iCloudProgress(
        toward destination: URL,
        selection: LibrarySelection,
        layout: FolderLayout? = nil,
        records: [String: [String]]? = nil
    ) -> (progress: LibraryProgress, isApproximate: Bool) {
        let total = selection.selectedCount(total: ICloudLibrary.cachedLibraryCount ?? 0)
        let items = ICloudItemCount.count(records: records ?? ExportManifest.records(in: destination), selection: selection,
                                          layout: layout == .album ? nil : layout)
        let progress = LibraryProgress(
            total: total,
            exported: total > 0 ? min(total, items.total) : items.total,
            hasIncompleteRun: ExportManifest.hasIncompleteRun(in: destination),
            previousLayout: ExportManifest.layout(in: destination)
        )
        return (progress, items.isApproximate)
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
        #if DEBUG
        if let storageWarningOverride { return storageWarningOverride }
        #endif
        guard let destination, destinationIssue == nil, let storageEstimate else { return nil }
        return StorageCheck.warning(
            needed: storageNeededBytes,
            isExact: storageEstimate.isExact && processedCount == 0,
            free: destinationFreeBytes,
            destinationName: destination.displayName
        )
    }

    #if DEBUG
    /// Test-only: a warning in place of the estimate's.
    @ObservationIgnored var storageWarningOverride: String?
    #endif

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
            let newLayout = layoutAfterChoosingFolder
            layoutAfterChoosingFolder = nil
            // The folder can't change under a running export.
            guard !isExporting else {
                record(.warning, "The folder can’t change while an export is running.")
                return
            }
            // "Choose New Folder…" answered with the same folder: ask again rather than download everything
            // again here without saying so.
            if let newLayout, let current = destination?.url,
               current.standardizedFileURL.resolvingSymlinksInPath() == url.standardizedFileURL.resolvingSymlinksInPath() {
                requestLayoutChange(to: newLayout)
                return
            }
            // A different folder: the export that was waiting to resume belongs to the old one.
            cancelAutoResume()
            setDestination(url, persist: true)
            if let newLayout {
                switchLayoutAfterChoosing(newLayout, folder: url)
            }
            if startsExport {
                startRun(selection: exportSelection)
            }
        case let .failure(error):
            layoutAfterChoosingFolder = nil
            record(.error, error.localizedDescription)
        }
    }

    /// The layout chosen before "Choose New Folder…", applied once the new folder has been read: through
    /// `requestLayoutChange(to:)`, so a folder that already has exports in another layout asks first too.
    private func switchLayoutAfterChoosing(_ newLayout: FolderLayout, folder url: URL) {
        guard destination?.url == url, destinationIssue == nil else { return }
        Task {
            await loadICloudItemsByLayout(for: url)
            guard destination?.url == url, destinationIssue == nil, !isExporting else { return }
            requestLayoutChange(to: newLayout)
        }
    }

    func revealDestination() {
        guard let url = destination?.url else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// Reveals `.photo-export/set-aside/<folder>` on the drive in Finder, or the drive when that folder is gone.
    /// The destination's security scope is active while it is chosen, as for `revealDestination`.
    func showSetAsideFolder(_ folder: String) {
        guard let url = destination?.url else { return }
        let setAside = url
            .appending(path: ".photo-export/set-aside/\(folder)", directoryHint: .isDirectory)
        let exists = FileManager.default.fileExists(atPath: setAside.path(percentEncoded: false))
        NSWorkspace.shared.activateFileViewerSelecting([exists ? setAside : url])
    }

    private func setDestination(_ url: URL, persist: Bool) {
        if isAccessingDestination {
            destination?.url.stopAccessingSecurityScopedResource()
        }
        isAccessingDestination = url.startAccessingSecurityScopedResource()

        let destination = Destination(url: url)
        // A folder chosen or restored, or a drive connected again: read its history and check it. Re-resolving the
        // same reachable folder (before each automatic resume, for instance) does neither again.
        let isNewOrReconnected = persist || self.destination?.url != url || destinationIssue != nil
        if self.destination?.url != url {
            // Another folder: its history and its items' layouts are read afresh.
            sessions = []
            iCloudItemsByLayout = [:]
            iCloudItemsByLayoutFolder = nil
            flatFolderOtherFiles = nil
        }
        self.destination = destination
        destinationIssue = destination.isWritable() ? nil : Self.notWritableMessage(for: destination)
        destinationFreeBytes = nil
        refreshDestinationFreeSpace(force: true)

        if persist, let bookmark = try? url.bookmarkData(options: .withSecurityScope) {
            UserDefaults.standard.set(bookmark, forKey: Self.bookmarkKey)
        }
        if lastDriveCheck != nil || driveCheckState != .notChecked, driveCheckTask == nil {
            lastDriveCheck = nil
            lastManualDriveCheck = nil
            lastDriveCheckedAt = nil
            driveCheckState = .notChecked
        }
        refreshProgress()
        if isNewOrReconnected {
            loadSessions()
            checkDriveWhenIdle()
        }
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
        sessions = []
        iCloudItemsByLayout = [:]
        iCloudItemsByLayoutFolder = nil
        flatFolderOtherFiles = nil
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
        // A run waiting to resume goes first, the way it was started, rather than being replaced.
        if autoResume != nil {
            resumeNow()
            return
        }
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
            body = "Backup finished, but \(failedCount.formatted()) items couldn’t be \(source.copiedVerb)."
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

    // MARK: - Automatic resume

    /// Starts the waiting export now instead of at its time.
    func resumeNow() {
        guard autoResume != nil else { return }
        attemptAutoResume()
    }

    /// Forgets the pending automatic resume, if there is one. The export stays failed; Resume continues it.
    func cancelAutoResume() {
        autoResumeTask?.cancel()
        autoResumeTask = nil
        let center = NSWorkspace.shared.notificationCenter
        autoResumeObservers.forEach(center.removeObserver)
        autoResumeObservers = []
        if autoResume != nil {
            autoResume = nil
        }
    }

    /// The pending resume's time as the user's locale shows it, such as "22:40".
    nonisolated static func resumeTimeText(_ resumeAt: Date) -> String {
        resumeAt.formatted(date: .omitted, time: .shortened)
    }

    private func scheduleAutoResume(_ pending: AutoResume) {
        cancelAutoResume()
        autoResume = pending
        record(.warning, "Paused because \(Self.lowercasingFirst(pending.reason)). Resuming at \(Self.resumeTimeText(pending.resumeAt)) (attempt \(pending.attempt)).")
        observeWakeAndMount()
        startAutoResumeTimer()
    }

    /// Wakes up when the pending resume is due, by the wall clock: it sleeps at most `recheckInterval` at a
    /// time and looks at the date again, so time the Mac spent asleep counts. A resume that's due but has to
    /// wait (for the drive, or for the last run to stop) is tried again every `recheckInterval`.
    private func startAutoResumeTimer() {
        autoResumeTask?.cancel()
        autoResumeTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, let pending = autoResume else { return }
                let recheck = autoResumeTiming.recheckInterval
                let remaining = pending.resumeAt.timeIntervalSince(currentDate())
                if remaining <= 0 {
                    attemptAutoResume()
                    guard !Task.isCancelled, autoResume != nil else { return }
                    try? await Task.sleep(for: recheck)
                } else {
                    try? await Task.sleep(for: min(.milliseconds(Int64((remaining * 1000).rounded(.up))), recheck))
                }
            }
        }
    }

    /// A Mac that slept past the resume time resumes as soon as it wakes; a drive that's connected resumes
    /// an export that was waiting for it.
    private func observeWakeAndMount() {
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.didMountNotification] {
            let observer = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.resumeIfDue()
                }
            }
            autoResumeObservers.append(observer)
        }
    }

    /// Starts the pending resume if its time has come.
    private func resumeIfDue() {
        guard let pending = autoResume, pending.resumeAt <= currentDate() else { return }
        attemptAutoResume()
    }

    /// Starts the pending resume the way its run was started, if everything is ready. Keeps waiting while
    /// the last run is still stopping or the drive isn't connected; gives up when the source needs the user.
    private func attemptAutoResume() {
        guard var pending = autoResume else { return }
        if isExporting {
            // Another export runs; it replaced this one.
            cancelAutoResume()
            return
        }
        guard !isEngineRunning, !isExportBlocked() else { return }
        switch source {
        case .iCloud:
            guard ICloudAccount.appleID != nil else {
                cancelAutoResume()
                return
            }
            if browser?.state == .signInRequired {
                cancelAutoResume()
                record(.warning, "Didn’t resume: sign in to iCloud again to continue.")
                isShowingICloudSignIn = true
                return
            }
        case .photosLibrary:
            guard hasPhotosAccess else {
                cancelAutoResume()
                return
            }
        }
        reconnectDestination()
        guard destination != nil, destinationIssue == nil else {
            if !pending.isWaitingForDestination {
                pending.isWaitingForDestination = true
                autoResume = pending
                if let destinationIssue {
                    record(.info, "Waiting to resume: \(destinationIssue)")
                }
            }
            if autoResumeTask == nil {
                startAutoResumeTimer()
            }
            return
        }

        // From here the run is started; nothing else may start it a second time.
        cancelAutoResume()
        record(.info, "Resuming automatically (attempt \(pending.attempt)).")
        Task {
            let started = await startExport(selection: pending.selection, automatic: pending.automatic, resumeAttempt: pending.attempt)
            guard !started, !isExporting, autoResume == nil, phase != .completed else { return }
            // Couldn't start after all, such as a folder that can't be written to: wait and try again.
            pending.isWaitingForDestination = destinationIssue != nil
            autoResume = pending
            observeWakeAndMount()
            startAutoResumeTimer()
        }
    }

    private static func lowercasingFirst(_ text: String) -> String {
        guard let first = text.first else { return text }
        // "Apple", "iCloud" and "Uncloud" keep their capital.
        if text.hasPrefix("Apple") || text.hasPrefix("iCloud") { return text }
        return first.lowercased() + text.dropFirst()
    }

    // MARK: - Folder layout changes (plan 7e, D3, D5)

    /// The question before a layout change that downloads an iCloud library again, for a confirmation dialog.
    struct LayoutChangeConfirmation: Identifiable, Equatable {
        enum Choice {
            /// Recommended: keep this folder as it is and pick another one for the new layout.
            case chooseNewFolder
            /// Switch here: everything downloads again next to the existing copies.
            case downloadAgainHere
            case cancel
        }

        let id = UUID()
        /// The layout most of the existing items were saved in.
        let from: FolderLayout
        let to: FolderLayout
        /// Items saved in other layouts than `to`.
        let itemsSaved: Int
        let title: String
        let message: String
        static let chooseNewFolderTitle = "Choose New Folder…"
        static let downloadAgainTitle = "Download Again Here"
        static let cancelTitle = "Cancel"
    }

    /// Set while a layout change waits for `resolveLayoutChange(_:)`. Views show it as a confirmation dialog.
    var pendingLayoutChange: LayoutChangeConfirmation?
    /// iCloud items in the destination by the layout they were saved in, from its manifest (refreshed with progress).
    private(set) var iCloudItemsByLayout: [FolderLayout: Int] = [:]
    /// The folder `iCloudItemsByLayout` was read from. Nil until the current folder's manifest has been read:
    /// right after launch or a folder choice, and while the drive is unplugged.
    private(set) var iCloudItemsByLayoutFolder: URL?
    /// The flat layout's folder and how many entries in it no record lists (a quick, read-only listing).
    private(set) var flatFolderOtherFiles: (folder: URL, count: Int)?
    /// The layout to switch to once a new folder is chosen ("Choose New Folder…").
    @ObservationIgnored private var layoutAfterChoosingFolder: FolderLayout?
    /// The resume logic's limits, for the iCloud engine. Tests shrink them.
    @ObservationIgnored var iCloudResumeSettings = ICloudResumeSettings()

    /// Changes the layout, or asks first (`pendingLayoutChange`) when the destination already has iCloud items in
    /// other layouts: icloudpd only looks at the new layout's paths, so the whole library downloads again.
    func requestLayoutChange(to newLayout: FolderLayout) {
        guard newLayout != layout, !isExporting, newLayout.isAvailable(for: source) else { return }
        if let confirmation = layoutChangeConfirmation(to: newLayout) {
            pendingLayoutChange = confirmation
        } else {
            layout = newLayout
        }
    }

    /// Answers `pendingLayoutChange`.
    func resolveLayoutChange(_ choice: LayoutChangeConfirmation.Choice) {
        guard let pending = pendingLayoutChange else { return }
        pendingLayoutChange = nil
        switch choice {
        case .chooseNewFolder:
            beginChoosingDestination()
            layoutAfterChoosingFolder = pending.to
        case .downloadAgainHere:
            guard !isExporting else { return }
            layout = pending.to
            record(.info, "Folder layout changed to \(pending.to.title.lowercased()). The next export downloads everything again into this folder.")
        case .cancel:
            break
        }
    }

    /// Whether `iCloudItemsByLayout` describes the current, reachable folder.
    var knowsICloudItemsByLayout: Bool {
        guard let url = destination?.url, destinationIssue == nil else { return false }
        return iCloudItemsByLayoutFolder == url
    }

    /// Reads the folder's iCloud items by layout off the main actor. False when the folder can't be read
    /// (unplugged) or is no longer the destination by then.
    @discardableResult
    private func loadICloudItemsByLayout(for url: URL) async -> Bool {
        let byLayout = await Task.detached(priority: .userInitiated) { () -> [FolderLayout: Int]? in
            guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else { return nil }
            return ICloudItemCount.itemsByLayout(records: ExportManifest.records(in: url))
        }.value
        guard let byLayout, destination?.url == url, destinationIssue == nil else { return false }
        if iCloudItemsByLayout != byLayout {
            iCloudItemsByLayout = byLayout
        }
        if iCloudItemsByLayoutFolder != url {
            iCloudItemsByLayoutFolder = url
        }
        return true
    }

    /// The question a change to `newLayout` needs, or nil when it needs none: not iCloud, no folder, or no more
    /// items saved in other layouts than in the new one. While the folder's items aren't known yet (just
    /// launched or chosen, or the drive is unplugged) it asks anyway: the folder may have items.
    func layoutChangeConfirmation(to newLayout: FolderLayout) -> LayoutChangeConfirmation? {
        guard source == .iCloud, let destination, newLayout != layout else { return nil }
        let size = storageEstimate.map { " (\($0.formatted))" } ?? ""
        let what = newLayout == .album ? "every album" : "your whole library"
        guard knowsICloudItemsByLayout else {
            let why = destinationIssue != nil
                ? "Uncloud can’t read “\(destination.displayName)” right now, so it can’t tell whether it already has items saved another way."
                : "Uncloud is still reading “\(destination.displayName)”, so it can’t tell yet whether it already has items saved another way."
            return LayoutChangeConfirmation(
                from: layout,
                to: newLayout,
                itemsSaved: 0,
                title: "Download Everything Again?",
                message: why + " If it does, switching to \(newLayout.title) downloads \(what) again\(size) into this folder, next to the copies already there. "
                    + "To keep one copy, choose a new folder for the new layout."
            )
        }
        let elsewhere = iCloudItemsByLayout.filter { $0.key != newLayout }
        let saved = elsewhere.values.reduce(0, +)
        guard saved > 0, saved > iCloudItemsByLayout[newLayout, default: 0],
              let from = elsewhere.max(by: { $0.value < $1.value })?.key else { return nil }
        return LayoutChangeConfirmation(
            from: from,
            to: newLayout,
            itemsSaved: saved,
            title: "Download Everything Again?",
            message: "“\(destination.displayName)” already has \(saved.formatted()) \(saved == 1 ? "item" : "items") saved \(Self.savedPhrase(from)). "
                + "Switching to \(newLayout.title) downloads \(what) again\(size) into this folder, next to the copies already there. "
                + "To keep one copy, choose a new folder for the new layout."
        )
    }

    /// Under the layout picker when the folder already has items saved another way; nil otherwise.
    var layoutSwitchNotice: String? {
        guard destination != nil else { return nil }
        switch source {
        case .photosLibrary:
            guard let previous = previousLayout, previous != layout, processedCount > 0 else { return nil }
            return "This folder already has items exported \(previous.title.lowercased()). They’ll stay where they are, and new items will use the layout you choose here."
        case .iCloud:
            let elsewhere = iCloudItemsByLayout.filter { $0.key != layout }
            let saved = elsewhere.values.reduce(0, +)
            guard saved > iCloudItemsByLayout[layout, default: 0],
                  let from = elsewhere.max(by: { $0.value < $1.value })?.key else { return nil }
            return "This folder already has \(saved.formatted()) \(saved == 1 ? "item" : "items") saved \(Self.savedPhrase(from)). "
                + "Exporting \(layout.title.lowercased()) downloads everything again into this folder. To keep one copy, choose a new folder."
        }
    }

    /// All in One Folder only: the chosen folder already holds files Uncloud didn't save. From a quick listing
    /// as soon as the layout and folder are chosen (before any export or drive check), or the last drive check.
    var flatFolderWarning: String? {
        guard layout == .flat, let destination, destinationIssue == nil else { return nil }
        let listed = flatFolderOtherFiles.flatMap { $0.folder == destination.url ? $0.count : nil } ?? 0
        guard listed > 0 || (lastDriveCheck?.otherFiles ?? 0) > 0 else { return nil }
        var text = "This folder already has other files. Uncloud will leave them alone, but a dedicated folder is easier to keep tidy."
        if source == .iCloud {
            text += " A file of yours with the same name and size as a photo counts as already \(source.copiedVerb)."
        }
        return text
    }

    /// Lists the flat layout's folder (top level only, read-only) for `flatFolderWarning`.
    private func refreshFlatFolderCheck() {
        guard layout == .flat, let url = destination?.url, destinationIssue == nil else { return }
        Task {
            let count = await Task.detached(priority: .utility) { Self.unrecordedEntryCount(in: url) }.value
            guard let count, destination?.url == url else { return }
            if flatFolderOtherFiles?.folder != url || flatFolderOtherFiles?.count != count {
                flatFolderOtherFiles = (url, count)
            }
        }
    }

    /// Entries at the top of `url` (files and folders, hidden ones aside) that no manifest record lists. Nil
    /// when the folder can't be listed.
    nonisolated static func unrecordedEntryCount(in url: URL) -> Int? {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: url.path(percentEncoded: false)) else { return nil }
        let recorded = Set(ExportManifest.records(in: url).values.flatMap { $0 })
        return names.count { !$0.hasPrefix(".") && !recorded.contains($0) }
    }

    private static func savedPhrase(_ layout: FolderLayout) -> String {
        switch layout {
        case .flat: "all in one folder"
        default: layout.title.lowercased()
        }
    }

    /// A pending automatic resume would continue in the old layout, so it's cancelled; the figures and the drive
    /// check follow the new layout.
    private func layoutDidChange() {
        if autoResume != nil {
            cancelAutoResume()
            record(.info, "Automatic resume cancelled because the folder layout changed.")
        }
        guard !isExporting else { return }
        refreshProgress()
        Task {
            guard !isExporting else { return }
            await stopDriveCheck()
            guard !isExporting else { return }
            checkDriveWhenIdle()
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
