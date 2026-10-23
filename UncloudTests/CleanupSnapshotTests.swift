import AppKit
import SwiftUI
import Testing
@testable import Uncloud

/// Renders the Delete from iCloud screens for design review, in light and dark: the grid with a selection and its
/// badges, the confirmation, the progress while deleting, and the finished summary. Runs only when the
/// `UNCLOUD_SNAPSHOT_DIR` environment variable names a folder, and writes the PNGs there.
/// The library is fabricated: a test browser backend stands in for the bridge's pages, and the fake bridge
/// stands in for photo_bridge.py, so nothing reaches iCloud.
private let cleanupSnapshotDirectory: URL? = ProcessInfo.processInfo.environment["UNCLOUD_SNAPSHOT_DIR"].map {
    URL(fileURLWithPath: $0, isDirectory: true)
}

@MainActor
@Suite("Delete from iCloud snapshots", .enabled(if: cleanupSnapshotDirectory != nil))
struct CleanupSnapshotTests {
    private final class BundleToken {}

    /// Sixty items, sized and shaded by number, with every seventh one a video.
    @MainActor
    private final class FakeBrowserBackend: LibraryBrowserBackend {
        let count: Int

        init(count: Int) {
            self.count = count
        }

        func loadCount() async throws -> Int {
            count
        }

        func loadPage(_ index: Int, pageSize: Int) async throws -> [Uncloud.LibraryItem] {
            let lower = index * pageSize
            let upper = min(count, lower + pageSize)
            guard lower < upper else { return [] }
            return (lower..<upper).map { number in
                Uncloud.LibraryItem(
                    id: "asset-\(number)",
                    filename: "IMG_\(String(format: "%04d", number)).HEIC",
                    created: Date(timeIntervalSince1970: 1_700_000_000 + Double(number) * 86_400),
                    isVideo: number % 7 == 0
                )
            }
        }

        func thumbnail(for item: Uncloud.LibraryItem, pixelSize: CGSize) async -> NSImage? {
            let number = Int(item.id.dropFirst("asset-".count)) ?? 0
            let hue = CGFloat(number % 12) / 12
            return NSImage(size: NSSize(width: 256, height: 256), flipped: false) { rect in
                NSColor(hue: hue, saturation: 0.45, brightness: 0.8, alpha: 1).setFill()
                rect.fill()
                return true
            }
        }

        func rankHints(for ids: Set<String>) async -> [String: Int] {
            [:]
        }

        func knownBytes() async -> [String: Int64] {
            Dictionary(uniqueKeysWithValues: (0..<count).map { ("asset-\($0)", Int64(1_500_000 + $0 * 40_000)) })
        }

        func reset() async {}
    }

    @Test(.timeLimit(.minutes(3))) func rendersGridConfirmationProgressAndSummaryInLightAndDark() async throws {
        let output = try #require(cleanupSnapshotDirectory)
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        try await withTemporaryDirectoryAsync { drive in
            // Every third item is backed up on the drive.
            let manifest = try ExportManifest(destination: drive)
            for number in stride(from: 0, to: 60, by: 3) {
                let path = "2024/07/IMG_\(number).HEIC"
                try writeFile("photo", to: path, in: drive)
                try manifest.recordICloudItem(id: "asset-\(number)", paths: [path])
            }

            let browser = LibraryBrowser(source: .iCloud, backend: FakeBrowserBackend(count: 60))
            browser.load()
            try await Self.wait { browser.count != nil }
            let recentlyDeleted = LibraryBrowser(source: .iCloud, backend: FakeBrowserBackend(count: 0))

            let (bridge, _) = try Self.fakeBridge(root: drive, options: ["--total", "60", "--delete-batch-delay", "0.6", "--delete-fail-every", "11"])
            defer { bridge.terminate() }
            let cleanup = ICloudCleanup(
                appleID: "fake@example.invalid",
                bridge: bridge,
                environment: ICloudCleanup.Environment(
                    isExportRunning: { false },
                    libraryCount: { browser.count },
                    rankHints: { _ in [:] },
                    libraryDidChange: { _ in },
                    recentlyDeletedCount: { recentlyDeleted.count }
                ),
                batchSize: 2
            )
            // A selection with backed-up and not backed-up items, and two that fail in the fake (11 and 22).
            let selected = Set(["asset-0", "asset-3", "asset-4", "asset-7", "asset-8", "asset-11", "asset-13", "asset-22", "asset-25", "asset-30"])
            cleanup.selection = .only(selected)

            for scheme in [ColorScheme.light, .dark] {
                let image = try #require(await Self.render(
                    CleanupGridView(
                        cleanup: cleanup, library: browser, recentlyDeleted: recentlyDeleted, destination: drive, isExportRunning: false
                    )
                        .frame(width: 720, height: 520),
                    size: NSSize(width: 720, height: 520), scheme: scheme
                ))
                try Self.save(image, named: "grid-\(Self.name(scheme)).png", in: output)
            }

            cleanup.requestConfirmation()
            let pending = cleanup.pendingCount
            // Backed up is every third item: 0, 3 and 30 of the selection.
            let backedUpSelected = selected.filter { Int($0.dropFirst("asset-".count)).map { $0 % 3 == 0 } == true }.count
            for scheme in [ColorScheme.light, .dark] {
                let image = try #require(await Self.render(
                    CleanupConfirmationSheet(count: pending, notBackedUp: pending - backedUpSelected, onCancel: {}, onDelete: { _ in })
                        .frame(width: 460, height: 300),
                    size: NSSize(width: 460, height: 300), scheme: scheme
                ))
                try Self.save(image, named: "confirm-\(Self.name(scheme)).png", in: output)
            }
            cleanup.cancelConfirmation()

            // Deleting: start the run and draw it part way through.
            cleanup.requestConfirmation()
            #expect(cleanup.start(typed: "\(cleanup.pendingCount)"))
            try await Self.wait { if case let .deleting(done, _, _) = cleanup.state { done >= 4 } else { false } }
            for scheme in [ColorScheme.light, .dark] {
                let image = try #require(await Self.render(
                    CleanupGridView(
                        cleanup: cleanup, library: browser, recentlyDeleted: recentlyDeleted, destination: drive, isExportRunning: false
                    )
                        .frame(width: 720, height: 520),
                    size: NSSize(width: 720, height: 520), scheme: scheme
                ))
                try Self.save(image, named: "deleting-\(Self.name(scheme)).png", in: output)
            }

            // Finished: the run ends with its summary, including the two fake failures.
            await cleanup.waitUntilEnded()
            guard case .finished = cleanup.state else {
                Issue.record("Expected the run to finish, got \(cleanup.state)")
                return
            }
            for scheme in [ColorScheme.light, .dark] {
                let image = try #require(await Self.render(
                    CleanupStatusCard(cleanup: cleanup)
                        .frame(width: 720, height: 260),
                    size: NSSize(width: 720, height: 260), scheme: scheme
                ))
                try Self.save(image, named: "finished-\(Self.name(scheme)).png", in: output)
            }
        }
    }

    /// Recently Deleted: the grid with a selection, the empty state, the recovery sheet, the progress while recovering,
    /// and the finished summary, in light and dark. The fake starts with twelve items in Recently Deleted, and fails
    /// the ones numbered 0, 5 and 10 to show the failures in the summary.
    @Test(.timeLimit(.minutes(3))) func rendersRecentlyDeletedGridRecoverAlertAndFinishedInLightAndDark() async throws {
        let output = try #require(cleanupSnapshotDirectory)
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        try await withTemporaryDirectoryAsync { drive in
            // Every third item of Recently Deleted is backed up on the drive.
            let manifest = try ExportManifest(destination: drive)
            for number in stride(from: 0, to: 12, by: 3) {
                let path = "2024/07/IMG_\(number).HEIC"
                try writeFile("photo", to: path, in: drive)
                try manifest.recordICloudItem(id: "asset-\(number)", paths: [path])
            }

            let library = LibraryBrowser(source: .iCloud, backend: FakeBrowserBackend(count: 48))
            library.load()
            let trash = LibraryBrowser(source: .iCloud, backend: FakeBrowserBackend(count: 12))
            trash.load()
            try await Self.wait { trash.count != nil }

            let (bridge, _) = try Self.fakeBridge(root: drive, options: [
                "--total", "60", "--trash-first", "12", "--delete-batch-delay", "0.6", "--delete-fail-every", "5",
            ])
            defer { bridge.terminate() }
            let cleanup = ICloudCleanup(
                appleID: "fake@example.invalid",
                bridge: bridge,
                environment: ICloudCleanup.Environment(
                    isExportRunning: { false },
                    libraryCount: { library.count },
                    rankHints: { _ in [:] },
                    libraryDidChange: { _ in },
                    recentlyDeletedCount: { trash.count },
                    recoveryDidChange: { _ in }
                ),
                batchSize: 2
            )
            cleanup.setMode(.recentlyDeleted)
            let selected = Set(["asset-0", "asset-1", "asset-3", "asset-4", "asset-5", "asset-7", "asset-8", "asset-10", "asset-11"])
            cleanup.selection = .only(selected)

            for scheme in [ColorScheme.light, .dark] {
                let image = try #require(await Self.render(
                    CleanupGridView(
                        cleanup: cleanup, library: library, recentlyDeleted: trash, destination: drive, isExportRunning: false
                    )
                        .frame(width: 720, height: 520),
                    size: NSSize(width: 720, height: 520), scheme: scheme
                ))
                try Self.save(image, named: "recently-deleted-grid-\(Self.name(scheme)).png", in: output)
            }

            // The empty state, when Recently Deleted holds nothing.
            let empty = LibraryBrowser(source: .iCloud, backend: FakeBrowserBackend(count: 0))
            empty.load()
            try await Self.wait { empty.count != nil }
            let emptyCleanup = ICloudCleanup(
                appleID: "fake@example.invalid",
                bridge: bridge,
                environment: ICloudCleanup.Environment(
                    isExportRunning: { false },
                    libraryCount: { library.count },
                    rankHints: { _ in [:] },
                    libraryDidChange: { _ in },
                    recentlyDeletedCount: { empty.count }
                )
            )
            emptyCleanup.setMode(.recentlyDeleted)
            for scheme in [ColorScheme.light, .dark] {
                let image = try #require(await Self.render(
                    CleanupGridView(
                        cleanup: emptyCleanup, library: library, recentlyDeleted: empty, destination: drive, isExportRunning: false
                    )
                        .frame(width: 720, height: 520),
                    size: NSSize(width: 720, height: 520), scheme: scheme
                ))
                try Self.save(image, named: "recently-deleted-empty-\(Self.name(scheme)).png", in: output)
            }

            // The recovery confirmation: no number to type.
            cleanup.requestConfirmation()
            let pending = cleanup.pendingCount
            for scheme in [ColorScheme.light, .dark] {
                let image = try #require(await Self.render(
                    CleanupRecoverySheet(count: pending, onCancel: {}, onRecover: {})
                        .frame(width: 460, height: 200),
                    size: NSSize(width: 460, height: 200), scheme: scheme
                ))
                try Self.save(image, named: "recover-alert-\(Self.name(scheme)).png", in: output)
            }
            cleanup.cancelConfirmation()

            // Recovering: start the run and draw it part way through.
            cleanup.requestConfirmation()
            #expect(cleanup.recover())
            try await Self.wait { if case let .deleting(done, _, _) = cleanup.state { done >= 4 } else { false } }
            for scheme in [ColorScheme.light, .dark] {
                let image = try #require(await Self.render(
                    CleanupStatusCard(cleanup: cleanup)
                        .frame(width: 720, height: 120),
                    size: NSSize(width: 720, height: 120), scheme: scheme
                ))
                try Self.save(image, named: "recovering-\(Self.name(scheme)).png", in: output)
            }

            // Finished: the summary with the three fake failures.
            await cleanup.waitUntilEnded()
            guard case .finished = cleanup.state else {
                Issue.record("Expected the recovery to finish, got \(cleanup.state)")
                return
            }
            for scheme in [ColorScheme.light, .dark] {
                let image = try #require(await Self.render(
                    CleanupStatusCard(cleanup: cleanup)
                        .frame(width: 720, height: 260),
                    size: NSSize(width: 720, height: 260), scheme: scheme
                ))
                try Self.save(image, named: "recovered-finished-\(Self.name(scheme)).png", in: output)
            }
        }
    }

    /// The toolbar and the selection bar in the window, at the minimum width (760 pt) and at 1000 pt, with the sidebar
    /// showing. Both modes, with and without a selection, light and dark. The window is titled with the unified toolbar,
    /// as the app's main window is, so the toolbar draws. The Recently Deleted count is in the subtitle, not the segment.
    @Test(.timeLimit(.minutes(3))) func rendersToolbarAndSelectionBarAtMinimumAndWideWidths() async throws {
        let output = try #require(cleanupSnapshotDirectory)
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        try await withTemporaryDirectoryAsync { drive in
            let browser = LibraryBrowser(source: .iCloud, backend: FakeBrowserBackend(count: 5_084))
            browser.load()
            try await Self.wait { browser.count != nil }
            let recentlyDeleted = LibraryBrowser(source: .iCloud, backend: FakeBrowserBackend(count: 5_084))
            recentlyDeleted.load()
            try await Self.wait { recentlyDeleted.count != nil }

            let (bridge, _) = try Self.fakeBridge(root: drive, options: ["--total", "60"])
            defer { bridge.terminate() }
            let cleanup = ICloudCleanup(
                appleID: "fake@example.invalid",
                bridge: bridge,
                environment: ICloudCleanup.Environment(
                    isExportRunning: { false },
                    libraryCount: { browser.count },
                    rankHints: { _ in [:] },
                    libraryDidChange: { _ in },
                    recentlyDeletedCount: { recentlyDeleted.count }
                ),
                batchSize: 2
            )

            for mode in [ICloudCleanup.Mode.library, .recentlyDeleted] {
                cleanup.setMode(mode)
                for hasSelection in [false, true] {
                    cleanup.selection = hasSelection ? .only(["asset-0", "asset-3", "asset-4", "asset-7", "asset-8"]) : .only([])
                    for width in [760.0, 1_000.0] {
                        for scheme in [ColorScheme.light, .dark] {
                            let view = NavigationSplitView {
                                PaneSidebar(selection: .constant(.cleanup))
                                    .navigationSplitViewColumnWidth(min: 180, ideal: 200)
                            } detail: {
                                CleanupGridView(
                                    cleanup: cleanup, library: browser, recentlyDeleted: recentlyDeleted, destination: drive, isExportRunning: false
                                )
                            }
                            .environment(ExportModel())
                            .environment(AccountModel.forTesting())
                            let modeName = mode == .library ? "library" : "recently-deleted"
                            let selectionName = hasSelection ? "selected" : "none"
                            let name = "toolbar-\(modeName)-\(selectionName)-\(Int(width))-\(Self.name(scheme)).png"
                            let image = try #require(await Self.renderTitledWindow(view, size: NSSize(width: width, height: 560), scheme: scheme))
                            try Self.save(image, named: name, in: output)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    /// A fake bridge over `root`, with the options given; the same fake the Swift bridge tests use.
    private static func fakeBridge(root: URL, options: [String]) throws -> (ICloudBridge, URL) {
        let python = try #require(ICloudAccount.helperURL ?? ICloudAccount.helperOverride?.executableURL)
        let fake = try #require(Bundle(for: BundleToken.self).url(forResource: "fake_bridge", withExtension: "py"))
        let appleID = "fake-\(UUID().uuidString.prefix(8))@example.invalid"
        let log = root.appending(path: "launch.log")
        let bridge = ICloudBridge(
            appleID: appleID,
            executableURL: python,
            arguments: ["-I", "-B", fake.path(percentEncoded: false), "--rate", "0",
                        "--launch-log", log.path(percentEncoded: false)] + options
                + ["--", "-u", appleID, "--cookie-directory", root.path(percentEncoded: false)]
        )
        return (bridge, log)
    }

    /// Polls until `condition` holds, for the screens that wait on a run.
    private static func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<600 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw CancellationError()
    }

    private static func name(_ scheme: ColorScheme) -> String {
        scheme == .dark ? "dark" : "light"
    }

    /// Attaches the PNG to the test result, and writes it to the folder when the sandboxed test host is allowed to.
    private static func save(_ image: NSImage, named name: String, in folder: URL) throws {
        let tiff = try #require(image.tiffRepresentation)
        let bitmap = try #require(NSBitmapImageRep(data: tiff))
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        Attachment.record(png, named: name)
        try? png.write(to: folder.appending(path: name))
    }

    /// Hosts the view in a titled window with the unified toolbar and a full-size content view, as the app's main window
    /// is, and captures the whole window frame, title bar and traffic lights included.
    private static func renderTitledWindow<V: View>(_ view: V, size: NSSize, scheme: ColorScheme) async -> NSImage? {
        let controller = NSHostingController(rootView: view.environment(\.colorScheme, scheme))
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        window.toolbarStyle = .unified
        window.contentViewController = controller
        window.setContentSize(size)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        for _ in 0..<25 {
            window.contentView?.layoutSubtreeIfNeeded()
            try? await Task.sleep(for: .milliseconds(100))
        }
        // A window made in code frees itself on close by default; ARC frees it too, which crashes the test host later.
        window.isReleasedWhenClosed = false
        defer { window.close() }
        guard let frameView = window.contentView?.superview,
              let rep = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds) else { return nil }
        frameView.cacheDisplay(in: frameView.bounds, to: rep)
        let image = NSImage(size: frameView.bounds.size)
        image.addRepresentation(rep)
        return image
    }

    /// Hosts the view in an offscreen window and captures it, as the other snapshot tests do.
    private static func render<V: View>(_ view: V, size: NSSize, scheme: ColorScheme) async -> NSImage? {
        let page = view
            .environment(\.colorScheme, scheme)
            .environment(AccountModel.forTesting())
            .background(Color(nsColor: .windowBackgroundColor))
        let host = NSHostingView(rootView: page)
        host.frame = NSRect(origin: .zero, size: size)

        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        window.contentView = host
        // Key window, so prominent buttons draw in the accent colour as they do in the app.
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        for _ in 0..<15 {
            host.layoutSubtreeIfNeeded()
            try? await Task.sleep(for: .milliseconds(100))
        }

        // A window made in code frees itself on close by default; ARC frees it too, which crashes the test host later.

        window.isReleasedWhenClosed = false

        defer { window.close() }
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
        host.cacheDisplay(in: host.bounds, to: rep)
        let image = NSImage(size: size)
        image.addRepresentation(rep)
        return image
    }
}
