import AppKit
import QuickLookThumbnailing
import SwiftUI

/// Lists the items saved more than once in the folder, and moves the extra copies to the Trash after one confirmation.
struct FindDuplicatesSheet: View {
    let cleanup: DuplicateCleanup
    @Environment(ExportModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var isConfirmingRemoval = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Find Duplicates")
                .font(.title2.weight(.semibold))

            content
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack {
                Spacer()
                buttons
            }
            .controlSize(.large)
        }
        .padding(Tokens.Sheet.padding)
        .frame(width: Tokens.Sheet.wide)
        .interactiveDismissDisabled(cleanup.isBusy)
        .confirmationDialog(
            "Move \(countText(cleanup.duplicateCount, "Copy", "Copies")) to the Trash?",
            isPresented: $isConfirmingRemoval,
            titleVisibility: .visible
        ) {
            Button("Move \(countText(cleanup.duplicateCount, "Copy", "Copies")) to Trash", role: .destructive) {
                cleanup.removeCopies()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Uncloud will move \(countText(cleanup.duplicateCount, "copy", "copies")) (\(byteText(cleanup.duplicateBytes))) from “\(destinationName)” to the Trash. One copy of each is kept. Your photo library isn’t changed. Empty the Trash to free the space.")
        }
    }

    private var destinationName: String {
        model.destination?.displayName ?? "the backup folder"
    }

    private func byteText(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    @ViewBuilder
    private var content: some View {
        switch cleanup.state {
        case .ready:
            VStack(alignment: .leading, spacing: 8) {
                Text("Uncloud compares the files in “\(destinationName)” using the checksums saved when they were exported. Items saved more than once are listed, and you choose which copy to keep.")
                    .fixedSize(horizontal: false, vertical: true)
                Text("Only the folder changes. Your photo library and iCloud aren’t touched.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if model.isExporting {
                    Label("Wait for the export to finish before looking for duplicates.", systemImage: "info.circle")
                        .foregroundStyle(.secondary)
                }
            }

        case let .scanning(done, total):
            VStack(alignment: .leading, spacing: 8) {
                if total > 0 {
                    ProgressView(value: Double(done), total: Double(total))
                    Text("Reading \(done.formatted()) of \(total.formatted()) files…")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                } else {
                    ProgressView()
                        .progressViewStyle(.linear)
                    Text("Getting ready…")
                        .foregroundStyle(.secondary)
                }
            }

        case let .noneFound(notChecked):
            VStack(alignment: .leading, spacing: 8) {
                Label("No duplicates found", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                if notChecked > 0 {
                    Text("\(countText(notChecked, "item")) couldn’t be checked because \(notChecked == 1 ? "it was" : "they were") saved by an older version of Uncloud.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

        case .found:
            FoundDuplicates(cleanup: cleanup, destinationName: destinationName)

        case let .removing(done, total):
            VStack(alignment: .leading, spacing: 8) {
                ProgressView(value: Double(done), total: Double(max(total, 1)))
                Text("Moving \(done.formatted()) of \(total.formatted()) copies to the Trash…")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }

        case let .finished(summary):
            RemovalResults(result: summary.result)

        case let .failed(message):
            Label(message, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var buttons: some View {
        switch cleanup.state {
        case .ready:
            Button("Cancel") {
                dismiss()
            }
            .keyboardShortcut(.cancelAction)
            Button("Find Duplicates") {
                cleanup.start()
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(!cleanup.canStart)

        case .scanning:
            Button("Cancel") {
                cleanup.cancel()
            }
            .keyboardShortcut(.cancelAction)

        case .found:
            Button("Done") {
                dismiss()
            }
            .keyboardShortcut(.cancelAction)
            // No default shortcut: Return shouldn't start a removal. It still asks first.
            // Not the prominent button: removing copies is the one thing this sheet doesn't want the user to hit by default.
            Button {
                isConfirmingRemoval = true
            } label: {
                Label("Move \(countText(cleanup.duplicateCount, "Copy", "Copies")) to Trash…", systemImage: "trash")
            }
            .buttonStyle(.bordered)
            .disabled(!cleanup.canRemove)

        case .removing:
            Button("Done") {}
                .disabled(true)

        case .finished:
            Button("Open Trash") {
                openTrash()
            }
            Button("Done") {
                dismiss()
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)

        case .noneFound:
            Button("Done") {
                dismiss()
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)

        case .failed:
            Button("Try Again") {
                cleanup.start()
            }
            .disabled(!cleanup.canStart)
            Button("Done") {
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
        }
    }

    private func openTrash() {
        guard let trash = FileManager.default.urls(for: .trashDirectory, in: .userDomainMask).first else { return }
        NSWorkspace.shared.open(trash)
    }
}

/// The summary and the list of groups in a finished scan.
private struct FoundDuplicates: View {
    let cleanup: DuplicateCleanup
    let destinationName: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("\(Text(countText(cleanup.duplicateCount, "duplicate copy", "duplicate copies")).fontWeight(.semibold)) using \(Text(ByteCountFormatter.string(fromByteCount: cleanup.duplicateBytes, countStyle: .file)).fontWeight(.semibold))")
                .monospacedDigit()

            if cleanup.notCheckedCount > 0 {
                Text("\(countText(cleanup.notCheckedCount, "item")) couldn’t be checked because \(cleanup.notCheckedCount == 1 ? "it was" : "they were") saved by an older version of Uncloud.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(cleanup.groups) { group in
                        DuplicateGroupView(group: group, cleanup: cleanup)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, 8)
            }
            .frame(maxHeight: 340)
        }
    }
}

/// One group of identical items: a checkbox for the whole group, then each copy with its keeper choice.
private struct DuplicateGroupView: View {
    let group: DuplicateFinder.Group
    let cleanup: DuplicateCleanup

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Toggle(isOn: Binding(
                    get: { cleanup.isIncluded(group) },
                    set: { cleanup.setIncluded($0, for: group) }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(group.keeper.fileName)
                            .font(.headline)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text("\(countText(group.duplicates.count, "extra copy", "extra copies")) · \(ByteCountFormatter.string(fromByteCount: group.duplicateBytes, countStyle: .file))")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                .toggleStyle(.checkbox)

                ForEach(group.copies) { copy in
                    CopyRow(
                        copy: copy,
                        isKept: copy.id == group.keeperID,
                        destination: cleanup.scannedDestination,
                        onKeep: { cleanup.setKeeper(copy.id, in: group) }
                    )
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// A copy's thumbnail, name, folder and size, with its keep status and a choice to keep it instead.
private struct CopyRow: View {
    let copy: DuplicateFinder.Copy
    let isKept: Bool
    let destination: URL?
    let onKeep: () -> Void

    private var fileURL: URL? {
        destination?.appending(path: copy.mediaPaths[0])
    }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            if let fileURL {
                FileThumbnail(url: fileURL)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(copy.fileName)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(copy.folderName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(ByteCountFormatter.string(fromByteCount: copy.byteCount, countStyle: .file))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            Spacer(minLength: 8)

            if isKept {
                Label("Keep", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                Label("Move to Trash", systemImage: "trash")
                    .foregroundStyle(.secondary)
                    .labelStyle(.titleAndIcon)
                Button("Keep This One", action: onKeep)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .contextMenu {
            if let fileURL {
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([fileURL])
                }
            }
        }
    }
}

/// A small Quick Look thumbnail, made when the row appears.
private struct FileThumbnail: View {
    let url: URL
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: "photo")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 44, height: 44)
        // Decorative next to the file name, which is what VoiceOver reads.
        .accessibilityHidden(true)
        .task(id: url) {
            image = await Self.thumbnail(for: url)
        }
    }

    @MainActor
    private static func thumbnail(for url: URL) async -> NSImage? {
        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: CGSize(width: 44, height: 44),
            scale: 2,
            representationTypes: .thumbnail
        )
        guard let representation = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) else {
            return nil
        }
        return NSImage(cgImage: representation.cgImage, size: .zero)
    }
}

/// What a finished removal did, in plain language.
private struct RemovalResults: View {
    let result: DuplicateFinder.RemovalResult

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if result.removedCopies > 0 {
                Label(
                    "Moved \(countText(result.removedCopies, "copy", "copies")) (\(ByteCountFormatter.string(fromByteCount: result.removedBytes, countStyle: .file))) to the Trash.",
                    systemImage: "checkmark.circle.fill"
                )
                .foregroundStyle(.green)
                .fixedSize(horizontal: false, vertical: true)
            } else {
                Label("No copies were moved to the Trash.", systemImage: "info.circle")
                    .foregroundStyle(.secondary)
            }

            let kept = result.skippedCopies + result.failedCopies
            if kept > 0 {
                Label(
                    "\(countText(kept, "copy", "copies")) \(kept == 1 ? "was" : "were") left in place because \(kept == 1 ? "it changed" : "they changed") or couldn’t be moved.",
                    systemImage: "exclamationmark.triangle"
                )
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private extension DuplicateFinder.Copy {
    var fileName: String {
        (mediaPaths[0] as NSString).lastPathComponent
    }

    /// The folder the file is in, relative to the destination; empty for files at the top.
    var folderName: String {
        let folder = (mediaPaths[0] as NSString).deletingLastPathComponent
        return folder.isEmpty ? "In the folder you chose" : folder
    }
}
