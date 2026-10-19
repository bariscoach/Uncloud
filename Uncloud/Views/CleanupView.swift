import SwiftUI

/// The Clean Up iCloud pane: pick photos in the iCloud library and delete them from iCloud Photos, or pick photos in
/// Recently Deleted and recover them. Deleted photos move to Recently Deleted, where they stay for 30 days. The backup
/// on the drive is never changed.
struct CleanupView: View {
    @Environment(ExportModel.self) private var model

    var body: some View {
        Group {
            if let cleanup = model.iCloudCleanup, let browser = model.browser, let recentlyDeleted = model.recentlyDeletedBrowser,
               model.source == .iCloud {
                CleanupGridView(
                    cleanup: cleanup,
                    library: browser,
                    recentlyDeleted: recentlyDeleted,
                    destination: model.destination?.url,
                    isExportRunning: model.isExporting || model.isEngineRunning
                )
            } else if model.source == .photosLibrary {
                ContentUnavailableView {
                    Label("Clean Up iCloud", systemImage: "icloud")
                } description: {
                    Text("Clean Up iCloud works with iCloud Photos. Switch to iCloud Photos to choose photos to delete.")
                } actions: {
                    Button("Switch to iCloud Photos") {
                        model.source = .iCloud
                    }
                    .buttonStyle(.borderedProminent)
                }
            } else {
                ContentUnavailableView {
                    Label("Sign In to iCloud", systemImage: "icloud")
                } description: {
                    Text("Sign in to choose photos to delete from iCloud.")
                } actions: {
                    Button("Sign In…") {
                        model.isShowingICloudSignIn = true
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The iCloud library as a grid for choosing what to delete, with the toolbar, the progress or summary card, and
/// the typed-number confirmation.
struct CleanupGridView: View {
    @Bindable var cleanup: ICloudCleanup
    /// The two lists the picker switches between.
    let library: LibraryBrowser
    let recentlyDeleted: LibraryBrowser
    /// The backup folder, whose manifest says what's backed up. Nil when none is chosen.
    let destination: URL?
    /// True while an export runs or its engine is still stopping.
    let isExportRunning: Bool
    @State private var filter: BackupFilter = .all
    /// The IDs backed up on the current destination, read from its manifest. Information only.
    @State private var backedUp: Set<String> = []
    @State private var knownBytes: [String: Int64] = [:]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(AccountModel.self) private var account

    /// The list the picker shows.
    private var browser: LibraryBrowser {
        cleanup.mode == .library ? library : recentlyDeleted
    }

    /// The window subtitle: the selection count, and in Recently Deleted, how long photos stay there.
    private var subtitle: String {
        let count = countText
        guard cleanup.mode == .recentlyDeleted else { return count }
        let note = "Deleted for good after 30 days"
        return count.isEmpty ? note : "\(count) · \(note)"
    }

    var body: some View {
        Group {
            // Clean Up iCloud is locked as a whole by MainWindow for free accounts, so this view never shows the lock.
            if cleanup.mode == .recentlyDeleted, browser.count == 0 {
                ContentUnavailableView("No Recently Deleted Photos", systemImage: "trash")
            } else if browser.count != nil {
                LibraryGrid(
                    browser: browser,
                    selection: $cleanup.selection,
                    selectAll: filter.selection(backedUp: backedUp),
                    backedUp: destination == nil ? nil : backedUp,
                    filter: filter
                )
            } else if case let .failed(message) = browser.state {
                ContentUnavailableView {
                    Label("Couldn’t Open Your Library", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(message)
                } actions: {
                    Button("Try Again") {
                        browser.reload()
                    }
                    .buttonStyle(.borderedProminent)
                }
            } else {
                ProgressView {
                    Text("Loading your library…")
                }
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if showsStatus {
                CleanupStatusCard(cleanup: cleanup)
                    .transition(.opacity)
            }
        }
        .animation(reduceMotion ? nil : .smooth, value: showsStatus)
        .navigationSubtitle(subtitle)
        .sheet(isPresented: isConfirming) {
            if cleanup.mode == .library {
                CleanupConfirmationSheet(
                    count: cleanup.pendingCount,
                    notBackedUp: notBackedUpCount,
                    onCancel: { cleanup.cancelConfirmation() },
                    onDelete: { typed in
                        // The plan can lapse while this sheet is open. A library delete then closes it instead (L6).
                        guard Self.mayStart(mode: cleanup.mode, allowsCleanUp: account.allows(.cleanUpICloud)) else {
                            cleanup.cancelConfirmation()
                            return
                        }
                        cleanup.start(typed: typed)
                    }
                )
            } else {
                CleanupRecoverySheet(
                    count: cleanup.pendingCount,
                    onCancel: { cleanup.cancelConfirmation() },
                    onRecover: {
                        // A lapse while this sheet is open closes it instead, as for a delete.
                        guard Self.mayStart(mode: cleanup.mode, allowsCleanUp: account.allows(.cleanUpICloud)) else {
                            cleanup.cancelConfirmation()
                            return
                        }
                        cleanup.recover()
                    }
                )
            }
        }
        .toolbar {
            toolbar
        }
        // The Edit menu's Delete from iCloud or Recover item. It opens the same confirmation as the toolbar button,
        // and is enabled exactly when that button is.
        .focusedValue(\.cleanupCommand, CleanupCommandActions(
            title: commandTitle,
            isEnabled: cleanup.canRequestConfirmation,
            perform: { cleanup.requestConfirmation() }
        ))
        .task(id: ObjectIdentifier(browser)) {
            browser.load()
        }
        .task(id: destination) {
            backedUp = await Self.backedUpIDs(at: destination)
        }
        .task(id: cleanup.selection) {
            knownBytes = await browser.knownBytes()
        }
        .task(id: cleanup.mode) {
            knownBytes = await browser.knownBytes()
        }
    }

    /// Library or Recently Deleted, with the count of Recently Deleted. Locked while a run works on one of them.
    /// It sits in the toolbar's centre, where switching views belongs on macOS, rather than in a bar under it.
    private var modePicker: some View {
        Picker("Show", selection: Binding(get: { cleanup.mode }, set: { cleanup.setMode($0) })) {
            Text("Library").tag(ICloudCleanup.Mode.library)
            Text(recentlyDeletedTitle).tag(ICloudCleanup.Mode.recentlyDeleted)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .disabled(cleanup.isRunning)
    }

    private var recentlyDeletedTitle: String {
        recentlyDeleted.count.map { "Recently Deleted (\($0.formatted()))" } ?? "Recently Deleted"
    }

    private var showsStatus: Bool {
        switch cleanup.state {
        case .idle, .confirming: false
        case .finding, .deleting, .waitingAfterThrottle, .finished, .failed: true
        }
    }

    private var isConfirming: Binding<Bool> {
        Binding(
            get: { cleanup.state == .confirming },
            set: { if !$0 { cleanup.cancelConfirmation() } }
        )
    }

    /// Selected photos that aren't backed up on the destination, for the warning in the confirmation.
    private var notBackedUpCount: Int {
        let backedUpSelected = backedUp.filter { cleanup.selection.contains($0) }.count
        return max(0, cleanup.pendingCount - backedUpSelected)
    }

    /// Deleting from the library and recovering from Recently Deleted both need Plus at the moment they start.
    static func mayStart(mode: ICloudCleanup.Mode, allowsCleanUp: Bool) -> Bool {
        allowsCleanUp
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            modePicker
        }

        ToolbarItem(placement: .primaryAction) {
            // One button that switches between the two actions. Each keeps its own enabled condition: Select All
            // needs a loaded list, and Deselect All needs a selection.
            Group {
                if cleanup.selection.isNothing {
                    Button("Select All") {
                        cleanup.selection = filter.selection(backedUp: backedUp)
                    }
                    .disabled(browser.count == nil)
                } else {
                    Button("Deselect All") {
                        cleanup.selection = .only([])
                    }
                }
            }
            .help("Select or deselect every photo")
        }

        ToolbarItem(placement: .primaryAction) {
            Menu {
                Picker("Show", selection: $filter) {
                    ForEach(BackupFilter.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
                .pickerStyle(.inline)
            } label: {
                Label(filter.title, systemImage: "line.3.horizontal.decrease.circle")
            }
            .help("Choose which photos Select All selects, and which are dimmed")
            .accessibilityLabel("Filter, \(filter.title)")
        }

        if #available(macOS 26, *) {
            ToolbarSpacer(.fixed, placement: .primaryAction)
        }

        ToolbarItem(placement: .primaryAction) {
            if cleanup.mode == .library {
                // Not prominent: the red, typed confirmation is where the deletion is committed. The trash glyph and the
                // ellipsis say what the button does.
                Button {
                    cleanup.requestConfirmation()
                } label: {
                    Label(deleteTitle, systemImage: "trash")
                }
                .labelStyle(.titleAndIcon)
                .buttonStyle(.bordered)
                .disabled(!cleanup.canRequestConfirmation)
                .help(deleteHelp)
            } else {
                // Recovering isn't destructive, so this is the prominent button without the red.
                Button(recoverTitle) {
                    cleanup.requestConfirmation()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!cleanup.canRequestConfirmation)
                .help(recoverHelp)
            }
        }
    }

    /// The Edit menu's title for the same action as the toolbar button in this mode.
    private var commandTitle: String {
        cleanup.mode == .library ? "Delete from iCloud…" : "Recover"
    }

    private var total: Int? { browser.count }

    private var countText: String {
        guard let total else { return "" }
        let selected = cleanup.selection.selectedCount(total: total)
        let count = cleanup.selection.isEverything
            ? "All \(Plural.photos(total)) selected"
            : "\(selected.formatted()) of \(total.formatted()) selected"
        guard selected > 0, let size = sizeText(selected: selected) else { return count }
        return "\(count) · \(size)"
    }

    /// The selected photos' sizes, from the ones whose sizes are known. "At least" unless every selected photo is known.
    private func sizeText(selected: Int) -> String? {
        let known = knownBytes.filter { cleanup.selection.contains($0.key) }
        let bytes = known.values.reduce(Int64(0), +)
        guard bytes > 0 else { return nil }
        let size = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        return known.count >= selected ? size : "at least \(size)"
    }

    private var deleteTitle: String {
        cleanup.selectedCount > 0 ? "Delete \(cleanup.selectedCount.formatted()) from iCloud…" : "Delete from iCloud…"
    }

    private var deleteHelp: String {
        if cleanup.isRunning { return "Wait for the current deletion to finish." }
        if isExportRunning { return "Wait for the export to finish." }
        return "Moves the selected photos to Recently Deleted, where they stay for 30 days."
    }

    private var recoverTitle: String {
        let count = cleanup.selectedCount
        return count > 0 ? "Recover \(Plural.photos(count))" : "Recover"
    }

    private var recoverHelp: String {
        if cleanup.isRunning { return "Wait for the current recovery to finish." }
        if isExportRunning { return "Wait for the export to finish." }
        return "Puts the selected photos back in your library on all your devices."
    }

    /// The IDs in the destination's manifest with an iCloud record. Empty without a destination.
    private static func backedUpIDs(at url: URL?) async -> Set<String> {
        guard let url else { return [] }
        return await Task.detached(priority: .utility) {
            Set(ExportManifest.iCloudItems(in: url).keys)
        }.value
    }
}

/// Progress and results of a run, above the grid: the phases, Pause and Cancel, the retry countdown, and the summary.
/// Each state is a `StatusBanner`, the same banner the Browse Backup indexing progress uses.
struct CleanupStatusCard: View {
    let cleanup: ICloudCleanup
    @State private var showsDetails = false

    /// Shown on Cancel and in the confirmation: a batch already sent to iCloud can't be recalled.
    private static let cancelHelp = "Photos already sent to iCloud can’t be called back."

    var body: some View {
        switch cleanup.state {
        case let .finding(done, total):
            progressBanner(title: "Finding photos…", done: done, total: total, canPause: false)
        case let .deleting(done, total, paused):
            progressBanner(
                title: paused ? "Paused" : (cleanup.runMode.action == .restore ? "Recovering…" : "Deleting…"),
                done: done, total: total, canPause: true, paused: paused
            )
        case let .waitingAfterThrottle(until, _):
            waiting(until: until)
        case let .finished(summary):
            summaryView(summary)
        case let .failed(message):
            StatusBanner(symbol: "exclamationmark.triangle.fill", tint: Tokens.Status.warning, title: message) {
                Button("Dismiss") { cleanup.dismiss() }
                    .buttonStyle(.bordered)
            }
        case .idle, .confirming:
            EmptyView()
        }
    }

    private func progressBanner(title: String, done: Int, total: Int, canPause: Bool, paused: Bool = false) -> some View {
        StatusBanner(
            symbol: "icloud",
            tint: .accentColor,
            title: title,
            detail: lines([
                "\(done.formatted()) of \(total.formatted())",
                cleanup.isStopping ? "Stopping after the current batch…" : nil
            ]),
            progress: min(1, Double(done) / Double(max(total, 1)))
        ) {
            if canPause {
                Button(paused ? "Resume" : "Pause") {
                    cleanup.setPaused(!paused)
                }
                .buttonStyle(.bordered)
                .disabled(cleanup.isStopping)
            }
            Button("Cancel") {
                cleanup.cancel()
            }
            .buttonStyle(.bordered)
            .disabled(cleanup.isStopping)
            .help(Self.cancelHelp)
            .accessibilityHint(Self.cancelHelp)
        }
    }

    private func waiting(until: Date) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            StatusBanner(
                symbol: "clock.fill",
                tint: Tokens.Status.warning,
                title: "Apple is limiting deletions for now",
                detail: countdownText(until: until, now: context.date)
            ) {
                Button("Try Now") {
                    cleanup.retryNow()
                }
                .buttonStyle(.borderedProminent)
                Button("Cancel") {
                    cleanup.cancel()
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private func countdownText(until: Date, now: Date) -> String {
        let seconds = max(0, Int(until.timeIntervalSince(now).rounded(.up)))
        let time = Duration.seconds(seconds).formatted(.time(pattern: .minuteSecond))
        return "Trying again in \(time). Photos already deleted stay in Recently Deleted."
    }

    @ViewBuilder
    private func summaryView(_ summary: ICloudCleanup.Summary) -> some View {
        let isRecovery = summary.action == .restore
        VStack(alignment: .leading, spacing: 0) {
            StatusBanner(
                symbol: summary.deleted > 0 ? "checkmark.circle.fill" : "info.circle.fill",
                tint: summary.deleted > 0 ? Tokens.Status.success : Tokens.Status.neutral,
                title: headline(summary),
                detail: summaryDetail(summary, isRecovery: isRecovery)
            ) {
                if summary.action == .delete, summary.deleted > 0 {
                    Button("Show Recently Deleted") {
                        cleanup.setMode(.recentlyDeleted)
                    }
                    .buttonStyle(.bordered)
                }
                Button("Done") {
                    cleanup.dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
            if !summary.failures.isEmpty {
                failureDetails(summary.failures)
            }
        }
    }

    /// The reasons for the photos that weren't changed. Grouped by reason, and never showing an iCloud ID.
    private func failureDetails(_ failures: [ICloudBridgeDeleteFailure]) -> some View {
        DisclosureGroup("Show Details", isExpanded: $showsDetails) {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Self.failureReasons(failures), id: \.reason) { group in
                    Text("\(group.count.formatted()) × \(group.reason)")
                        .font(.caption)
                        .textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.callout)
        .padding(.horizontal, Tokens.Space.l)
        .padding(.bottom, Tokens.Space.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial)
    }

    static func failureReasons(_ failures: [ICloudBridgeDeleteFailure]) -> [(reason: String, count: Int)] {
        Dictionary(grouping: failures, by: \.reason)
            .map { (reason: $0.key, count: $0.value.count) }
            .sorted { $0.reason < $1.reason }
    }

    /// Joins the parts that are present, one per line. Nil when none is.
    private func lines(_ parts: [String?]) -> String? {
        let present = parts.compactMap { $0 }
        return present.isEmpty ? nil : present.joined(separator: "\n")
    }

    private func summaryDetail(_ summary: ICloudCleanup.Summary, isRecovery: Bool) -> String? {
        lines([
            summary.deleted > 0 && !isRecovery ? "They’re in Recently Deleted on all your devices for 30 days." : nil,
            summary.missing > 0
                ? "\(summary.missing.formatted()) were no longer in \(isRecovery ? "Recently Deleted" : "your library")."
                : nil,
            summary.failures.isEmpty
                ? nil
                : "\(summary.failures.count.formatted()) couldn’t be \(isRecovery ? "recovered" : "deleted").",
            summary.stoppedMessage
        ])
    }

    private func headline(_ summary: ICloudCleanup.Summary) -> String {
        if summary.action == .restore {
            if summary.cancelled {
                return summary.deleted > 0
                    ? "Stopped after recovering \(Plural.photos(summary.deleted))."
                    : "Stopped. Nothing was recovered."
            }
            if summary.deleted == 0 {
                return "Nothing was recovered."
            }
            return "Recovered \(Plural.photos(summary.deleted)). They’re back in your library."
        }
        if summary.cancelled {
            return summary.deleted > 0
                ? "Stopped after deleting \(Plural.photos(summary.deleted))."
                : "Stopped. Nothing was deleted."
        }
        if summary.deleted == 0 {
            return "Nothing was deleted."
        }
        return "Deleted \(Plural.photos(summary.deleted)) from iCloud."
    }
}

/// Asks for the count before anything is deleted: the destructive button stays off until the number is typed.
/// Cancel is the button that closes the sheet without deleting; Return never deletes.
struct CleanupConfirmationSheet: View {
    let count: Int
    let notBackedUp: Int
    let onCancel: () -> Void
    let onDelete: (String) -> Void
    @State private var typed = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Delete ^[\(count) Photo](inflect: true) from iCloud?")
                .font(.title2.weight(.semibold))
            Text("They move to Recently Deleted on all your devices, where you can recover them for 30 days.")
                .foregroundStyle(.secondary)
            if notBackedUp > 0 {
                Label("\(notBackedUp.formatted()) of them aren’t in your backup.", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Type \(count.formatted()) to confirm.")
                    .font(.callout)
                TextField("Number of photos", text: $typed)
                    .textFieldStyle(.roundedBorder)
                    .monospacedDigit()
                    .accessibilityLabel("Type \(count) to confirm")
            }

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(role: .destructive) {
                    onDelete(typed)
                } label: {
                    Text("Delete ^[\(count) Photo](inflect: true)")
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(!ICloudCleanup.typedNumberMatches(typed, count: count))
                .help("Photos already sent to iCloud can’t be called back.")
                .accessibilityHint("Photos already sent to iCloud can’t be called back.")
            }
        }
        .padding(Tokens.Sheet.padding)
        .frame(width: Tokens.Sheet.narrow)
    }
}

/// Asks before recovering. Recovering isn't destructive, so there's no number to type: the prominent button is the default.
struct CleanupRecoverySheet: View {
    let count: Int
    let onCancel: () -> Void
    let onRecover: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Recover ^[\(count) Photo](inflect: true)?")
                .font(.title2.weight(.semibold))
            Text("They’ll return to your library on all your devices.")
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(action: onRecover) {
                    Text("Recover ^[\(count) Photo](inflect: true)")
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(Tokens.Sheet.padding)
        .frame(width: Tokens.Sheet.narrow)
    }
}
