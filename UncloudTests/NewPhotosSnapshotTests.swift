import AppKit
import SwiftUI
import Testing
@testable import Uncloud

/// Renders the new-photos states (the Backup pane's status, "Up to date", and the primary button with the sidebar
/// badge) to PNG files in light and dark. Runs only when UNCLOUD_NEW_PHOTOS_SNAPSHOTS is set, so a normal test run
/// writes nothing. The PNGs go to the scratch folder when the test host can write there, and are always attached
/// to the test result.
@MainActor
@Suite("NewPhotosSnapshot")
struct NewPhotosSnapshotTests {
    private static let scratch = URL(
        fileURLWithPath: "/private/tmp/claude-501/-Users-barishiz-Developer-icloud-photo-export/df886b0f-d79a-4d1c-973d-23c5d89614c2/scratchpad/new-photos-snapshots",
        isDirectory: true
    )

    @Test func rendersNewPhotosStatesInLightAndDark() async throws {
        guard ProcessInfo.processInfo.environment["UNCLOUD_NEW_PHOTOS_SNAPSHOTS"] != nil else { return }
        let defaults = UserDefaults.standard
        let drive = FileManager.default.temporaryDirectory
            .appending(path: "uncloud-new-photos-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: drive, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: drive) }

        // An iCloud source with a preview account and library size, put back afterwards.
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

        let model = ExportModel()
        model.chooseDestination(.success(drive))
        try await Task.sleep(for: .milliseconds(800))
        let context = try #require(model.newPhotosContext)
        let since = Date.now.addingTimeInterval(-3 * 24 * 60 * 60)

        let states: [(name: String, status: NewPhotosStatus)] = [
            ("new", NewPhotosStatus(count: 1_243, isAtLeast: false, since: since)),
            ("up-to-date", NewPhotosStatus(count: 0, isAtLeast: false, since: since)),
        ]
        var attachments: [(String, Data)] = []
        for state in states {
            model.newPhotos.setStatusForPreview(state.status, context: context)
            for scheme in [ColorScheme.light, .dark] {
                let pane = BackupPane()
                    .environment(model)
                    .environment(BackupTools(model: model))
                let image = try #require(await render(pane, size: NSSize(width: 560, height: 1_480), scheme: scheme))
                attachments.append(("backup-pane-\(state.name)-\(Self.name(scheme)).png", try Self.png(image)))
            }
        }

        // The primary button and the sidebar badge, with new photos: the Cloud Library toolbar's button and the Export Settings row.
        model.newPhotos.setStatusForPreview(states[0].status, context: context)
        for scheme in [ColorScheme.light, .dark] {
            let strip = VStack(alignment: .leading, spacing: 16) {
                List {
                    Label {
                        Text("Export Settings")
                    } icon: {
                        Image(systemName: "gearshape")
                    }
                    .badge(model.newPhotosBadgeText)
                }
                .listStyle(.sidebar)
                .frame(height: 72)
                Button(model.primaryExportTitle(total: 93_015)) {}
                    .buttonStyle(.borderedProminent)
                    .help(model.primaryExportHelp(total: 93_015) ?? "")
            }
            .padding(20)
            .frame(width: 320)
            let image = try #require(await render(strip, size: NSSize(width: 360, height: 180), scheme: scheme))
            attachments.append(("toolbar-button-\(Self.name(scheme)).png", try Self.png(image)))
        }

        for (name, data) in attachments {
            Attachment.record(data, named: name)
            try? FileManager.default.createDirectory(at: Self.scratch, withIntermediateDirectories: true)
            try? data.write(to: Self.scratch.appending(path: name))
        }
    }

    /// The Export pane with a backup that has history but no New Photos watermark: the primary button reads
    /// "Export Photos by Date…", the subtitle says "1,243 not backed up", and the Backup pane's hero says the same.
    /// Renders the real main window in a titled window, so the toolbar and subtitle draw. Runs only with the env var.
    @Test func rendersExportPaneWithTheNewOnlyOffer() async throws {
        guard ProcessInfo.processInfo.environment["UNCLOUD_NEW_PHOTOS_SNAPSHOTS"] != nil else { return }
        let defaults = UserDefaults.standard
        let drive = FileManager.default.temporaryDirectory
            .appending(path: "uncloud-new-only-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: drive, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: drive) }

        // 93,015 in iCloud, of which 91,772 are already in the backup (the month layout the test uses).
        let savedAppleID = ICloudAccount.appleID
        let savedCount = defaults.object(forKey: "icloudLibraryCount")
        let savedSource = defaults.object(forKey: "librarySource")
        let savedLayout = defaults.object(forKey: "folderLayout")
        ICloudAccount.appleID = "preview@example.invalid"
        defaults.set(93_015, forKey: "icloudLibraryCount")
        defaults.set(LibrarySource.iCloud.rawValue, forKey: "librarySource")
        defaults.set(FolderLayout.month.rawValue, forKey: "folderLayout")
        defaults.removeObject(forKey: ExportModel.bookmarkKey)
        defer {
            ICloudAccount.appleID = savedAppleID
            defaults.set(savedCount, forKey: "icloudLibraryCount")
            defaults.set(savedSource, forKey: "librarySource")
            defaults.set(savedLayout, forKey: "folderLayout")
        }
        let records = (0..<91_772).map { index in
            (key: ExportManifest.iCloudIDPrefix + "asset-\(index)", paths: ["2001/01/IMG_\(index).JPG"])
        }
        try ExportManifest.appendRecords(records, in: drive)

        let model = ExportModel()
        model.chooseDestination(.success(drive))
        // The manifest is read in the background, which takes a while for this many records, so wait for its count.
        for _ in 0..<300 where model.onDriveCount != 91_772 {
            try await Task.sleep(for: .milliseconds(100))
        }
        model.pane = .export
        #expect(model.onDriveCount == 91_772)
        #expect(model.primaryExportTitle(total: 93_015) == "Export Photos by Date…")
        // No complete walk has measured iCloud's unlisted items yet, so the "not backed up" count isn't shown.
        #expect(model.trustedToGoCount == nil)
        #expect(model.notBackedUpSummary == nil)

        var attachments: [(String, Data)] = []
        for scheme in [ColorScheme.light, .dark] {
            let main = MainWindow()
                .environment(model)
                .environment(BackupTools(model: model))
                .environment(AccountModel.forTesting())
            let image = try #require(await renderWindow(main, size: NSSize(width: 1_000, height: 700), scheme: scheme))
            attachments.append(("export-pane-new-only-\(Self.name(scheme)).png", try Self.png(image)))

            let hero = BackupPane()
                .environment(model)
                .environment(BackupTools(model: model))
                .environment(AccountModel.forTesting())
            let heroImage = try #require(await renderWindow(hero, size: NSSize(width: 1_000, height: 700), scheme: scheme))
            attachments.append(("backup-pane-new-only-\(Self.name(scheme)).png", try Self.png(heroImage)))
        }

        for (name, data) in attachments {
            Attachment.record(data, named: name)
            try? FileManager.default.createDirectory(at: Self.scratch, withIntermediateDirectories: true)
            try? data.write(to: Self.scratch.appending(path: name))
        }
    }

    /// Renders a view in a titled window, so the window's frame, toolbar and subtitle draw as they do in the app.
    private func renderWindow<V: View>(_ view: V, size: NSSize, scheme: ColorScheme) async -> NSImage? {
        let page = view.environment(\.colorScheme, scheme)
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

    private func render<V: View>(_ view: V, size: NSSize, scheme: ColorScheme) async -> NSImage? {
        let page = view
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
        for _ in 0..<5 {
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
