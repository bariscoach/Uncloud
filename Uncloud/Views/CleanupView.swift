import SwiftUI

/// The Clean Up iCloud pane: pick items in the iCloud library and delete them from iCloud Photos, or pick items in
/// Recently Deleted and recover them. Deleted items move to Recently Deleted, where they stay for 30 days. The backup
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
                    Label("Clean Up iCloud", systemImage: "trash")
                } description: {
                    Text("Clean Up works on your iCloud Photos library. Switch the source to iCloud Photos to choose items to delete.")
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
                    Text("Sign in to iCloud to choose items to delete from iCloud Photos.")
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

    /// The list the picker shows.
    private var browser: LibraryBrowser {
        cleanup.mode == .library ? library : recentlyDeleted
    }

    var body: some View {
        Group {
            if cleanup.mode == .recentlyDeleted, browser.count == 0 {
                ContentUnavailableView("Recently Deleted is empty.", systemImage: "trash")
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
                    Text("Reading your library…")
                }
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: 0) {
                modePicker
                if cleanup.mode == .recentlyDeleted {
                    Text("Items are permanently removed by iCloud after 30 days.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 8)
                }
                if showsStatus {
                    CleanupStatusCard(cleanup: cleanup)
                        .transition(.opacity)
                }
            }
        }
        .animation(.smooth, value: showsStatus)
        .sheet(isPresented: isConfirming) {
            if cleanup.mode == .library {
                CleanupConfirmationSheet(
                    count: cleanup.pendingCount,
                    notBackedUp: notBackedUpCount,
                    onCancel: { cleanup.cancelConfirmation() },
                    onDelete: { typed in cleanup.start(typed: typed) }
                )
            } else {
                CleanupRecoverySheet(
                    count: cleanup.pendingCount,
                    onCancel: { cleanup.cancelConfirmation() },
                    onRecover: { cleanup.recover() }
                )
            }
        }
        .toolbar {
            toolbar
        }
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
    private var modePicker: some View {
        Picker("Show", selection: Binding(get: { cleanup.mode }, set: { cleanup.setMode($0) })) {
            Text("Library").tag(ICloudCleanup.Mode.library)
            Text(recentlyDeletedTitle).tag(ICloudCleanup.Mode.recentlyDeleted)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .disabled(cleanup.isRunning)
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 8)
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

    /// Selected items that aren't backed up on the destination, for the warning in the confirmation.
    private var notBackedUpCount: Int {
        let backedUpSelected = backedUp.filter { cleanup.selection.contains($0) }.count
        return max(0, cleanup.pendingCount - backedUpSelected)
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Text(countText)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .lineLimit(1)

            Menu("Select") {
                Button("Select All") {
                    cleanup.selection = filter.selection(backedUp: backedUp)
                }
                .disabled(browser.count == nil)
                Button("Deselect All") {
                    cleanup.selection = .only([])
                }
                .disabled(cleanup.selection.isNothing)
            }
            .help("Select or deselect every item")

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
            .help("Choose which items Select All selects, and which are dimmed")
            .accessibilityLabel("Filter, \(filter.title)")

            if cleanup.mode == .library {
                Button(deleteTitle) {
                    cleanup.requestConfirmation()
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
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

    private var total: Int? { browser.count }

    private var countText: String {
        guard let total else { return "" }
        let selected = cleanup.selection.selectedCount(total: total)
        let count = cleanup.selection.isEverything
            ? "All \(total.formatted()) items selected"
            : "\(selected.formatted()) of \(total.formatted()) selected"
        guard selected > 0, let size = sizeText(selected: selected) else { return count }
        return "\(count) · \(size)"
    }

    /// The selected items' sizes, from the ones whose sizes are known. "At least" unless every selected item is known.
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
        if cleanup.isRunning { return "A clean up is running." }
        if isExportRunning { return "Wait for the export to finish." }
        return "Delete the selected items from iCloud Photos. They stay in Recently Deleted for 30 days."
    }

    private var recoverTitle: String {
        let count = cleanup.selectedCount
        return count > 0 ? "Recover \(count.formatted()) \(count == 1 ? "Item" : "Items")" : "Recover Items"
    }

    private var recoverHelp: String {
        if cleanup.isRunning { return "A clean up is running." }
        if isExportRunning { return "Wait for the export to finish." }
        return "Recover the selected items to your library on all your devices."
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
struct CleanupStatusCard: View {
    let cleanup: ICloudCleanup
    @State private var showsDetails = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch cleanup.state {
            case let .finding(done, total):
                progress(title: "Finding items…", done: done, total: total)
                controls(canPause: false)
            case let .deleting(done, total, paused):
                progress(title: paused ? "Paused" : (cleanup.runMode.action == .restore ? "Recovering…" : "Deleting…"),
                         done: done, total: total)
                controls(canPause: true, paused: paused)
            case let .waitingAfterThrottle(until, attempt):
                waiting(until: until, attempt: attempt)
            case let .finished(summary):
                summaryView(summary)
            case let .failed(message):
                Label {
                    Text(message)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                .font(.callout)
                HStack {
                    Spacer()
                    Button("Dismiss") { cleanup.dismiss() }
                        .buttonStyle(.bordered)
                }
            case .idle, .confirming:
                EmptyView()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial)
        .overlay(alignment: .bottom) {
            Divider()
        }
    }

    private func progress(title: String, done: Int, total: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                    .font(.headline)
                Spacer()
                Text("\(done.formatted()) of \(total.formatted())")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            ProgressView(value: Double(done), total: Double(max(total, 1)))
                .accessibilityLabel(title)
                .accessibilityValue("\(done) of \(total)")
        }
    }

    private func controls(canPause: Bool, paused: Bool = false) -> some View {
        HStack {
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
            if cleanup.isStopping {
                Text("Stopping after the batch in progress…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .help("A batch already sent to iCloud can’t be recalled.")
    }

    private func waiting(until: Date, attempt: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Apple is limiting deletions for now")
                .font(.headline)
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(countdownText(until: until, now: context.date))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .font(.callout)
            HStack {
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
        return "Trying the rest again in \(time). Items already deleted stay deleted."
    }

    @ViewBuilder
    private func summaryView(_ summary: ICloudCleanup.Summary) -> some View {
        let isRecovery = summary.action == .restore
        VStack(alignment: .leading, spacing: 8) {
            Label {
                Text(headline(summary))
                    .font(.headline)
            } icon: {
                Image(systemName: summary.deleted > 0 ? "checkmark.circle.fill" : "info.circle.fill")
                    .foregroundStyle(summary.deleted > 0 ? .green : .secondary)
            }
            if summary.deleted > 0, !isRecovery {
                Text("They’re in Recently Deleted on all your devices for 30 days.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if summary.missing > 0 {
                Text("\(summary.missing.formatted()) were no longer in \(isRecovery ? "Recently Deleted" : "your library").")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if !summary.failures.isEmpty {
                Label("\(summary.failures.count.formatted()) couldn’t be \(isRecovery ? "recovered" : "deleted").",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
                DisclosureGroup("Show Details", isExpanded: $showsDetails) {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(summary.failures, id: \.id) { failure in
                            Text("\(failure.id): \(failure.reason)")
                                .font(.caption)
                                .textSelection(.enabled)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.callout)
            }
            if let message = summary.stoppedMessage {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
            HStack {
                Spacer()
                if summary.action == .delete, summary.deleted > 0 {
                    Button("View Recently Deleted") {
                        cleanup.setMode(.recentlyDeleted)
                    }
                    .buttonStyle(.bordered)
                }
                Button("Done") {
                    cleanup.dismiss()
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private func headline(_ summary: ICloudCleanup.Summary) -> String {
        if summary.action == .restore {
            if summary.cancelled {
                return summary.deleted > 0
                    ? "Stopped. Recovered \(Self.items(summary.deleted))."
                    : "Stopped. Nothing was recovered."
            }
            if summary.deleted == 0 {
                return "No items were recovered."
            }
            return "Recovered \(Self.items(summary.deleted)). They’re back in your library."
        }
        if summary.cancelled {
            return summary.deleted > 0
                ? "Stopped. Deleted \(Self.items(summary.deleted)) from iCloud."
                : "Stopped. Nothing was deleted."
        }
        if summary.deleted == 0 {
            return "No items were deleted."
        }
        return "Deleted \(Self.items(summary.deleted)) from iCloud."
    }

    /// "1 item" or "1,200 items". Runtime strings can't use Text's inflection markup, so this does it by hand.
    private static func items(_ count: Int) -> String {
        "\(count.formatted()) \(count == 1 ? "item" : "items")"
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
            Text("Delete ^[\(count) item](inflect: true) from iCloud?")
                .font(.title2.weight(.semibold))
            Text("The items move to Recently Deleted on all your devices. They can be recovered there for 30 days.")
                .foregroundStyle(.secondary)
            if notBackedUp > 0 {
                Label("\(notBackedUp.formatted()) of them aren’t backed up to your drive.", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
            Text("A batch that has already been sent to iCloud can’t be recalled.")
                .font(.callout)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 6) {
                Text("Type \(count.formatted()) to confirm.")
                    .font(.callout)
                TextField("Number of items", text: $typed)
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
                    Text("Delete ^[\(count) Item](inflect: true)")
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(!ICloudCleanup.typedNumberMatches(typed, count: count))
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}

/// Asks before recovering. Recovering isn't destructive, so there's no number to type: the prominent button is the default.
struct CleanupRecoverySheet: View {
    let count: Int
    let onCancel: () -> Void
    let onRecover: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Recover ^[\(count) item](inflect: true)?")
                .font(.title2.weight(.semibold))
            Text("They’ll return to your library on all your devices.")
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(action: onRecover) {
                    Text("Recover ^[\(count) Item](inflect: true)")
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}
