import AppKit
import QuickLookThumbnailing
import SwiftUI

/// Thumbnails for Browse Backup, made by QuickLook and loaded lazily. The memory cache is least-recently-used, so
/// a large backup can't fill memory.
@MainActor
final class BrowseThumbnails {
    static let shared = BrowseThumbnails()

    private static let limit = 400
    private var images: [String: NSImage] = [:]
    /// Keys from least to most recently used.
    private var order: [String] = []

    func image(for url: URL, key: String) async -> NSImage? {
        if let cached = images[key] {
            touch(key)
            return cached
        }
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 256, height: 256), scale: 2, representationTypes: .thumbnail)
        guard let representation = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) else {
            return nil
        }
        let image = NSImage(cgImage: representation.cgImage, size: .zero)
        images[key] = image
        touch(key)
        if order.count > Self.limit {
            let evicted = order.removeFirst()
            images[evicted] = nil
        }
        return image
    }

    private func touch(_ key: String) {
        order.removeAll { $0 == key }
        order.append(key)
    }
}

/// A group of photos under a header in the grid: a day or a month.
struct BrowsePhotoSection: Identifiable, Equatable {
    let id: String
    let title: String
    let subtitle: String?
    /// In the grid's order. The sections' paths, in order, are the grid's `paths`.
    let paths: [String]
}

/// The photos of a set of paths as a lazy grid of thumbnails. Click selects, ⌘-click adds or removes, ⌘A selects all,
/// Space and double-click open Quick Look, and the context menu opens, reveals or copies the location. With `sections`,
/// each group has a header that stays pinned while its photos scroll.
struct BrowsePhotoGrid: View {
    let paths: [String]
    let destination: URL
    @Binding var selection: Set<String>
    /// The location text for Copy Location: the place and coordinates. Nil when the photo has no location.
    let locationText: (String) -> String?
    var sections: [BrowsePhotoSection]? = nil
    @FocusState private var isFocused: Bool

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 2)], spacing: 2, pinnedViews: [.sectionHeaders]) {
                if let sections {
                    ForEach(sections) { section in
                        Section {
                            ForEach(section.paths, id: \.self) { path in
                                tile(for: path)
                            }
                        } header: {
                            BrowseSectionHeader(title: section.title, subtitle: section.subtitle)
                        }
                    }
                } else {
                    ForEach(paths, id: \.self) { path in
                        tile(for: path)
                    }
                }
            }
        }
        .focusable()
        .focused($isFocused)
        .focusEffectDisabled()
        .onKeyPress(.space) {
            guard let first = paths.first(where: selection.contains) ?? paths.first else { return .ignored }
            openQuickLook(startingAt: first)
            return .handled
        }
        // Edit > Select All (⌘A) reaches the grid only while it has focus, as in the Library.
        .onCommand(#selector(NSResponder.selectAll(_:))) {
            selection = Set(paths)
        }
        .accessibilityLabel("Photos, \(paths.count)")
    }

    private func tile(for path: String) -> some View {
        BrowsePhotoTile(path: path, destination: destination, isSelected: selection.contains(path))
            .contentShape(Rectangle())
            .onTapGesture(count: 2) {
                selection = [path]
                openQuickLook(startingAt: path)
            }
            .onTapGesture {
                if NSEvent.modifierFlags.contains(.command) {
                    if selection.contains(path) {
                        selection.remove(path)
                    } else {
                        selection.insert(path)
                    }
                } else {
                    selection = [path]
                }
            }
            .contextMenu {
                Button("Open") {
                    if let url = url(for: path) { NSWorkspace.shared.open(url) }
                }
                Button("Show in Finder") {
                    if let url = url(for: path) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                }
                Divider()
                Button("Copy Location") {
                    if let text = locationText(path) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(text, forType: .string)
                    }
                }
                .disabled(locationText(path) == nil)
            }
    }

    private func url(for path: String) -> URL? {
        BackupFiles.containedURL(for: path, in: destination)
    }

    private func openQuickLook(startingAt path: String) {
        let urls = paths.compactMap { url(for: $0) }
        let index = paths.firstIndex(of: path) ?? 0
        QuickLookPanel.shared.show(urls, startingAt: index)
    }
}

/// The header of a grid section: its title in headline type, then its subtitle in secondary text. It sits on the bar
/// material, so it reads over the thumbnails as they scroll under it.
struct BrowseSectionHeader: View {
    let title: String
    let subtitle: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Tokens.Space.s) {
            Text(title)
                .font(.headline)
                .lineLimit(1)
            if let subtitle {
                Text("·")
                    .font(Tokens.Font.help)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text(subtitle)
                    .font(Tokens.Font.help)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Tokens.Space.m)
        .padding(.vertical, Tokens.Space.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(subtitle.map { "\(title), \($0)" } ?? title)
        .accessibilityAddTraits(.isHeader)
    }
}

/// One thumbnail. Selected tiles get an accent ring and a check mark, not colour alone.
private struct BrowsePhotoTile: View {
    let path: String
    let destination: URL
    let isSelected: Bool
    @State private var image: NSImage?
    @Environment(\.uncloudAccent) private var accent

    var body: some View {
        Rectangle()
            .fill(.quaternary)
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                }
            }
            .clipped()
            .overlay(alignment: .topTrailing) {
                // Same marks as the Library grid: a filled check when selected, an outlined circle otherwise.
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title3)
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, accent ?? Color.accentColor)
                        .padding(4)
                        .accessibilityHidden(true)
                } else {
                    Image(systemName: "circle")
                        .font(.title3)
                        .foregroundStyle(.white)
                        .padding(4)
                        .accessibilityHidden(true)
                }
            }
            .overlay {
                if isSelected {
                    Rectangle().strokeBorder(accent ?? Color.accentColor, lineWidth: 3)
                }
            }
            .task(id: path) {
                guard let url = BackupFiles.containedURL(for: path, in: destination) else {
                    image = nil
                    return
                }
                image = await BrowseThumbnails.shared.image(for: url, key: path)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel((path as NSString).lastPathComponent)
            .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// The details of one photo: place, coordinates, date, camera, file, folder and size.
struct BrowsePhotoDetail: View {
    let entry: BrowseEntry
    let placeTitle: String?
    /// Reads the camera of a photo indexed from iCloud, which has none until it's asked for. Nil when the file can't
    /// be read now.
    var loadCamera: () async -> String? = { nil }
    @State private var cameraUnavailable = false

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: Tokens.Space.m, verticalSpacing: Tokens.Space.xs) {
            row("Place", placeTitle ?? "No location")
            row("Coordinates", coordinates)
            row("Date taken", entry.date.map { $0.formatted(date: .long, time: .shortened) } ?? "Unknown")
            row("Camera", Self.cameraText(for: entry, unavailable: cameraUnavailable))
            row("File", (entry.path as NSString).lastPathComponent)
            row("Folder", folder)
            row("Size", ByteCountFormatter.string(fromByteCount: entry.size, countStyle: .file))
        }
        .font(.callout)
        .textSelection(.enabled)
        .task(id: entry.path) {
            cameraUnavailable = false
            guard entry.camera == nil, entry.source == .iCloud else { return }
            if await loadCamera() == nil {
                cameraUnavailable = true
            }
        }
    }

    /// The camera line: the camera; "Unknown" when the file has none; "Reading…" while an iCloud photo's file is read.
    static func cameraText(for entry: BrowseEntry, unavailable: Bool) -> String {
        if let camera = entry.camera { return camera.isEmpty ? "Unknown" : camera }
        return entry.source == .iCloud && !unavailable ? "Reading…" : "Unknown"
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.trailing)
            Text(value)
                .lineLimit(2)
                .truncationMode(.middle)
                .gridColumnAlignment(.leading)
        }
        .accessibilityElement(children: .combine)
    }

    private var coordinates: String {
        guard let latitude = entry.latitude, let longitude = entry.longitude else { return "None" }
        return BrowsePhotoDetail.coordinateText(latitude: latitude, longitude: longitude)
    }

    private var folder: String {
        let folder = (entry.path as NSString).deletingLastPathComponent
        return folder.isEmpty ? "Backup folder" : folder
    }

    /// "41.9028° N, 12.4964° E".
    static func coordinateText(latitude: Double, longitude: Double) -> String {
        String(format: "%.4f° %@, %.4f° %@",
               abs(latitude), latitude < 0 ? "S" : "N",
               abs(longitude), longitude < 0 ? "W" : "E")
    }
}
