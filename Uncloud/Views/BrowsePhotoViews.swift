import AppKit
import QuickLookThumbnailing
import Quartz
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

/// Quick Look for Browse Backup's photos. Space or double-click opens the panel, which pages through the grid.
@MainActor
final class BrowseQuickLook: NSObject {
    static let shared = BrowseQuickLook()

    private var items: [URL] = []

    func show(_ urls: [URL], startingAt index: Int) {
        guard !urls.isEmpty, let panel = QLPreviewPanel.shared() else { return }
        items = urls
        panel.dataSource = self
        panel.reloadData()
        panel.currentPreviewItemIndex = min(max(index, 0), urls.count - 1)
        panel.makeKeyAndOrderFront(nil)
    }

}

/// AppKit calls these on the main thread, where the panel is used. The protocol isn't main-actor isolated, so the
/// conformance is marked preconcurrency. The panel needs no delegate.
extension BrowseQuickLook: @preconcurrency QLPreviewPanelDataSource {
    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        items.count
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        items[index] as NSURL
    }
}

/// The photos of a set of paths as a lazy grid of thumbnails. Click selects, ⌘-click adds or removes, ⌘A selects all,
/// Space and double-click open Quick Look, and the context menu opens, reveals or copies the location.
struct BrowsePhotoGrid: View {
    let paths: [String]
    let destination: URL
    @Binding var selection: Set<String>
    /// The location text for Copy Location: the place and coordinates. Nil when the photo has no location.
    let locationText: (String) -> String?
    @FocusState private var isFocused: Bool

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 2)], spacing: 2) {
                ForEach(paths, id: \.self) { path in
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

    private func url(for path: String) -> URL? {
        BackupFiles.containedURL(for: path, in: destination)
    }

    private func openQuickLook(startingAt path: String) {
        let urls = paths.compactMap { url(for: $0) }
        let index = paths.firstIndex(of: path) ?? 0
        BrowseQuickLook.shared.show(urls, startingAt: index)
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

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: Tokens.Space.m, verticalSpacing: Tokens.Space.xs) {
            row("Place", placeTitle ?? "No location")
            row("Coordinates", coordinates)
            row("Date taken", entry.date.map { $0.formatted(date: .long, time: .shortened) } ?? "Unknown")
            row("Camera", entry.camera ?? "Unknown")
            row("File", (entry.path as NSString).lastPathComponent)
            row("Folder", folder)
            row("Size", ByteCountFormatter.string(fromByteCount: entry.size, countStyle: .file))
        }
        .font(.callout)
        .textSelection(.enabled)
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
