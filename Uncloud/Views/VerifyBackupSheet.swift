import SwiftUI

/// Checks the backup's files. Quick Check confirms every file is there and the right size. Full Check reads every file
/// and compares it with its checksum, and continues where it stopped.
struct VerifyBackupSheet: View {
    let verification: BackupVerification
    @Environment(ExportModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var isConfirmingReexport = false

    var body: some View {
        SheetScaffold("Verify Backup", content: {
            content
                .frame(maxWidth: .infinity, alignment: .leading)
        }, buttons: {
            buttons
        })
        .interactiveDismissDisabled(verification.isBusy)
        .confirmationDialog(
            reexportTitle,
            isPresented: $isConfirmingReexport,
            titleVisibility: .visible
        ) {
            Button("Delete and Export Again", role: .destructive) {
                verification.reexport()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Their files in “\(destinationName)” are deleted and exported again from your library. Your library isn’t changed.")
        }
    }

    private var destinationName: String {
        model.destination?.displayName ?? "your backup folder"
    }

    private var reexportCount: Int {
        if case let .finished(summary) = verification.state {
            return summary.reexportIDs.count
        }
        return 0
    }

    private var reexportTitle: String {
        "Export \(countText(reexportCount, "Photo")) Again?"
    }

    @ViewBuilder
    private var content: some View {
        switch verification.state {
        case .ready:
            VStack(alignment: .leading, spacing: 12) {
                Text("Uncloud checks the files in “\(destinationName)” against their export records.")
                    .fixedSize(horizontal: false, vertical: true)
                CheckChoice(
                    title: "Quick Check",
                    detail: "Checks that every file is there and the right size. Takes seconds.",
                    systemImage: "bolt.fill"
                )
                CheckChoice(
                    title: "Full Check",
                    detail: fullDetail,
                    systemImage: "checkmark.shield.fill"
                )
                if case .stale = verification.savedCheck {
                    HelpText(VerifyCheckpoint.restartReason)
                }
                if model.isExporting {
                    HelpText("Available when the export finishes.")
                }
            }

        case let .checking(progress):
            CheckProgress(progress: progress)

        case let .quickFinished(summary):
            QuickResults(summary: summary)

        case let .finished(summary):
            VStack(alignment: .leading, spacing: 12) {
                if summary.resumedFromCheckpoint {
                    HelpText("Continued from where it stopped.")
                }
                if let reason = summary.restartReason {
                    HelpText(reason)
                }
                VerifyResults(summary: summary)
            }

        case let .failed(message):
            Label(message, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.red)

        case .reexporting:
            VStack(alignment: .leading, spacing: 8) {
                ProgressView()
                    .progressViewStyle(.linear)
                Text("Removing damaged files…")
                    .foregroundStyle(.secondary)
            }

        case let .reexported(message, isProblem):
            Label(message, systemImage: isProblem ? "exclamationmark.triangle" : "checkmark.circle.fill")
                .foregroundStyle(isProblem ? .orange : .green)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The Full Check description. With a checkpoint, it says the check continues.
    private var fullDetail: String {
        switch verification.savedCheck {
        case let .resumable(percentDone, _):
            "Continues where it stopped, \(percentDone)% done. Reads the files and compares them with their checksums."
        default:
            "Reads every file and compares it with its checksum. Takes hours on a large backup. You can stop and continue later."
        }
    }

    @ViewBuilder
    private var buttons: some View {
        switch verification.state {
        case .ready:
            Button("Cancel") {
                dismiss()
            }
            .keyboardShortcut(.cancelAction)
            if verification.canContinueFullCheck {
                Button("Start Over") {
                    verification.startFullCheckOver()
                }
                .disabled(!verification.canStart)
            }
            Button(verification.canContinueFullCheck ? "Continue Full Check" : "Full Check") {
                verification.continueFullCheck()
            }
            .disabled(!verification.canStart)
            Button("Quick Check") {
                verification.start(.quick)
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(!verification.canStart)

        case .checking:
            Button("Stop") {
                verification.cancel()
            }
            .keyboardShortcut(.cancelAction)

        case .reexporting:
            Button("Done") {}
                .disabled(true)

        case let .quickFinished(summary):
            if !summary.report.problemItemIDs.isEmpty {
                Button("Check These Fully") {
                    verification.checkProblemsFully()
                }
                .disabled(!verification.canStart)
            }
            Button("Done") {
                dismiss()
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)

        case .finished:
            if reexportCount > 0 {
                Button("Export \(countText(reexportCount, "Photo")) Again…") {
                    isConfirmingReexport = true
                }
                .disabled(!verification.canReexport)
            }
            Button("Done") {
                dismiss()
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)

        case .failed:
            Button("Try Again") {
                verification.start(.full)
            }
            .disabled(!verification.canStart)
            Button("Done") {
                dismiss()
            }
            .keyboardShortcut(.defaultAction)

        case .reexported:
            Button("Done") {
                dismiss()
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
        }
    }
}

/// One of the two ways to check, with a plain-language line about what it does.
private struct CheckChoice: View {
    let title: String
    let detail: String
    let systemImage: String

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                HelpText(detail)
            }
        } icon: {
            Image(systemName: systemImage)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Progress of a running check: files, data read and time left.
private struct CheckProgress: View {
    let progress: BackupVerification.Progress

    var body: some View {
        // The estimate changes with the clock, so the line is redrawn each second.
        TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(alignment: .leading, spacing: 8) {
                switch progress.check {
                case .quick:
                    ProgressView()
                        .progressViewStyle(.linear)
                    Text("Checking that every file is there…")
                        .foregroundStyle(.secondary)

                case .full, .items:
                    if progress.total > 0 {
                        ProgressView(value: Double(progress.done), total: Double(progress.total))
                        Text("Checking \(progress.done.formatted()) of \(progress.total.formatted()) files · \(progress.bytesRead.formatted(.byteCount(style: .file))) read")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                        Text(timeLeftText(now: context.date))
                            .foregroundStyle(.secondary)
                    } else {
                        ProgressView()
                            .progressViewStyle(.linear)
                        Text("Getting ready…")
                            .foregroundStyle(.secondary)
                    }
                    if progress.baseline > 0 {
                        HelpText("Continuing from where it stopped.")
                    }
                }
            }
        }
    }

    private func timeLeftText(now: Date) -> String {
        guard let seconds = progress.secondsRemaining(now: now) else {
            return "Working out how long is left…"
        }
        return VerifyEstimate.timeLeftText(seconds: seconds)
    }
}

/// What a quick check found.
private struct QuickResults: View {
    let summary: BackupVerification.QuickSummary

    var body: some View {
        let report = summary.report
        VStack(alignment: .leading, spacing: 12) {
            HelpText("Checked \(countText(report.checkedFiles, "file")) in \(secondsText(report.seconds)).")

            if report.problemItemIDs.isEmpty {
                VerifyFinding(
                    title: "Everything is there",
                    detail: "Every file is present and the right size.",
                    systemImage: "checkmark.circle.fill",
                    color: .green
                )
                HelpText("Quick Check doesn’t open the files. Full Check reads them and confirms they aren’t damaged.")
            } else {
                if !report.missingFiles.isEmpty {
                    VerifyFinding(
                        title: "\(countText(report.missingFiles.count, "file")) missing",
                        detail: report.missingFiles.count == 1
                            ? "It’s recorded in the export but isn’t in the backup folder."
                            : "They’re recorded in the export but aren’t in the backup folder.",
                        systemImage: "xmark.octagon.fill",
                        color: .red
                    )
                }
                if !report.emptyFiles.isEmpty {
                    VerifyFinding(
                        title: "\(countText(report.emptyFiles.count, "file")) empty",
                        detail: report.emptyFiles.count == 1
                            ? "It has no content, so it can’t be right."
                            : "They have no content, so they can’t be right.",
                        systemImage: "xmark.octagon.fill",
                        color: .red
                    )
                }
                if !report.changedFiles.isEmpty {
                    VerifyFinding(
                        title: "\(countText(report.changedFiles.count, "file")) changed since export",
                        detail: report.changedFiles.count == 1
                            ? "Its size or date no longer matches the export record."
                            : "Their size or date no longer matches the export record.",
                        systemImage: "exclamationmark.triangle.fill",
                        color: .orange
                    )
                }
                if !report.sizeMismatchItemIDs.isEmpty {
                    VerifyFinding(
                        title: "\(countText(report.sizeMismatchItemIDs.count, "photo")) may be incomplete",
                        detail: report.sizeMismatchItemIDs.count == 1
                            ? "Its files add up to less than the library recorded. A download may have been cut short."
                            : "Their files add up to less than the library recorded. A download may have been cut short.",
                        systemImage: "exclamationmark.triangle.fill",
                        color: .orange
                    )
                }
                HelpText("Check These Fully reads only these \(countText(report.problemItemIDs.count, "photo")) and confirms whether they’re damaged.")
                AffectedFileList(paths: summary.affectedFiles, more: summary.affectedFileCount - summary.affectedFiles.count)
            }
        }
    }

    private func secondsText(_ seconds: Double) -> String {
        seconds < 1 ? "under a second" : "\(Int(seconds.rounded())) seconds"
    }
}

/// The plain-language findings of a full check.
private struct VerifyResults: View {
    let summary: BackupVerification.Summary

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if summary.verifiedCount + summary.damagedCount + summary.unverifiableCount == 0 {
                HelpText("Nothing to verify yet.")
            }

            if summary.verifiedCount > 0 {
                VerifyFinding(
                    title: "\(countText(summary.verifiedCount, "Photo")) verified",
                    detail: "Every file is intact.",
                    systemImage: "checkmark.circle.fill",
                    color: .green
                )
            }

            if summary.damagedCount > 0 {
                VerifyFinding(
                    title: "\(countText(summary.damagedCount, "Photo")) damaged or missing",
                    detail: "\(countText(summary.affectedFileCount, "file")) are missing or don’t match the original.",
                    systemImage: "xmark.octagon.fill",
                    color: .red
                )
                AffectedFileList(paths: summary.affectedFiles, more: summary.affectedFileCount - summary.affectedFiles.count)
            }

            if summary.unverifiableCount > 0 {
                VerifyFinding(
                    title: "\(countText(summary.unverifiableCount, "Photo")) can’t be verified",
                    detail: "Exported by an older version of Uncloud. They look fine, and can be verified once they’re exported again.",
                    systemImage: "questionmark.circle.fill",
                    color: .orange
                )
            }

            if let notBackedUp = summary.notBackedUpCount, notBackedUp > 0 {
                VerifyFinding(
                    title: "\(countText(notBackedUp, "Photo")) not backed up yet",
                    detail: "They’re in your library but not in this backup. Export to add them.",
                    systemImage: "info.circle.fill",
                    color: .secondary
                )
            }

            if summary.notInLibraryCount > 0 {
                let count = summary.notInLibraryCount
                HelpText("\(count.formatted()) of these \(count == 1 ? "is" : "are") no longer in your library, so \(count == 1 ? "it" : "they") can’t be exported again. \(count == 1 ? "Its files were" : "Their files were") left as they are.")
            }
        }
    }
}

/// A headline, a line of detail and an icon. Used for every result.
private struct VerifyFinding: View {
    let title: String
    let detail: String
    let systemImage: String
    let color: Color

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                HelpText(detail)
            }
        } icon: {
            Image(systemName: systemImage)
                .foregroundStyle(color)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Up to `AffectedFileLimit` file paths, with a count of the rest.
private struct AffectedFileList: View {
    let paths: [String]
    let more: Int

    var body: some View {
        GroupBox {
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(paths, id: \.self) { path in
                        Text(path)
                            .font(.callout)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    if more > 0 {
                        Text("and \(countText(more, "more file", "more files"))")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
            }
            .frame(maxHeight: 140)
        }
    }
}
