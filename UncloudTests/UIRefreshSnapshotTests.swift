import AppKit
import SwiftUI
import Testing
@testable import Uncloud

/// Renders the screens the UI refresh changes, to PNG attachments: light and dark, for each accent variant. Runs only
/// when UNCLOUD_UI_REFRESH_SNAPSHOTS is set, so a normal test run writes nothing. The sandboxed test host can't write
/// to the scratch folder, so the PNGs are exported from the result bundle with `xcrun xcresulttool`.
@MainActor
@Suite("UIRefreshSnapshot")
struct UIRefreshSnapshotTests {
    private static let variants: [AccentVariant] = [.indigo, .sky, .purple]

    /// Backup pane states, every hero state, the full window (sidebar and toolbar), Settings and the Clean Up sheets.
    @Test func rendersRefreshScreens() async throws {
        guard ProcessInfo.processInfo.environment["UNCLOUD_UI_REFRESH_SNAPSHOTS"] != nil else { return }
        let defaults = UserDefaults.standard
        let drive = FileManager.default.temporaryDirectory
            .appending(path: "uncloud-ui-refresh-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: drive, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: drive) }

        let savedAppleID = ICloudAccount.appleID
        let savedCount = defaults.object(forKey: "icloudLibraryCount")
        let savedSource = defaults.object(forKey: "librarySource")
        ICloudAccount.appleID = "preview@example.invalid"
        defaults.set(93_015, forKey: "icloudLibraryCount")
        defaults.set(LibrarySource.iCloud.rawValue, forKey: "librarySource")
        defer {
            ICloudAccount.appleID = savedAppleID
            defaults.set(savedCount, forKey: "icloudLibraryCount")
            defaults.set(savedSource, forKey: "librarySource")
        }

        // A destination, so the context exists for the preview status.
        defaults.removeObject(forKey: ExportModel.bookmarkKey)
        let model = ExportModel()
        model.chooseDestination(.success(drive))
        try await Task.sleep(for: .milliseconds(800))
        let context = try #require(model.newPhotosContext)
        let since = Date.now.addingTimeInterval(-3 * 24 * 60 * 60)
        var images: [(String, NSImage)] = []

        // Backup pane: new photos, up to date, and ready (no status yet), at the default and a tall height.
        let paneStates: [(name: String, status: NewPhotosStatus?)] = [
            ("backup-newphotos", NewPhotosStatus(count: 1_243, isAtLeast: false, since: since)),
            ("backup-uptodate", NewPhotosStatus(count: 0, isAtLeast: false, since: since)),
            ("backup-ready", nil),
        ]
        for variant in Self.variants {
            for state in paneStates {
                model.newPhotos.setStatusForPreview(state.status, context: context)
                for size in [NSSize(width: 560, height: 1_480), NSSize(width: 1_000, height: 700)] {
                    for scheme in [ColorScheme.light, .dark] {
                        let pane = BackupPane()
                            .environment(model)
                            .environment(BackupTools(model: model))
                        let image = try #require(await Self.renderWindow(pane, size: size, scheme: scheme, variant: variant))
                        images.append(("\(state.name)-\(size.width == 560 ? "560" : "1000")-\(Self.name(scheme))-\(variant)", image))
                    }
                }
            }
        }

        // No folder yet.
        let noFolder = ExportModel()
        for variant in Self.variants {
            for scheme in [ColorScheme.light, .dark] {
                let pane = BackupPane()
                    .environment(noFolder)
                    .environment(BackupTools(model: noFolder))
                let image = try #require(await Self.renderWindow(pane, size: NSSize(width: 1_000, height: 700), scheme: scheme, variant: variant))
                images.append(("backup-nofolder-1000-\(Self.name(scheme))-\(variant)", image))
            }
        }

        // Every hero state, on its own, so the states the model can't reach (resume, paused, waiting) are still seen.
        let heroStates: [(name: String, content: BackupHeroContent)] = Self.heroStates(since: since)
        for variant in Self.variants {
            for state in heroStates {
                for scheme in [ColorScheme.light, .dark] {
                    let header = BackupHeroHeader(content: state.content)
                        .padding(Tokens.Space.l)
                    let image = try #require(await Self.renderWindow(header, size: NSSize(width: 560, height: 110), scheme: scheme, variant: variant))
                    images.append(("hero-\(state.name)-\(Self.name(scheme))-\(variant)", image))
                }
            }
        }

        // The whole window, with the sidebar and toolbar, on each pane in sidebar order. Export Settings renders twice,
        // once per segment (General, then Folder Organization).
        model.newPhotos.setStatusForPreview(NewPhotosStatus(count: 1_243, isAtLeast: false, since: since), context: context)
        for variant in Self.variants {
            for pane in ExportModel.Pane.allCases {
                model.pane = pane
                let sections: [(name: String, section: ExportModel.ExportSettingsSection)] = pane == .backup
                    ? [("", .general), ("folders-", .folders)]
                    : [("", .general)]
                for section in sections {
                    model.exportSettingsSection = section.section
                    for scheme in [ColorScheme.light, .dark] {
                        let window = MainWindow()
                            .environment(model)
                            .environment(BackupTools(model: model))
                        let image = try #require(await Self.renderTitledWindow(window, size: NSSize(width: 1_000, height: 700), scheme: scheme, variant: variant))
                        images.append(("window-\(pane)-\(section.name)\(Self.name(scheme))-\(variant)", image))
                    }
                }
            }
        }
        model.pane = .export
        model.exportSettingsSection = .general

        // Settings, and the Clean Up sheets.
        let settings = AutoBackupSettings()
        for variant in Self.variants {
            for scheme in [ColorScheme.light, .dark] {
                let page = SettingsView()
                    .environment(model)
                    .environment(settings)
                let image = try #require(await Self.renderWindow(page, size: NSSize(width: 460, height: 520), scheme: scheme, variant: variant))
                images.append(("settings-\(Self.name(scheme))-\(variant)", image))

                let confirm = CleanupConfirmationSheet(count: 10, notBackedUp: 7, onCancel: {}, onDelete: { _ in })
                images.append(("cleanup-confirm-\(Self.name(scheme))-\(variant)", try #require(await Self.renderWindow(confirm, size: NSSize(width: 460, height: 300), scheme: scheme, variant: variant))))
                let recover = CleanupRecoverySheet(count: 12, onCancel: {}, onRecover: {})
                images.append(("cleanup-recover-\(Self.name(scheme))-\(variant)", try #require(await Self.renderWindow(recover, size: NSSize(width: 460, height: 200), scheme: scheme, variant: variant))))
            }
        }

        for (name, image) in images {
            let data = try Self.png(image)
            Attachment.record(data, named: "\(name).png")
        }
    }

    /// Session Detail and Landing, in light and dark, for each accent variant. Gated like the others.
    @Test func rendersSheetsAndLanding() async throws {
        guard ProcessInfo.processInfo.environment["UNCLOUD_UI_REFRESH_SNAPSHOTS"] != nil else { return }
        let model = ExportModel()
        var images: [(String, NSImage)] = []
        for variant in Self.variants {
            for scheme in [ColorScheme.light, .dark] {
                let session = ExportSessionDetailView(chain: DesignSnapshotTests.sampleChains()[0])
                images.append(("session-detail-\(Self.name(scheme))-\(variant)", try #require(await Self.renderWindow(session, size: NSSize(width: 560, height: 760), scheme: scheme, variant: variant))))

                let landing = LandingView().environment(model)
                images.append(("landing-\(Self.name(scheme))-\(variant)", try #require(await Self.renderWindow(landing, size: NSSize(width: 1_000, height: 700), scheme: scheme, variant: variant))))
            }
        }
        for (name, image) in images {
            Attachment.record(try Self.png(image), named: "\(name).png")
        }
    }

    /// One content value per hero state, each built from the same table the pane uses.
    private static func heroStates(since: Date) -> [(name: String, content: BackupHeroContent)] {
        let now = Date.now
        func make(
            _ phase: ExportModel.Phase = .idle,
            hasAutoResume: Bool = false,
            offersResume: Bool = false,
            failed: Int = 0,
            newPhotos: NewPhotosStatus? = nil,
            lastExport: Date? = nil,
            ready: String? = nil,
            hasDestination: Bool = true
        ) -> BackupHeroContent {
            BackupHeroContent.make(
                phase: phase, hasDestination: hasDestination, hasAutoResume: hasAutoResume, offersResumeExport: offersResume,
                failedCount: failed, newPhotos: newPhotos, lastExport: lastExport, readySummary: ready, now: now
            )
        }
        let newPhotosStatus = NewPhotosStatus(count: 1_243, isAtLeast: false, since: since)
        let upToDate = NewPhotosStatus(count: 0, isAtLeast: false, since: since)
        let summary = "0 already on this drive · 93,015 to go"
        return [
            ("newphotos", make(newPhotos: newPhotosStatus)),
            ("resume", make(offersResume: true)),
            ("uptodate", make(newPhotos: upToDate)),
            ("firstexport", make(ready: summary)),
            ("exporting", make(.running)),
            ("preparing", make(.preparing)),
            ("paused", make(.paused)),
            ("cancelling", make(.cancelling)),
            ("waiting", make(hasAutoResume: true)),
            ("finishedproblems", make(.completed, failed: 2)),
            ("stopped", make(.failed("Disk full"))),
            ("cancelled", make(.cancelled)),
            ("complete", make(.completed, lastExport: since)),
            ("needsfolder", make(hasDestination: false)),
        ]
    }

    // MARK: - Helpers

    private static func name(_ scheme: ColorScheme) -> String {
        scheme == .dark ? "dark" : "light"
    }

    private static func png(_ image: NSImage) throws -> Data {
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let data = rep.representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return data
    }

    /// Renders a view in a borderless offscreen window of the given size, with the accent variant applied.
    private static func renderWindow<V: View>(_ view: V, size: NSSize, scheme: ColorScheme, variant: AccentVariant) async -> NSImage? {
        let page = view
            .accentVariant(variant)
            .environment(\.colorScheme, scheme)
            .environment(AccountModel.forTesting())
            .frame(width: size.width, height: size.height)
            .background(Color(nsColor: .windowBackgroundColor))
        let host = NSHostingView(rootView: page)
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        for _ in 0..<10 {
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

    /// Renders a view in a titled window, so the toolbar and sidebar draw as they do in the app. The image
    /// includes the title bar and toolbar, from the window's frame view.
    private static func renderTitledWindow<V: View>(_ view: V, size: NSSize, scheme: ColorScheme, variant: AccentVariant) async -> NSImage? {
        let page = view
            .accentVariant(variant)
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
}
