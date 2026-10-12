import SwiftUI

/// Checks every exported file against its checksum and reports what it found.
struct VerifyBackupSheet: View {
    let verification: BackupVerification
    @Environment(ExportModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var isConfirmingReexport = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Verify Backup")
                .font(.title2.weight(.semibold))

            content
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack {
                Spacer()
                buttons
            }
            .controlSize(.large)
        }
        .padding(20)
        .frame(width: 500)
        .interactiveDismissDisabled(verification.isBusy)
        .confirmationDialog(
            reexportTitle,
            isPresented: $isConfirmingReexport,
            titleVisibility: .visible
        ) {
            Button("Delete Files and Export Again", role: .destructive) {
                verification.reexport()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Uncloud will delete the files these items still have in “\(destinationName)”, then copy them again from your photo library. Your photo library isn’t changed.")
        }
    }

    private var destinationName: String {
        model.destination?.displayName ?? "the backup folder"
    }

    private var reexportCount: Int {
        if case let .finished(summary) = verification.state {
            return summary.reexportIDs.count
        }
        return 0
    }

    private var reexportTitle: String {
        "Export \(countText(reexportCount, "item")) again?"
    }

    @ViewBuilder
    private var content: some View {
        switch verification.state {
        case .ready:
            Text("Uncloud will read every file in “\(destinationName)” and compare it with the checksum saved when it was exported. This can take a while for a large backup.")
                .fixedSize(horizontal: false, vertical: true)
            if model.isExporting {
                Label("Wait for the export to finish before checking the backup.", systemImage: "info.circle")
                    .foregroundStyle(.secondary)
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
                Text("Removing old files…")
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
            Button("Check Backup") {
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
                Button("Re-export \(countText(reexportCount, "Item"))…") {
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
                Label("There’s nothing in this backup yet.", systemImage: "info.circle")
            }

            if summary.verifiedCount > 0 {
                finding(
                    "\(countText(summary.verifiedCount, "item")) verified",
                    detail: "Every file is present and matches the original.",
                    systemImage: "checkmark.circle.fill",
                    color: .green
                )
            }

            if summary.damagedCount > 0 {
                finding(
                    "\(countText(summary.damagedCount, "item")) damaged or missing",
                    detail: "\(countText(summary.affectedFileCount, "file")) are missing or don’t match the original.",
                    systemImage: "xmark.octagon.fill",
                    color: .red
                )
                affectedFiles
            }

            if summary.unverifiableCount > 0 {
                finding(
                    "\(countText(summary.unverifiableCount, "item")) can’t be checked",
                    detail: "These were exported by an earlier version of Uncloud that didn’t save checksums. Their files are there and look fine, but they can’t be checked until they’re exported again.",
                    systemImage: "questionmark.circle.fill",
                    color: .orange
                )
            }

            if let notBackedUp = summary.notBackedUpCount, notBackedUp > 0 {
                finding(
                    "\(countText(notBackedUp, "item")) not backed up yet",
                    detail: "These are in your photo library but not in this backup. Choose Export or Resume to copy them.",
                    systemImage: "info.circle.fill",
                    color: .secondary
                )
            }

            if summary.notInLibraryCount > 0 {
                Text("\(countText(summary.notInLibraryCount, "item")) with problems \(summary.notInLibraryCount == 1 ? "is" : "are") no longer in your photo library, so \(summary.notInLibraryCount == 1 ? "it" : "they") can’t be exported again. \(summary.notInLibraryCount == 1 ? "Its files were" : "Their files were") left as they are.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func finding(_ title: String, detail: String, systemImage: String, color: Color) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
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
