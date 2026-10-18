import SwiftUI

/// The Backup pane's drive row: what the drive already holds for the current selection, when it was last
/// checked, and Check Drive. While a check runs it shows progress and Cancel instead.
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
            HStack(spacing: 12) {
                ProgressView()
                    .controlSize(.small)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Checking your drive…")
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
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    if let summary {
                        Text(summary.prefix(1).uppercased() + summary.dropFirst())
                            .monospacedDigit()
                    } else {
                        Text("Not checked yet")
                            .foregroundStyle(.secondary)
                    }
                    if let lastChecked {
                        Text("Last checked \(ExportHistoryFormat.when(lastChecked))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button("Check Drive", action: onCheck)
                    .disabled(!canCheck)
                    .accessibilityHint("Finds missing and damaged files. Damaged files are moved aside, never deleted.")
            }
        }
    }
}

/// Lets `.sheet(item:)` present a check's report. A report is presented once: dismissing the sheet clears
/// `ExportModel.lastManualDriveCheck`, so two checks never share an identity.
extension DriveCheckReport: Identifiable {
    var id: String { "\(filesListed)-\(onDrive)-\(seconds)" }
}

/// The result of a manual Check Drive, in plain language: what was missing or damaged, what was done about
/// it, and what was only counted. Presented by the Backup pane when a manual check finishes.
struct CheckDriveResultsSheet: View {
    let report: DriveCheckReport
    /// The library the drive holds: sets "downloaded" (iCloud) or "exported" (Photos library).
    let source: LibrarySource
    /// Opens `.photo-export/set-aside/<folder>` on the drive in Finder. Nil hides the button.
    let onShowSetAside: (() -> Void)?

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    LabeledContent("Checked") {
                        Text("\(report.filesListed.formatted()) files in \(Self.durationText(report.seconds))")
                            .monospacedDigit()
                    }
                    LabeledContent("Scope") {
                        Text(report.mode == .full ? "Every file" : "Folders that changed")
                    }
                    LabeledContent("Status") {
                        Text(report.isApproximate
                             ? "About \(report.onDrive.formatted()) already on this drive · about \(report.toGo.formatted()) to go"
                             : "\(report.onDrive.formatted()) already on this drive · \(report.toGo.formatted()) to go")
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
                            Text("Everything on the drive is in order.")
                        } icon: {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        }
                    }
                }

                if report.missingItems > 0 {
                    Section {
                        Label {
                            Text("\(report.missingItems.formatted()) \(report.missingItems == 1 ? "item is" : "items are") missing")
                        } icon: {
                            Image(systemName: "questionmark.folder")
                                .foregroundStyle(.orange)
                        }
                        Text("They’ll be \(source.copiedVerb) again on the next export.")
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
                            Text("\(report.damagedFiles.count.formatted()) \(report.damagedFiles.count == 1 ? "file is" : "files are") empty or changed size")
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.red)
                        }
                        Text(damagedNote)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if let onShowSetAside, !report.setAsideFiles.isEmpty {
                            Button("Show Set-Aside Folder", action: onShowSetAside)
                                .accessibilityHint("Opens the folder that holds the damaged files.")
                        }
                        fileList(report.damagedFiles, title: "Show Damaged Files")
                        if !report.setAsideFailures.isEmpty {
                            Label {
                                Text("\(report.setAsideFailures.count.formatted()) couldn’t be moved aside. \(report.setAsideFailures.count == 1 ? "It stays" : "They stay") where \(report.setAsideFailures.count == 1 ? "it is" : "they are"), isn’t \(source.copiedVerb) again, and is checked again next time.")
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
                            Text("\(report.changedFiles.count.formatted()) \(report.changedFiles.count == 1 ? "file" : "files") changed size")
                        } icon: {
                            Image(systemName: "doc.badge.ellipsis")
                                .foregroundStyle(.secondary)
                        }
                        Text("Uncloud can’t tell it saved these, so it left them as they are.")
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
                            Text("\(report.registeredFiles.count.formatted()) \(report.registeredFiles.count == 1 ? "file was" : "files were") recorded")
                        } icon: {
                            Image(systemName: "checkmark.circle")
                                .foregroundStyle(.green)
                        }
                        Text("These were at the paths iCloud uses, with no record. Their checksums are added during the next export.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        fileList(report.registeredFiles, title: "Show Recorded Files")
                    } header: {
                        Text("Registered")
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
                            Text("\(report.partialFiles.formatted()) unfinished \(report.partialFiles == 1 ? "download" : "downloads"), \(report.partialItems.formatted()) partly downloaded \(report.partialItems == 1 ? "item" : "items")")
                        } icon: {
                            Image(systemName: "arrow.down.circle.dotted")
                                .foregroundStyle(.secondary)
                        }
                        Text("Partial downloads don’t count as on the drive, so they’ll be downloaded again.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } header: {
                        Text("Partial Downloads")
                    }
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Spacer()
                Button("Done") {
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
            .padding(Tokens.Sheet.padding)
        }
        .frame(minWidth: 480, idealWidth: 520, minHeight: 440, idealHeight: 560)
    }

    private var damagedNote: String {
        if report.setAsideFiles.isEmpty {
            return report.setAsideFailures.isEmpty
                ? "They’ll be moved aside and \(source.copiedVerb) again when you export or choose Check Drive."
                : "Nothing was moved."
        }
        return "Moved to the set-aside folder, never deleted. Their items will be \(source.copiedVerb) again."
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
