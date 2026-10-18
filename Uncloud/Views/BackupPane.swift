import SwiftUI

/// The Backup pane: where exports go, how they are organized, progress, and the backup tools.
struct BackupPane: View {
    @Environment(ExportModel.self) private var model

    var body: some View {
        if model.isSourceReady {
            form
        } else {
            notReady
        }
    }

    /// Shown while no source is ready: nothing to export yet, so point back to the Library's landing page.
    private var notReady: some View {
        ContentUnavailableView {
            Label("Nothing to Export Yet", systemImage: "externaldrive")
        } description: {
            Text("Choose where your photos come from first: iCloud or the Photos library on this Mac.")
        } actions: {
            Button("Get Started") {
                model.pane = .library
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private var form: some View {
        @Bindable var model = model

        return Form {
            // The status and the one thing to do about it come first. Set-once settings sit below, so Export is
            // in view without scrolling.
            Section {
                BackupHero(total: total)
                if model.authorization == .limited {
                    LimitedAccessNotice()
                }
            }

            Section {
                destinationRow
                if let issue = model.destinationIssue {
                    Label(issue, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                }
                spaceNeededRow
                if let warning = model.storageWarning {
                    Label(warning, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
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
                SectionTitle(title: "Save To", symbol: "externaldrive", tint: Tokens.Tint.drive)
            }

            Section {
                Picker("Folder layout", selection: Binding(get: { model.layout }, set: { model.requestLayoutChange(to: $0) })) {
                    ForEach(FolderLayout.allCases.filter { $0.isAvailable(for: model.source) }) { layout in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(layout.title)
                            Text(layout.example)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .tag(layout)
                    }
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
                .disabled(model.isExporting)
                .confirmationDialog(
                    model.pendingLayoutChange?.title ?? "",
                    isPresented: Binding(get: { model.pendingLayoutChange != nil }, set: { if !$0 { model.resolveLayoutChange(.cancel) } }),
                    presenting: model.pendingLayoutChange
                ) { _ in
                    Button(ExportModel.LayoutChangeConfirmation.chooseNewFolderTitle) { model.resolveLayoutChange(.chooseNewFolder) }
                        .keyboardShortcut(.defaultAction)
                    Button(ExportModel.LayoutChangeConfirmation.downloadAgainTitle) { model.resolveLayoutChange(.downloadAgainHere) }
                    Button(ExportModel.LayoutChangeConfirmation.cancelTitle, role: .cancel) { model.resolveLayoutChange(.cancel) }
                } message: { confirmation in
                    Text(confirmation.message)
                }

                if model.layout.usesPlaces {
                    Label("Place names come from each photo’s location, which is sent to Apple to look up the city and country. Photos without a location go in “Unknown Location”.", systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if model.layout == .album {
                    Label(model.source == .iCloud
                          ? "Each album is saved in its own folder. Photos that aren’t in any album aren’t included."
                          : "Items in more than one album are saved in each album’s folder. On drives formatted as APFS the extra copies take no additional space.",
                          systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let caption = model.layout.caption(for: model.source) {
                    Label(caption, systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let warning = model.flatFolderWarning {
                    Label(warning, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                if let notice = model.layoutSwitchNotice {
                    Label(notice, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                Toggle("Save metadata files (.xmp)", isOn: $model.writesSidecars)
                    .disabled(model.isExporting)
                Text("Adds a small file next to each item with its albums, favorite status, location and dates, which apps like Lightroom can read. Titles, captions, keywords and people aren’t available to other apps, so they can’t be included.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                SectionTitle(title: "Folders and Files", symbol: "folder", tint: Tokens.Tint.folders)
            }

            if model.destination != nil {
                Section {
                    BackupToolButtons()
                } header: {
                    SectionTitle(title: "Backup Tools", symbol: "checkmark.shield", tint: Tokens.Tint.tools)
                }

                ExportHistoryView(
                    chains: model.exportHistory,
                    unavailableText: model.exportHistoryUnavailableText,
                    showInFinder: { model.showSessionsInFinder() }
                )
            }

            Section {
                ActivitySection()
            }
        }
        .formStyle(.grouped)
        .navigationSubtitle(model.destination?.displayName ?? "")
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

    /// The selection's estimated size, with the destination's free space beneath it.
    @ViewBuilder
    private var spaceNeededRow: some View {
        if let text = model.storageEstimateText {
            LabeledContent {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(text.prefix(1).uppercased() + text.dropFirst())
                        .monospacedDigit()
                    if let estimate = model.storageEstimate, let needed = model.storageNeededBytes, needed < estimate.bytes {
                        Text("About \(StorageEstimate.format(needed)) still to copy")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    if let destination = model.destination, let free = model.destinationFreeBytes {
                        Text("\(StorageEstimate.format(free)) free on “\(destination.displayName)”")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
            } label: {
                Text("Space needed")
                if let note = model.storageEstimateNote {
                    Text(note)
                }
            }
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
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
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
                    Text("No folder chosen")
                        .foregroundStyle(.secondary)
                }
            }
            // The name and path keep their width ahead of the buttons, so the name stays on one line.
            .layoutPriority(1)
            Spacer()
            if model.destination != nil {
                Button {
                    model.revealDestination()
                } label: {
                    Image(systemName: "folder")
                }
                .help("Show in Finder")
                .accessibilityLabel("Show in Finder")
                .fixedSize()
            }
            Button(model.destination == nil ? "Choose Folder…" : "Change Folder…") {
                model.beginChoosingDestination()
            }
            .disabled(model.isExporting)
            // The buttons keep their width, so a long folder name or path truncates instead of squeezing them.
            .fixedSize()
        }
    }
}

/// A section title with a coloured icon tile, as in System Settings. Every section of the Backup pane uses one.
struct SectionTitle: View {
    let title: String
    let symbol: String
    let tint: Color

    var body: some View {
        HStack(spacing: 8) {
            IconTile(symbol: symbol, tint: tint)
            Text(title)
                .font(.headline)
        }
    }
}
