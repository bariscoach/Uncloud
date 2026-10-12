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
            } header: {
                SectionTitle(title: "Save To", symbol: "externaldrive", tint: .teal)
            }

            Section {
                Picker("Folder layout", selection: $model.layout) {
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
                if let previous = model.previousLayout, previous != model.layout, model.processedCount > 0 {
                    Label("This folder already has items exported \(previous.title.lowercased()). They’ll stay where they are, and new items will use the layout you choose here.", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                Toggle("Save metadata files (.xmp)", isOn: $model.writesSidecars)
                    .disabled(model.isExporting)
                Text("Adds a small file next to each item with its albums, favorite status, location and dates, which apps like Lightroom can read. Titles, captions, keywords and people aren’t available to other apps, so they can’t be included.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                SectionTitle(title: "Folders and Files", symbol: "folder", tint: .mint)
            }

            Section {
                if model.authorization == .limited {
                    LimitedAccessNotice()
                }
                ProgressCard()
                if !model.isExporting {
                    Button(model.primaryExportTitle(total: total)) {
                        model.performPrimaryAction()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(!model.primaryExportEnabled(total: total))
                }
                if let date = model.lastBackupDate {
                    LabeledContent("Last Export") {
                        Text(date.formatted(.relative(presentation: .named)))
                    }
                }
            } header: {
                SectionTitle(title: "Export", symbol: "square.and.arrow.down", tint: .accentColor)
            }

            if model.destination != nil {
                Section {
                    BackupToolButtons()
                } header: {
                    SectionTitle(title: "Backup Tools", symbol: "checkmark.shield", tint: .green)
                }
            }

            Section {
                ActivitySection()
            }
        }
        .formStyle(.grouped)
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

    /// The item count of the whole library, once known. Used for the primary button's title.
    private var total: Int? {
        model.browser?.count
    }

    private var destinationRow: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                if let destination = model.destination {
                    Text(destination.displayName)
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
            Spacer()
            if model.destination != nil {
                Button {
                    model.revealDestination()
                } label: {
                    Image(systemName: "folder")
                }
                .help("Show in Finder")
                .accessibilityLabel("Show in Finder")
            }
            Button(model.destination == nil ? "Choose Folder…" : "Change Folder…") {
                model.beginChoosingDestination()
            }
            .disabled(model.isExporting)
        }
    }
}

/// A section title with a coloured icon tile, as in System Settings.
private struct SectionTitle: View {
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
