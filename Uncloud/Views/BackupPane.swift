import SwiftUI

/// The Backup pane: where exports go, how they are organized, progress, and the backup tools.
struct BackupPane: View {
    @Environment(ExportModel.self) private var model

    var body: some View {
        if model.isSourceReady {
            form
        } else {
            // Until a source is ready, Backup is the place to connect one: the same landing page as first launch.
            LandingView()
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
                VStack(alignment: .leading, spacing: Tokens.Space.xs) {
                    layoutPicker
                    Text(model.layout.example)
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
                if let notice = model.layoutSwitchNotice {
                    Label {
                        Text(notice)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(Tokens.Status.warning)
                    }
                    .font(.caption)
                }

                VStack(alignment: .leading, spacing: Tokens.Space.xs) {
                    Toggle("Save XMP metadata files", isOn: $model.writesSidecars)
                        .disabled(model.isExporting)
                        .help(xmpExplanation)
                        .accessibilityHint(xmpExplanation)
                    Text("Adds a small file beside each photo with its albums, favorites, location and dates, for apps like Lightroom.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                SectionTitle("Folders")
            }

            if model.destination != nil {
                Section {
                    BackupToolButtons()
                } header: {
                    SectionTitle("Tools")
                }

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
        .formStyle(.grouped)
        .navigationSubtitle(model.destination?.displayName ?? "")
        .toolbar {
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

    /// The folder layout menu. Its explanation for the selected layout is in `.help`, not on screen.
    private var layoutPicker: some View {
        @Bindable var model = model

        return Picker("Folders", selection: Binding(get: { model.layout }, set: { model.requestLayoutChange(to: $0) })) {
            ForEach(FolderLayout.allCases.filter { $0.isAvailable(for: model.source) }) { layout in
                Text(layout.title).tag(layout)
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .disabled(model.isExporting)
        .help(layoutExplanation ?? "")
        .accessibilityHint(layoutExplanation ?? "")
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
    }

    /// What the selected layout does with places, albums and the source. Was three captions under the picker.
    private var layoutExplanation: String? {
        var parts: [String] = []
        if model.layout.usesPlaces {
            parts.append("Place names come from each photo’s location, which Apple looks up. Photos without one go in “Unknown Location”.")
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

    /// The selection's estimated size and the destination's free space, as one row's value.
    private var spaceValue: String? {
        guard let text = model.storageEstimateText else { return nil }
        let estimate = text.prefix(1).uppercased() + text.dropFirst()
        var parts = [model.storageEstimate == nil ? estimate : "\(estimate) needed"]
        if model.destination != nil, let free = model.destinationFreeBytes {
            parts.append("\(StorageEstimate.format(free)) free")
        }
        return parts.joined(separator: " · ")
    }

    /// The estimate's basis and the amount still to export, which were two captions. Now the row's help.
    private var spaceHelp: String {
        var parts: [String] = []
        if let note = model.storageEstimateNote {
            parts.append(note)
        }
        if let estimate = model.storageEstimate, let needed = model.storageNeededBytes, needed < estimate.bytes {
            parts.append("About \(StorageEstimate.format(needed)) still to export.")
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
                    Text("No backup folder chosen")
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

/// A section header in the Backup pane: plain headline text, as in System Settings. The `title:symbol:tint:` form is
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
