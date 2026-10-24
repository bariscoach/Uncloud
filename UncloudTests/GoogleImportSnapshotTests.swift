import AppKit
import SwiftUI
import Testing
@testable import Uncloud

/// Renders the main window on the Google Photos pane to PNG attachments, in light and dark mode, at the window's
/// minimum size, so the sidebar's five rows and the pane's steps can be checked. Runs only when
/// UNCLOUD_GOOGLE_SNAPSHOTS is set. The PNGs are exported from the result bundle with `xcrun xcresulttool`.
@MainActor
@Suite("GoogleImportSnapshot")
struct GoogleImportSnapshotTests {
    @Test func rendersGooglePane() async throws {
        guard ProcessInfo.processInfo.environment["UNCLOUD_GOOGLE_SNAPSHOTS"] != nil else { return }
        let model = ExportModel()
        model.pane = .google
        for scheme in [ColorScheme.light, .dark] {
            let view = MainWindow()
                .environment(model)
                .environment(BackupTools(model: model))
            let name = scheme == .dark ? "dark" : "light"
            let image = try #require(await Self.render(view, size: NSSize(width: 760, height: 500), scheme: scheme))
            Attachment.record(try Self.png(image), named: "google-\(name).png")
        }
    }

    // MARK: - Helpers

    private static func png(_ image: NSImage) throws -> Data {
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let data = rep.representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return data
    }

    /// Renders a view inside a titled window, so the toolbar, title and subtitle draw as they do in the app.
    private static func render<V: View>(_ view: V, size: NSSize, scheme: ColorScheme) async -> NSImage? {
        // The shipping accent, as the app sets it at its root and the UI refresh snapshots do.
        let page = view
            .accentVariant(.sky)
            .environment(\.colorScheme, scheme)
            .environment(AccountModel.forTesting())
        let controller = NSHostingController(rootView: page)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        window.contentViewController = controller
        window.setContentSize(size)
        window.toolbarStyle = .unified
        // Controls draw their selected state only in a key window, and a sidebar-style list only when it has focus.
        // A user looking at the window has both, so the capture does too. Without them the selection draws black offscreen.
        for _ in 0..<30 {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            if window.isKeyWindow { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        // Thumbnails and the map load after layout, so give them time.
        for step in 0..<40 {
            window.contentView?.layoutSubtreeIfNeeded()
            if [5, 15, 25].contains(step) {
                // Each render closes its window, and activation can drift to the next one. Take key and main again.
                NSApp.activate(ignoringOtherApps: true)
                window.makeKeyAndOrderFront(nil)
                window.makeMain()
            }
            if step == 5 {
                if let table = Self.firstTable(in: window.contentView) {
                    window.makeFirstResponder(table)
                }
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        // A window made in code frees itself on close by default; ARC frees it too, which crashes the test host later.
        window.isReleasedWhenClosed = false
        defer { window.close() }
        // Let the key state reach the title bar and the list before the capture is drawn.
        window.displayIfNeeded()
        try? await Task.sleep(for: .milliseconds(300))
        guard let frameView = window.contentView?.superview else { return nil }
        frameView.displayIfNeeded()
        guard let rep = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds) else { return nil }
        frameView.cacheDisplay(in: frameView.bounds, to: rep)
        let image = NSImage(size: frameView.bounds.size)
        image.addRepresentation(rep)
        return image
    }

    private static func firstTable(in view: NSView?) -> NSTableView? {
        guard let view else { return nil }
        if let table = view as? NSTableView { return table }
        for subview in view.subviews {
            if let table = firstTable(in: subview) { return table }
        }
        return nil
    }

}
