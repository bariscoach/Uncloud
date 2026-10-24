import AppKit
import SwiftUI

/// The Export Settings pane (`Pane.backup`; the name is kept from the Backup pane). A segmented control in the
/// toolbar switches between General (where exports go, progress and history) and Folder Organization (how files
/// are arranged and named).
struct ExportSettingsPane: View {
    @Environment(ExportModel.self) private var model
    // Optional so that a view hosted without these in its environment still renders.
    @Environment(AutoBackupSettings.self) private var autoBackup: AutoBackupSettings?
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        if model.isSourceReady {
            form
        } else {
            // Until a source is ready, Export Settings is the place to connect one: the same landing page as first launch.
            LandingView()
        }
    }

    private var form: some View {
        @Bindable var model = model

        return Form {
            switch model.exportSettingsSection {
            case .general:
                generalSections
            case .folders:
                folderSections
            }
        }
        .formStyle(.grouped)
        .navigationSubtitle(model.destination?.displayName ?? "")
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Section", selection: $model.exportSettingsSection) {
                    ForEach(ExportModel.ExportSettingsSection.allCases, id: \.self) { section in
                        Text(section.title).tag(section)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .accessibilityLabel("Section")
            }
            if model.destination != nil {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        model.revealDestination()
                    } label: {
                        Label("Show in Finder", systemImage: "folder")
                    }
                    .help("Show in Finder")
                }
            }
        }
        // The layout-mismatch confirmation lives at the pane root, so it shows whichever section is visible.
        .confirmationDialog(
            model.pendingLayoutChange?.title ?? "",
            isPresented: Binding(get: { model.pendingLayoutChange != nil }, set: { if !$0 { model.resolveLayoutChange(.cancel) } }),
            presenting: model.pendingLayoutChange
        ) { confirmation in
            if let recorded = confirmation.recorded {
                // The folder's own layout is the recommended choice: the export it held back starts with it.
                Button("Use \(recorded.title)") { model.resolveLayoutChange(.useRecorded) }
                    .keyboardShortcut(.defaultAction)
                Button(ExportModel.LayoutChangeConfirmation.chooseNewFolderTitle) { model.resolveLayoutChange(.chooseNewFolder) }
            } else {
                Button(ExportModel.LayoutChangeConfirmation.chooseNewFolderTitle) { model.resolveLayoutChange(.chooseNewFolder) }
                    .keyboardShortcut(.defaultAction)
                Button(ExportModel.LayoutChangeConfirmation.downloadAgainTitle) { model.resolveLayoutChange(.downloadAgainHere) }
            }
            Button(ExportModel.LayoutChangeConfirmation.cancelTitle, role: .cancel) { model.resolveLayoutChange(.cancel) }
        } message: { confirmation in
            Text(confirmation.message)
        }
        .sheet(item: manualCheckBinding) { report in
            CheckDriveResultsSheet(report: report, source: model.source) {
                model.showSetAsideFolder(report.setAsideFolder)
            }
        }
        .task(id: model.destination?.url) {
            // Free space changes as files are written, here or by other apps.
            while !Task.isCancelled {
                model.refreshDestinationFreeSpace()
                try? await Task.sleep(for: ExportModel.freeSpaceInterval)
            }
        }
    }

    // MARK: - General

    @ViewBuilder
    private var generalSections: some View {
        // The status and the one thing to do about it come first. Set-once settings sit below, so Export is
        // in view without scrolling.
        Section {
            BackupHero(total: total)
            if model.authorization == .limited {
                LimitedAccessNotice()
            }
            exportByDateRow
        }

        Section {
            destinationRow
            if let issue = model.destinationIssue {
                Label {
                    Text(issue)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Tokens.Status.danger)
                }
            }
            spaceNeededRow
            if let warning = model.storageWarning {
                Label {
                    Text(warning)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Tokens.Status.warning)
                }
            }
            if model.destination != nil {
                DriveSummaryRow(
                    summary: model.onDriveSummaryText,
                    lastChecked: model.lastDriveCheckedAt,
                    isChecking: model.isCheckingDrive,
                    progressText: model.driveCheckProgressText,
                    canCheck: model.canCheckDrive,
                    onCheck: { model.checkDrive(full: true) },
                    onCancel: { model.cancelDriveCheck() }
                )
            }
        } header: {
            SectionTitle("Backup Folder")
        }

        Section {
            automaticBackupsRow
        } header: {
            SectionTitle("Automatic Backups")
        }

        if model.destination != nil {
            ExportHistoryView(
                chains: model.exportHistory,
                unavailableText: model.exportHistoryUnavailableText,
                showInFinder: { model.showSessionsInFinder() }
            )
        }

        // Activity is a disclosure row, collapsed by default, after the history.
        Section {
            ActivitySection(asRow: true)
        }
    }

    /// Export Photos by Date is always here, whatever the hero's button is. Its dates are chosen in their own sheet.
    private var exportByDateRow: some View {
        LabeledContent {
            Button("Choose Dates…") { model.openExportByDate() }
                .fixedSize()
                .disabled(!model.canOpenExportByDate)
        } label: {
            VStack(alignment: .leading, spacing: Tokens.Space.xs) {
                Text("Export Photos by Date")
                Text("Pick a start and end date. Uncloud exports the photos taken in between and skips the ones already backed up.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Automatic backups are set in Settings › Backups. This row shows the state and opens that tab.
    private var automaticBackupsRow: some View {
        let status = AutomaticBackupStatus.text(
            connects: autoBackup?.backUpWhenDriveConnects ?? false,
            daily: autoBackup?.backUpDaily ?? false
        )
        return LabeledContent {
            Button("Change…") { openBackupSettings() }
                .fixedSize()
        } label: {
            Text(status)
        }
        .help("Open Settings to change automatic backups")
    }

    /// Opens Settings on its Backups tab, the same way Uncloud ▸ Account Settings… opens the Account tab.
    private func openBackupSettings() {
        UserDefaults.standard.set(SettingsTab.backups.rawValue, forKey: SettingsTab.storageKey)
        openSettings()
        NSApp.activate()
    }

    // MARK: - Folder Organization

    @ViewBuilder
    private var folderSections: some View {
        if let notice = model.layoutSwitchNotice {
            Section {
                Label {
                    Text(notice)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Tokens.Status.warning)
                }
                .font(.caption)
            }
        }

        Section {
            layoutPicker
            if let explanation = layoutExplanation {
                Text(explanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let warning = model.flatFolderWarning {
                Label {
                    Text(warning)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Tokens.Status.warning)
                }
                .font(.caption)
            }
        } header: {
            SectionTitle("Folders")
        }

        Section {
            Text("Files keep their original names, like IMG_0001.HEIC.")
            Text(FolderLayout.clashRule(for: model.source))
                .font(.caption)
                .foregroundStyle(.secondary)
        } header: {
            SectionTitle("File Names")
        }

        Section {
            Toggle("Save an XMP file with each photo", isOn: Binding(get: { model.writesSidecars }, set: { model.writesSidecars = $0 }))
                .disabled(model.isExporting)
                .help(xmpExplanation)
                .accessibilityHint(xmpExplanation)
            Text("Keeps albums, favorites, places and dates for apps like Lightroom.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } header: {
            SectionTitle("Extras")
        } footer: {
            if model.isExporting {
                Text("You can change this when the export finishes.")
            }
        }
    }

    /// The folder layouts as a radio group. Each option shows its example path, so every choice is visible at once.
    private var layoutPicker: some View {
        @Bindable var model = model

        return Picker("Folders", selection: Binding(get: { model.layout }, set: { model.requestLayoutChange(to: $0) })) {
            ForEach(FolderLayout.allCases.filter { $0.isAvailable(for: model.source) }) { layout in
                HStack {
                    Text(layout.title)
                    Spacer()
                    Text(layout.example.replacingOccurrences(of: "/", with: " / "))
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
                .tag(layout)
            }
        }
        .pickerStyle(.radioGroup)
        .labelsHidden()
        .disabled(model.isExporting)
    }

    /// What the selected layout does with places and albums, plus its flat-folder caption. Visible under the picker.
    private var layoutExplanation: String? {
        var parts: [String] = []
        if model.layout.usesPlaces {
            parts.append("Place names come from each photo’s location. Photos without one go in “Unknown Location”.")
        }
        if model.layout == .album {
            parts.append(model.source == .iCloud
                ? "Each album gets its own folder. Photos that aren’t in an album aren’t exported."
                : "Photos in several albums are saved in each one. On APFS drives the extra copies use no extra space.")
        }
        if let caption = model.layout.caption(for: model.source) {
            parts.append(caption)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    /// The second sentence of the XMP caption, which moved to the toggle's help.
    private var xmpExplanation: String {
        "Titles, captions, keywords and people aren’t available to other apps, so they can’t be included."
    }

    // MARK: - Shared rows

    /// What still has to be exported, and the destination's free space, as one row's value.
    private var spaceValue: String? {
        SpaceRowText.value(
            estimateText: model.storageEstimateText,
            hasEstimate: model.storageEstimate != nil,
            backedUp: (model.onDriveCount ?? 0) > 0,
            needed: model.toGoCount == 0 ? 0 : model.storageNeededBytes,
            free: model.destination == nil ? nil : model.destinationFreeBytes
        )
    }

    /// The whole library's estimate and the estimate's basis, which were two captions. Now the row's help.
    private var spaceHelp: String {
        var parts: [String] = []
        if let estimate = model.storageEstimate {
            parts.append("Your whole library is \(estimate.formatted).")
        }
        if let note = model.storageEstimateNote {
            parts.append(note)
        }
        return parts.joined(separator: " ")
    }

    /// The selection's estimated size, with the destination's free space beside it.
    @ViewBuilder
    private var spaceNeededRow: some View {
        if let value = spaceValue {
            LabeledContent("Space") {
                Text(value)
                    .monospacedDigit()
            }
            .help(spaceHelp)
            .accessibilityHint(spaceHelp)
        }
    }

    /// Presents `lastManualDriveCheck` as a sheet. Dismissing it clears the report, so it shows once.
    private var manualCheckBinding: Binding<DriveCheckReport?> {
        Binding(
            get: { model.lastManualDriveCheck },
            set: { if $0 == nil { model.dismissManualDriveCheck() } }
        )
    }

    /// The item count of the whole library, once known. Used for the primary button's title.
    private var total: Int? {
        model.browser?.count
    }

    private var destinationRow: some View {
        HStack(spacing: Tokens.Space.m) {
            Image(systemName: "externaldrive")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Tokens.Space.xs) {
                if let destination = model.destination {
                    Text(destination.displayName)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(destination.path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                } else {
                    Text("No folder chosen yet")
                        .foregroundStyle(.secondary)
                }
            }
            // The name and path keep their width ahead of the button, so the name stays on one line.
            .layoutPriority(1)
            Spacer()
            Button(model.destination == nil ? "Choose Folder…" : "Change…") {
                model.beginChoosingDestination()
            }
            .disabled(model.isExporting)
            // The button keeps its width, so a long folder name or path truncates instead of squeezing it.
            .fixedSize()
        }
    }
}

/// The one-line status of automatic backups. Pure, so it is tested without a window.
enum AutomaticBackupStatus {
    static func text(connects: Bool, daily: Bool) -> String {
        switch (connects, daily) {
        case (true, true): return "On: when the drive connects and daily"
        case (true, false): return "On: when the drive connects"
        case (false, true): return "On: once a day"
        case (false, false): return "Off"
        }
    }
}

/// The Backup pane's old name. Tests and the window's detail view still use it until they move to `ExportSettingsPane`.
typealias BackupPane = ExportSettingsPane

/// A section header in Export Settings: plain headline text, as in System Settings. The `title:symbol:tint:` form is
/// kept so existing callers compile. It draws the title alone, with no icon tile.
struct SectionTitle: View {
    let title: String

    init(_ title: String) {
        self.title = title
    }

    init(title: String, symbol: String, tint: Color) {
        self.title = title
    }

    var body: some View {
        Text(title)
            .font(.headline)
    }
}
