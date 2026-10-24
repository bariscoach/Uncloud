import SwiftUI

/// The Backup pane's drive row: what the backup holds for the current selection, when it was last checked, and
/// Check Backup Folder. While a check runs it shows progress and Cancel instead.
struct DriveSummaryRow: View {
    /// `ExportModel.onDriveSummaryText`, such as "9,207 already on this drive · 83,808 to go".
    let summary: String?
    /// When the drive was last checked. Nil leaves the line out.
    let lastChecked: Date?
    let isChecking: Bool
    /// `ExportModel.driveCheckProgressText`, such as "41,000 of about 93,000 files".
    let progressText: String?
    /// `ExportModel.canCheckDrive`.
    let canCheck: Bool
    let onCheck: () -> Void
    let onCancel: () -> Void

    var body: some View {
        if isChecking {
            HStack(spacing: Tokens.Space.m) {
                ProgressView()
                    .controlSize(.small)
                VStack(alignment: .leading, spacing: Tokens.Space.xs) {
                    Text("Checking your backup…")
                    if let progressText {
                        Text(progressText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                Spacer()
                Button("Cancel", action: onCancel)
                    .accessibilityHint("Stops the check. Nothing on the drive has changed.")
            }
        } else {
            HStack(alignment: .firstTextBaseline, spacing: Tokens.Space.m) {
                VStack(alignment: .leading, spacing: Tokens.Space.xs) {
                    if let summary {
                        Text(summary.prefix(1).uppercased() + summary.dropFirst())
                            .monospacedDigit()
                    } else {
                        Text("Not checked yet")
                            .foregroundStyle(.secondary)
                    }
                    if let lastChecked {
                        Text("Checked \(ExportHistoryFormat.when(lastChecked))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button("Check Backup Folder", action: onCheck)
                    .disabled(!canCheck)
                    .accessibilityHint("Finds missing and damaged files. Damaged files are moved to a separate folder, never deleted.")
            }
        }
    }
}

/// Lets `.sheet(item:)` present a check's report. A report is presented once: dismissing the sheet clears
/// `ExportModel.lastManualDriveCheck`, so two checks never share an identity.
extension DriveCheckReport: Identifiable {
    var id: String { "\(filesListed)-\(onDrive)-\(seconds)" }
}

/// The result of a manual check, in plain language: what was missing or damaged, what was done about it, and
/// what was only counted. Presented by the Backup pane when a manual check finishes.
struct CheckDriveResultsSheet: View {
    let report: DriveCheckReport
    /// The library the drive holds. Kept for the copy that says what happens next time.
    let source: LibrarySource
    /// Opens `.photo-export/set-aside/<folder>` on the drive in Finder. Nil hides the button.
    let onShowSetAside: (() -> Void)?

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        FormSheetScaffold("Check Results", minHeight: 440) {
            Section {
                LabeledContent("Checked") {
                    Text("\(report.filesListed.formatted()) files in \(Self.durationText(report.seconds))")
                        .monospacedDigit()
                }
                LabeledContent("Backed up") {
                    Text(report.isApproximate
                         ? "about \(report.onDrive.formatted()) · \(report.toGo.formatted()) to go"
                         : "\(report.onDrive.formatted()) · \(report.toGo.formatted()) to go")
                        .monospacedDigit()
                        .multilineTextAlignment(.trailing)
                }
            } header: {
                Text("Summary")
            }

            if !report.foundProblems && report.registeredFiles.isEmpty && report.otherFiles == 0
                && report.partialFiles == 0 && report.partialItems == 0 && report.changedFiles.isEmpty {
                Section {
                    Label {
                        Text("Everything looks good.")
                    } icon: {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                }
            }

            if report.missingItems > 0 {
                Section {
                    Label {
                        Text("\(Plural.photos(report.missingItems)) \(report.missingItems == 1 ? "is" : "are") missing")
                    } icon: {
                        Image(systemName: "questionmark.folder")
                            .foregroundStyle(.orange)
                    }
                    Text("They’ll be exported again next time.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    fileList(report.missingFiles, title: "Show Missing Files")
                } header: {
                    Text("Missing")
                }
            }

            if !report.damagedFiles.isEmpty {
                Section {
                    Label {
                        Text("\(report.damagedFiles.count.formatted()) \(report.damagedFiles.count == 1 ? "file is" : "files are") damaged")
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
                    Text(damagedNote)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let onShowSetAside, !report.setAsideFiles.isEmpty {
                        Button("Show Damaged Files in Finder", action: onShowSetAside)
                            .accessibilityHint("Opens the folder that holds the damaged files.")
                    }
                    fileList(report.damagedFiles, title: "List Damaged Files")
                    if !report.setAsideFailures.isEmpty {
                        let count = report.setAsideFailures.count
                        Label {
                            Text("\(count.formatted()) \(count == 1 ? "file couldn’t" : "files couldn’t") be moved and \(count == 1 ? "was" : "were") left in place. \(count == 1 ? "It’s" : "They’re") checked again next time.")
                        } icon: {
                            Image(systemName: "xmark.octagon")
                                .foregroundStyle(.red)
                        }
                        .font(.caption)
                        fileList(report.setAsideFailures.map { "\($0.path): \($0.reason)" }, title: "Show Files Not Moved")
                    }
                } header: {
                    Text("Damaged")
                }
            }

            if !report.changedFiles.isEmpty {
                Section {
                    Label {
                        Text("\(report.changedFiles.count.formatted()) other \(report.changedFiles.count == 1 ? "file" : "files") changed")
                    } icon: {
                        Image(systemName: "doc.badge.ellipsis")
                            .foregroundStyle(.secondary)
                    }
                    Text("They may not be Uncloud’s, so they were left alone.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    fileList(report.changedFiles, title: "Show Changed Files")
                } header: {
                    Text("Changed")
                }
            }

            if !report.registeredFiles.isEmpty {
                Section {
                    Label {
                        Text("\(report.registeredFiles.count.formatted()) \(report.registeredFiles.count == 1 ? "file" : "files") recognized")
                    } icon: {
                        Image(systemName: "checkmark.circle")
                            .foregroundStyle(.green)
                    }
                    Text("These were already in your backup folder. Uncloud now records them.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    fileList(report.registeredFiles, title: "Show Files")
                } header: {
                    Text("Recognized")
                }
            }

            if report.otherFiles > 0 {
                Section {
                    Label {
                        Text("\(report.otherFiles.formatted()) other \(report.otherFiles == 1 ? "file was" : "files were") left alone")
                    } icon: {
                        Image(systemName: "doc")
                            .foregroundStyle(.secondary)
                    }
                    Text("Files such as your own documents. Uncloud never changes or records them.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("Other Files")
                }
            }

            if report.partialFiles > 0 || report.partialItems > 0 {
                Section {
                    Label {
                        Text("\(unfinishedCount.formatted()) unfinished \(unfinishedCount == 1 ? "file" : "files")")
                    } icon: {
                        Image(systemName: "arrow.down.circle.dotted")
                            .foregroundStyle(.secondary)
                    }
                    Text("They’ll be exported again next time.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("Unfinished")
                }
            }
        } buttons: {
            Button("Done") {
                dismiss()
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
        }
    }

    /// Unfinished downloads when there are any, otherwise the partly exported photos.
    private var unfinishedCount: Int {
        report.partialFiles > 0 ? report.partialFiles : report.partialItems
    }

    private var damagedNote: String {
        if report.setAsideFiles.isEmpty {
            return report.setAsideFailures.isEmpty
                ? "They’ll be moved to a separate folder and exported again next time."
                : "Nothing was moved."
        }
        return "Moved to a separate folder, never deleted. They’ll be exported again."
    }

    /// File names behind a disclosure, so long lists don't fill the sheet. Capped at 200.
    @ViewBuilder
    private func fileList(_ names: [String], title: String) -> some View {
        if !names.isEmpty {
            DisclosureGroup(title) {
                ForEach(Array(names.prefix(200).enumerated()), id: \.offset) { _, name in
                    Text(name)
                        .font(.caption)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                if names.count > 200 {
                    Text("And \((names.count - 200).formatted()) more.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    /// "12 sec", "1 min 4 sec".
    private static func durationText(_ seconds: Double) -> String {
        Duration.seconds(seconds).formatted(.units(allowed: [.minutes, .seconds], width: .narrow, maximumUnitCount: 2))
    }
}
