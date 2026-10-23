import AppKit
import SwiftUI
import Testing
@testable import Uncloud

/// The sidebar's first row, the brand header, sits below the titlebar in a real window with a full-size content view and
/// the unified toolbar, so the traffic lights never cover it. The check reads the row's frame from the window, since the
/// offscreen snapshot doesn't draw the sidebar's list.
@MainActor
@Suite("Sidebar titlebar")
struct SidebarTitlebarTests {
    @Test(.timeLimit(.minutes(1))) func firstSidebarRowStartsBelowTheTitlebar() async throws {
        let view = NavigationSplitView {
            PaneSidebar(selection: .constant(.export))
                .navigationSplitViewColumnWidth(min: 180, ideal: 200)
        } detail: {
            Text("Detail")
        }
        .environment(ExportModel())
        .environment(AccountModel.forTesting())

        let size = NSSize(width: 1_000, height: 700)
        let controller = NSHostingController(rootView: view)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.toolbarStyle = .unified
        window.contentViewController = controller
        window.setContentSize(size)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }

        var table: NSTableView?
        for _ in 0..<40 {
            window.contentView?.layoutSubtreeIfNeeded()
            table = Self.tableViews(in: window.contentView).first { $0.numberOfRows > 0 }
            if table != nil { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        let sidebar = try #require(table, "The sidebar list should be in the window")
        let firstRow = sidebar.rect(ofRow: 0)
        let rowInWindow = sidebar.convert(firstRow, to: nil)

        // The content layout rect is the area below the titlebar. The first row must not reach above its bottom edge.
        let layoutTop = window.contentLayoutRect.maxY
        #expect(rowInWindow.maxY <= layoutTop + 0.5, "The first sidebar row (\(rowInWindow.maxY)) should start below the titlebar (\(layoutTop))")
    }

    /// Every table view under the view, the sidebar's list among them.
    private static func tableViews(in view: NSView?) -> [NSTableView] {
        guard let view else { return [] }
        var found: [NSTableView] = []
        if let table = view as? NSTableView {
            found.append(table)
        }
        for subview in view.subviews {
            found += tableViews(in: subview)
        }
        return found
    }
}
