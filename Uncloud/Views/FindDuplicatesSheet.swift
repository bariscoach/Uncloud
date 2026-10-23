import AppKit
import QuickLookThumbnailing
import SwiftUI

/// Lists the photos saved more than once in the folder, and moves the extra copies to the Trash after one confirmation.
struct FindDuplicatesSheet: View {
    let cleanup: DuplicateCleanup
    @Environment(ExportModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var isConfirmingRemoval = false

    var body: some View {
        SheetScaffold("Find Duplicates", width: Tokens.Sheet.wide, content: {
            content
                .frame(maxWidth: .infinity, alignment: .leading)
        }, buttons: {
            buttons
        })
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
            Text("\(countText(cleanup.duplicateCount, "copy", "copies")) (\(byteText(cleanup.duplicateBytes))) in “\(destinationName)” go to the Trash. One copy of each photo is kept. Empty the Trash to free the space.")
        }
    }

    private var destinationName: String {
        model.destination?.displayName ?? "your backup folder"
    }

    private func byteText(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    @ViewBuilder
    private var content: some View {
        switch cleanup.state {
        case .ready:
            VStack(alignment: .leading, spacing: 8) {
                Text("Uncloud looks for photos saved more than once in “\(destinationName)”. You choose which copy to keep.")
                    .fixedSize(horizontal: false, vertical: true)
                HelpText("Only your backup folder changes. Your library and iCloud aren’t touched.")
                if model.isExporting {
                    HelpText("Available when the export finishes.")
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
                Label("No duplicates found. Every photo in your backup is saved once.", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .fixedSize(horizontal: false, vertical: true)
                if notChecked > 0 {
                    HelpText("\(Plural.photos(notChecked)) exported by an older version of Uncloud couldn’t be checked.")
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
            if !cleanup.groups.isEmpty || !cleanup.extraCopies.isEmpty {
                Button {
                    isConfirmingRemoval = true
                } label: {
                    Label("Move \(countText(cleanup.duplicateCount, "Copy", "Copies")) to Trash…", systemImage: "trash")
                }
                .buttonStyle(.bordered)
                .disabled(!cleanup.canRemove)
            }

        case .removing:
            Button("Done") {}
                .disabled(true)

        case .finished:
            Button("Show Trash") {
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

/// The summary and the three sections of a finished scan. A section with nothing in it is hidden.
private struct FoundDuplicates: View {
    let cleanup: DuplicateCleanup
    let destinationName: String

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if cleanup.duplicateCount > 0 {
                    Text("\(Text(countText(cleanup.duplicateCount, "copy", "copies")).fontWeight(.semibold)) to move to the Trash, using \(Text(ByteCountFormatter.string(fromByteCount: cleanup.duplicateBytes, countStyle: .file)).fontWeight(.semibold))")
                        .monospacedDigit()
                }

                if !cleanup.extraFolders.isEmpty {
                    ExtraCopiesSection(cleanup: cleanup)
                }
                if !cleanup.groups.isEmpty {
                    SameFolderSection(cleanup: cleanup)
                }
                if !cleanup.sharedItemGroups.isEmpty {
                    SharedItemsSection(cleanup: cleanup)
                }

                if cleanup.notCheckedCount > 0 {
                    HelpText("\(Plural.photos(cleanup.notCheckedCount)) exported by an older version of Uncloud couldn’t be checked.")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 760)
    }
}

/// The heading, explanation and count of one section of the results.
private struct SectionHeading: View {
    let title: String
    let text: String
    let summary: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.headline)
            Text(summary)
                .font(.callout)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            HelpText(text)
        }
    }
}

/// Extra copies of photos saved in a second folder: the same files, left behind by a change of folder layout. Each
/// folder is one row with its include toggle. Removing moves the folder's extra files to the Trash.
private struct ExtraCopiesSection: View {
    let cleanup: DuplicateCleanup

    private var fileCount: Int {
        cleanup.extraCopies.reduce(0) { $0 + $1.mediaPaths.count }
    }

    private var byteCount: Int64 {
        cleanup.extraCopies.reduce(0) { $0 + $1.byteCount }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeading(
                title: "Extra copies of the same photo",
                text: "These files are copies of photos that are already in your backup, often left behind by a change of folder layout.",
                summary: "\(countText(fileCount, "file")) · \(ByteCountFormatter.string(fromByteCount: byteCount, countStyle: .file))"
            )
            List {
                ForEach(cleanup.extraFolders) { folder in
                    Toggle(isOn: Binding(
                        get: { cleanup.isIncluded(folder) },
                        set: { cleanup.setIncluded($0, for: folder) }
                    )) {
                        Text(folderLabel(folder))
                            .monospacedDigit()
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .toggleStyle(.checkbox)
                }
            }
            .listStyle(.inset)
            .frame(height: min(CGFloat(cleanup.extraFolders.count) * 30 + 16, 150))
        }
    }

    private func folderLabel(_ folder: DuplicateCleanup.ExtraFolder) -> String {
        let name = folder.folder.isEmpty ? "In your backup folder" : folder.folder
        return "\(name) · \(countText(folder.fileCount, "file")) · \(ByteCountFormatter.string(fromByteCount: folder.byteCount, countStyle: .file))"
    }
}

/// Groups of identical photos in the same folder, one checkbox and a keeper choice per copy.
private struct SameFolderSection: View {
    let cleanup: DuplicateCleanup

    private var extraCount: Int {
        cleanup.groups.reduce(0) { $0 + $1.duplicates.count }
    }

    private var byteCount: Int64 {
        cleanup.groups.reduce(0) { $0 + $1.duplicateBytes }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeading(
                title: "Copies in the same folder",
                text: "These files are identical and sit in the same folder. You choose which copy to keep.",
                summary: "\(countText(extraCount, "extra copy", "extra copies")) · \(ByteCountFormatter.string(fromByteCount: byteCount, countStyle: .file))"
            )
            List {
                ForEach(cleanup.groups) { group in
                    DuplicateGroupSection(group: group, cleanup: cleanup)
                }
            }
            .listStyle(.inset)
            .frame(height: 260)
        }
    }
}

/// iCloud items that share a file. Nothing is removed here: the extra items are selected in Delete from iCloud.
private struct SharedItemsSection: View {
    let cleanup: DuplicateCleanup
    @Environment(ExportModel.self) private var model
    @Environment(AccountModel.self) private var account
    @Environment(\.dismiss) private var dismiss

    private var canReview: Bool {
        account.allows(.cleanUpICloud) && model.iCloudCleanup != nil && model.source == .iCloud
            && model.iCloudCleanup?.isRunning != true
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                SectionHeading(
                    title: "Saved twice in your iCloud library",
                    text: "Your iCloud library has these photos more than once. Your backup keeps one file. Delete the extra copies from iCloud to save iCloud space.",
                    summary: "\(countText(cleanup.sharedExtraItemCount, "extra item", "extra items")) in iCloud"
                )
                Spacer(minLength: 12)
                Button("Review in Delete from iCloud") {
                    if cleanup.reviewSharedItemsInCleanup() {
                        dismiss()
                    }
                }
                .buttonStyle(.bordered)
                .disabled(!canReview)
            }
            List {
                ForEach(cleanup.sharedItemGroups) { group in
                    VStack(alignment: .leading, spacing: 2) {
                        Text((group.paths.first.map { ($0 as NSString).lastPathComponent }) ?? "Photo")
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text("\(countText(group.ids.count, "item")) share this file · keeps the first one saved")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .listStyle(.inset)
            .frame(height: min(CGFloat(cleanup.sharedItemGroups.count) * 44 + 16, 180))
        }
    }
}

/// One group of identical photos: a checkbox for the whole group, then each copy with its keeper choice.
private struct DuplicateGroupSection: View {
    let group: DuplicateFinder.Group
    let cleanup: DuplicateCleanup

    var body: some View {
        Section {
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
                Button("Keep This", action: onKeep)
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
                HelpText("No copies were moved to the Trash.")
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
        return folder.isEmpty ? "In your backup folder" : folder
    }
}
