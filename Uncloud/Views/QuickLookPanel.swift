import AppKit
import Quartz

/// The Quick Look panel for the photos of a grid: Space or double-click opens it, and it pages through the items
/// it's given. Shared by Browse Backup and the library grids.
@MainActor
final class QuickLookPanel: NSObject {
    static let shared = QuickLookPanel()

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
extension QuickLookPanel: @preconcurrency QLPreviewPanelDataSource {
    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        items.count
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        items[index] as NSURL
    }
}
