import SwiftUI

/// Checks every exported file against its checksum and reports what it found.
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
            Text("Uncloud reads every file in “\(destinationName)” and checks it’s identical to when it was exported. Large backups take a while.")
                .fixedSize(horizontal: false, vertical: true)
            if model.isExporting {
                HelpText("Available when the export finishes.")
            }

        case let .checking(done, total):
            VStack(alignment: .leading, spacing: 8) {
                if total > 0 {
                    ProgressView(value: Double(done), total: Double(total))
                    Text("Checking \(done.formatted()) of \(total.formatted()) files…")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                } else {
                    ProgressView()
                        .progressViewStyle(.linear)
                    Text("Getting ready…")
                        .foregroundStyle(.secondary)
                }
            }

        case let .finished(summary):
            VerifyResults(summary: summary)

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

    @ViewBuilder
    private var buttons: some View {
        switch verification.state {
        case .ready:
            Button("Cancel") {
                dismiss()
            }
            .keyboardShortcut(.cancelAction)
            Button("Verify") {
                verification.start()
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(!verification.canStart)

        case .checking:
            Button("Cancel") {
                verification.cancel()
            }
            .keyboardShortcut(.cancelAction)

        case .reexporting:
            Button("Done") {}
                .disabled(true)

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
                verification.start()
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

/// The plain-language findings of a check.
private struct VerifyResults: View {
    let summary: BackupVerification.Summary

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if summary.verifiedCount + summary.damagedCount + summary.unverifiableCount == 0 {
                HelpText("Nothing to verify yet.")
            }

            if summary.verifiedCount > 0 {
                finding(
                    "\(countText(summary.verifiedCount, "Photo")) verified",
                    detail: "Every file is intact.",
                    systemImage: "checkmark.circle.fill",
                    color: .green
                )
            }

            if summary.damagedCount > 0 {
                finding(
                    "\(countText(summary.damagedCount, "Photo")) damaged or missing",
                    detail: "\(countText(summary.affectedFileCount, "file")) are missing or don’t match the original.",
                    systemImage: "xmark.octagon.fill",
                    color: .red
                )
                affectedFiles
            }

            if summary.unverifiableCount > 0 {
                finding(
                    "\(countText(summary.unverifiableCount, "Photo")) can’t be verified",
                    detail: "Exported by an older version of Uncloud. They look fine, and can be verified once they’re exported again.",
                    systemImage: "questionmark.circle.fill",
                    color: .orange
                )
            }

            if let notBackedUp = summary.notBackedUpCount, notBackedUp > 0 {
                finding(
                    "\(countText(notBackedUp, "Photo")) not backed up yet",
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

    private func finding(_ title: String, detail: String, systemImage: String, color: Color) -> some View {
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

    private var affectedFiles: some View {
        GroupBox {
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(summary.affectedFiles, id: \.self) { path in
                        Text(path)
                            .font(.callout)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    let more = summary.affectedFileCount - summary.affectedFiles.count
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
