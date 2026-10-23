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
        Group {
            if case .found = cleanup.state {
                DuplicatesLibrary(cleanup: cleanup, destinationName: destinationName) {
                    isConfirmingRemoval = true
                }
            } else {
                SheetScaffold("Find Duplicates", width: Tokens.Sheet.wide, content: {
                    content
                        .frame(maxWidth: .infinity, alignment: .leading)
                }, buttons: {
                    buttons
                })
            }
        }
        .interactiveDismissDisabled(cleanup.isBusy)
        .alert(DuplicateWording.confirmationTitle(copies: cleanup.duplicateCount), isPresented: $isConfirmingRemoval) {
            // Cancel is the default and Esc triggers it. Return doesn't start a removal.
            Button("Move to Trash", role: .destructive) {
                cleanup.removeCopies()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(DuplicateWording.confirmationMessage(
                copies: cleanup.duplicateCount, bytes: cleanup.duplicateBytes, volume: destinationName
            ))
        }
    }

    private var destinationName: String {
        model.destination?.displayName ?? "your backup folder"
    }

    @ViewBuilder
    private var content: some View {
        switch cleanup.state {
        case .ready:
            VStack(alignment: .leading, spacing: 8) {
                Text("Uncloud looks for photos saved more than once in “\(destinationName)”. It keeps the first copy of each photo and moves the others to the Trash.")
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
            // The library draws its own header and footer.
            EmptyView()

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
            // The library has its own footer, with the removal.
            EmptyView()

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

/// The duplicates library of a finished scan: a header, one row per photo with its original and copies, and a footer
/// with the removal. The iCloud notice sits above the photos.
private struct DuplicatesLibrary: View {
    let cleanup: DuplicateCleanup
    let destinationName: String
    let onRemove: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let totals = cleanup.library.totals()
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Duplicates")
                    .font(.title2.weight(.semibold))
                // The same count as the footer and the confirmation: the copies that go, not the originals that stay.
                Text("\(countText(totals.copies, "duplicate")) of \(countText(totals.photos, "photo")) · \(DuplicateWording.byteText(totals.bytes)) to free")
                    .font(.callout.weight(.medium))
                    .monospacedDigit()
                HelpText("Uncloud keeps the original of each photo, the first copy it saved, and removes the other copies.")
            }
            .padding(.horizontal, Tokens.Sheet.padding)
            .padding(.top, Tokens.Sheet.padding)
            .padding(.bottom, 14)
            .frame(maxWidth: .infinity, alignment: .leading)

            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 22) {
                    if cleanup.sharedExtraItemCount > 0 {
                        SharedItemsNotice(cleanup: cleanup)
                    }
                    ForEach(cleanup.library.photos) { photo in
                        PhotoRow(photo: photo, cleanup: cleanup, destination: cleanup.scannedDestination)
                    }
                }
                .padding(Tokens.Sheet.padding)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: .infinity)

            Divider()

            HStack(spacing: Tokens.Space.s) {
                Text("\(countText(cleanup.duplicateCount, "copy", "copies")) selected for removal · \(DuplicateWording.byteText(cleanup.duplicateBytes))")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Spacer()
                Button("Close") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                // No default shortcut: Return shouldn't start a removal. It still asks first.
                Button("Remove Duplicates…") {
                    onRemove()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!cleanup.canRemove)
            }
            .controlSize(Tokens.Sheet.footerControlSize)
            .padding(Tokens.Sheet.padding)
        }
        .frame(minWidth: 720, idealWidth: 920, maxWidth: .infinity, minHeight: 520, idealHeight: 660, maxHeight: .infinity)
    }
}

/// The iCloud items saved twice. Nothing is removed here: the extra items are selected in Delete from iCloud.
private struct SharedItemsNotice: View {
    let cleanup: DuplicateCleanup
    @Environment(ExportModel.self) private var model
    @Environment(AccountModel.self) private var account
    @Environment(\.dismiss) private var dismiss

    private var canReview: Bool {
        account.allows(.cleanUpICloud) && model.iCloudCleanup != nil && model.source == .iCloud
            && model.iCloudCleanup?.isRunning != true
    }

    private var sentence: String {
        let count = cleanup.sharedExtraItemCount
        let saved = count == 1 ? "1 photo is saved" : "\(count.formatted()) photos are saved"
        return "\(saved) twice in your iCloud library. Your drive keeps one file for each."
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Label {
                Text(sentence)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "icloud")
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            Button("Review in Delete from iCloud") {
                if cleanup.reviewSharedItemsInCleanup() {
                    dismiss()
                }
            }
            .buttonStyle(.bordered)
            .disabled(!canReview)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
    }
}

/// One photo: its name and copy count, then a row of tiles with the original first.
private struct PhotoRow: View {
    let photo: DuplicateLibrary.Photo
    let cleanup: DuplicateCleanup
    let destination: URL?

    private var isIncluded: Bool {
        cleanup.isIncluded(photo)
    }

    private var summary: String {
        let copies = countText(photo.copies.count + 1, "copy", "copies")
        return isIncluded
            ? "\(copies) · \(DuplicateWording.byteText(photo.copyBytes)) to free"
            : "\(copies) · keeping all"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(photo.original.fileName)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                Text(summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 12) {
                    PhotoTile(tile: photo.original, role: .original, destination: destination)
                    ForEach(photo.copies) { copy in
                        PhotoTile(tile: copy, role: isIncluded ? .removed : .kept, destination: destination)
                    }
                }
                .padding(.bottom, 4)
            }
            .scrollIndicators(.automatic)
        }
        .contextMenu {
            Button(isIncluded ? "Keep All Copies of This Photo" : "Remove Copies of This Photo") {
                cleanup.setIncluded(!isIncluded, for: photo)
            }
            if let destination {
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([destination.appending(path: photo.original.path)])
                }
            }
        }
    }
}

/// How a tile is labelled: the original is kept; a copy is removed, or kept when the user keeps the whole photo.
private enum TileRole {
    case original
    case removed
    case kept
}

/// One saved file: its thumbnail, what happens to it, and the folder it's in.
private struct PhotoTile: View {
    let tile: DuplicateLibrary.Tile
    let role: TileRole
    /// The destination the scan ran in, so the thumbnails are the files that were scanned.
    let destination: URL?

    private static let size: CGFloat = 140

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .bottomLeading) {
                RoundedRectangle(cornerRadius: 8)
                    .fill(.quaternary)
                if let url = fileURL {
                    FileThumbnail(url: url, size: Self.size)
                        .frame(width: Self.size, height: Self.size)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .opacity(role == .removed ? 0.6 : 1)
                }
                if tile.isVideo {
                    Image(systemName: "video.fill")
                        .font(.caption)
                        .foregroundStyle(.white)
                        .padding(6)
                        .background(.black.opacity(0.55), in: Capsule())
                        .padding(6)
                }
            }
            .frame(width: Self.size, height: Self.size)

            badge
            Text(tile.folder.isEmpty ? "All in One Folder" : tile.folder)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: Self.size, alignment: .leading)
        }
        .frame(width: Self.size, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(tile.fileName), \(badgeText), \(tile.folder.isEmpty ? "All in One Folder" : tile.folder)")
    }

    private var fileURL: URL? {
        destination?.appending(path: tile.path)
    }

    private var badge: some View {
        Label(badgeText, systemImage: badgeIcon)
            .font(.caption.weight(.semibold))
            .foregroundStyle(badgeColor)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(badgeColor.opacity(0.14), in: Capsule())
    }

    private var badgeText: String {
        switch role {
        case .original: "Original · Kept"
        case .removed: "Copy · Removed"
        case .kept: "Copy · Kept"
        }
    }

    private var badgeIcon: String {
        switch role {
        case .original: "checkmark.seal.fill"
        case .removed: "trash"
        case .kept: "checkmark.circle.fill"
        }
    }

    private var badgeColor: Color {
        switch role {
        case .original, .kept: .green
        case .removed: .red
        }
    }
}

/// What a finished removal did, in plain language.
private struct RemovalResults: View {
    let result: DuplicateFinder.RemovalResult

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(
                DuplicateWording.finishedTitle(result),
                systemImage: result.removedCopies > 0 ? "checkmark.circle.fill" : "minus.circle"
            )
            .foregroundStyle(result.removedCopies > 0 ? .green : .secondary)
            .fixedSize(horizontal: false, vertical: true)

            ForEach(DuplicateWording.finishedDetails(result), id: \.self) { detail in
                Text(detail)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// A small Quick Look thumbnail, made when the row appears.
private struct FileThumbnail: View {
    let url: URL
    var size: CGFloat = 44
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
        .frame(width: size, height: size)
        // Decorative next to the file name, which is what VoiceOver reads.
        .accessibilityHidden(true)
        .task(id: url) {
            image = await Self.thumbnail(for: url, size: size)
        }
    }

    @MainActor
    private static func thumbnail(for url: URL, size: CGFloat) async -> NSImage? {
        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: CGSize(width: size, height: size),
            scale: 2,
            representationTypes: .thumbnail
        )
        guard let representation = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) else {
            return nil
        }
        return NSImage(cgImage: representation.cgImage, size: .zero)
    }
}
