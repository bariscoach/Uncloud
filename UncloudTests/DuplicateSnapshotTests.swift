import AppKit
import SwiftUI
import Testing
@testable import Uncloud

/// Renders the Find Duplicates sheet for design review, in light and dark. Runs only when the
/// `UNCLOUD_SNAPSHOT_DIR` environment variable names a folder, and writes the PNGs there.
/// The drive is a temporary folder of fabricated files, and the Trash is replaced by a delete.
/// The folder for the PNGs, from the environment; nil skips the suite.
private let duplicateSnapshotDirectory: URL? = ProcessInfo.processInfo.environment["UNCLOUD_SNAPSHOT_DIR"].map {
    URL(fileURLWithPath: $0, isDirectory: true)
}

@MainActor
@Suite("Find Duplicates snapshots", .enabled(if: duplicateSnapshotDirectory != nil))
struct DuplicateSnapshotTests {
    @Test func rendersFoundAndFinishedInLightAndDark() async throws {
        let output = try #require(duplicateSnapshotDirectory)
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        try await withTemporaryDirectoryAsync { drive in
            try Self.writeSampleDrive(in: drive)

            let model = ExportModel()
            UserDefaults.standard.removeObject(forKey: ExportModel.bookmarkKey)
            model.chooseDestination(.success(drive))
            try await Task.sleep(for: .milliseconds(800))

            let cleanup = DuplicateCleanup(model: model)
            cleanup.trasher = { try FileManager.default.removeItem(at: $0) }
            cleanup.notifier = { _, _ in }
            cleanup.start()
            try await Self.wait(for: cleanup) { if case .found = $0 { true } else { false } }

            for scheme in [ColorScheme.light, .dark] {
                let image = try #require(await Self.render(
                    FindDuplicatesSheet(cleanup: cleanup).environment(model),
                    size: NSSize(width: 920, height: 660), scheme: scheme
                ))
                try Self.save(image, named: "library-\(Self.name(scheme)).png", in: output)
            }

            for scheme in [ColorScheme.light, .dark] {
                let image = try #require(await Self.render(
                    ConfirmationPreview(copies: cleanup.duplicateCount, bytes: cleanup.duplicateBytes, volume: "Backup"),
                    size: NSSize(width: 460, height: 260), scheme: scheme
                ))
                try Self.save(image, named: "confirmation-\(Self.name(scheme)).png", in: output)
            }

            cleanup.removeCopies()
            try await Self.wait(for: cleanup) { if case .finished = $0 { true } else { false } }

            for scheme in [ColorScheme.light, .dark] {
                let image = try #require(await Self.render(
                    FindDuplicatesSheet(cleanup: cleanup).environment(model),
                    size: NSSize(width: 600, height: 300), scheme: scheme
                ))
                try Self.save(image, named: "finished-\(Self.name(scheme)).png", in: output)
            }
        }
    }

    /// The alert's title and message, laid out as the alert lays them out. An offscreen host can't show an alert, so this
    /// stands in for it; the strings are the ones the app's alert uses.
    private struct ConfirmationPreview: View {
        let copies: Int
        let bytes: Int64
        let volume: String

        var body: some View {
            VStack(alignment: .leading, spacing: 12) {
                Text(DuplicateWording.confirmationTitle(copies: copies))
                    .font(.headline)
                Text(DuplicateWording.confirmationMessage(copies: copies, bytes: bytes, volume: volume))
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer()
                    Button("Cancel") {}
                    Button("Move to Trash") {}
                        .buttonStyle(.borderedProminent)
                }
            }
            .padding(20)
            .frame(width: 420, alignment: .leading)
        }
    }

    // MARK: - Fabricated drive

    /// Three groups: three copies of one photo with different names, a Live Photo exported twice, and two copies
    /// of an album photo. Also extra copies in the month folder of three flat photos, and two iCloud items that share a file.
    private static func writeSampleDrive(in drive: URL) throws {
        let manifest = try ExportManifest(destination: drive)
        let photo = String(repeating: "p", count: 3_000_000)
        let movie = String(repeating: "m", count: 8_000_000)
        let albumPhoto = String(repeating: "a", count: 2_000_000)

        try save(manifest, id: "A1", files: ["2024/07/IMG_0101.HEIC": photo], in: drive)
        try save(manifest, id: "A2", files: ["2024/07/IMG_0101 copy.HEIC": photo], in: drive)
        try save(manifest, id: "A3", files: ["2024/07/IMG_0101-2483921.JPG": photo], in: drive)

        try save(manifest, id: "B1", files: ["2024/07/IMG_0102.HEIC": photo, "2024/07/IMG_0102.MOV": movie], in: drive)
        try save(manifest, id: "B2", files: ["2024/07/IMG_0102 (1).HEIC": photo, "2024/07/IMG_0102 (1).MOV": movie], in: drive)

        try save(manifest, id: "C1", files: ["Trips/IMG_0200.HEIC": albumPhoto], in: drive)
        try save(manifest, id: "C2", files: ["Trips/IMG_0200 copy.HEIC": albumPhoto], in: drive)

        // Extra copies: photos saved in the month folder by a run before the layout changed to flat, and again flat.
        try manifest.recordLayout(.flat)
        for number in 300...302 {
            let name = "IMG_0\(number).HEIC"
            let distinct = photo + "\(number)"
            try save(manifest, id: "D\(number)", files: ["2026/10/\(name)": distinct, name: distinct], in: drive)
        }

        // Shared iCloud items: two items that saved the same file in the flat folder.
        try save(manifest, id: "E1", files: ["IMG_0400.HEIC": albumPhoto], in: drive)
        try save(manifest, id: "E2", files: ["IMG_0400.HEIC": albumPhoto], in: drive)
    }

    private static func save(_ manifest: ExportManifest, id: String, files: [String: String], in drive: URL) throws {
        var checksums: [String: String] = [:]
        for (path, text) in files {
            try writeFile(text, to: path, in: drive)
            checksums[path] = try FileHasher.sha256(of: drive.appending(path: path))
        }
        try manifest.recordICloudItem(id: id, paths: files.keys.sorted())
        try manifest.recordChecksums(checksums)
    }

    // MARK: - Helpers

    /// Polls until the cleanup reaches a state, so the render sees the settled sheet.
    private static func wait(for cleanup: DuplicateCleanup, until isReady: (DuplicateCleanup.State) -> Bool) async throws {
        for _ in 0..<300 {
            if isReady(cleanup.state) { return }
            try await Task.sleep(for: .milliseconds(50))
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

    /// Hosts the view in an offscreen window and captures it, as the other snapshot tests do.
    private static func render<V: View>(_ view: V, size: NSSize, scheme: ColorScheme) async -> NSImage? {
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
        // Key window, so prominent buttons draw in the accent colour as they do in the app.
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        for _ in 0..<8 {
            host.layoutSubtreeIfNeeded()
            try? await Task.sleep(for: .milliseconds(100))
        }

        defer { window.close() }
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
        host.cacheDisplay(in: host.bounds, to: rep)
        let image = NSImage(size: size)
        image.addRepresentation(rep)
        return image
    }
}
