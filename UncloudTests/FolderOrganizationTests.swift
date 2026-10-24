import AppKit
import SwiftUI
import Testing
@testable import Uncloud

@Suite("FolderOrganization")
struct FolderOrganizationTests {
    @Test func clashRuleNamesTheSizeSuffixForICloud() {
        #expect(FolderLayout.clashRule(for: .iCloud) == "If two files share a name, the second gets its size added: IMG_0001-2483921.HEIC.")
    }

    @Test func clashRuleNamesTheNumberForPhotosOnThisMac() {
        #expect(FolderLayout.clashRule(for: .photosLibrary) == "If two files share a name, the second gets a number: IMG_0001 (1).HEIC.")
    }

    @Test func flatCaptionIsOnlyTheFirstSentence() {
        for source in LibrarySource.allCases {
            #expect(FolderLayout.flat.caption(for: source) == "Everything goes straight into your backup folder, with no subfolders.")
        }
    }

    @Test func automaticBackupStatusCoversEveryCombination() {
        #expect(AutomaticBackupStatus.text(connects: true, daily: true) == "On: when the drive connects and daily")
        #expect(AutomaticBackupStatus.text(connects: true, daily: false) == "On: when the drive connects")
        #expect(AutomaticBackupStatus.text(connects: false, daily: true) == "On: once a day")
        #expect(AutomaticBackupStatus.text(connects: false, daily: false) == "Off")
    }
}

/// Renders General and Folder Organization in light and dark. Runs only with
/// `TEST_RUNNER_UNCLOUD_EXPORT_SETTINGS_SNAPSHOTS=1`; the PNGs are attachments of the result bundle, exported with
/// `xcrun xcresulttool export attachments`.
@MainActor
@Suite("ExportSettingsSnapshot")
struct ExportSettingsSnapshotTests {
    @Test func rendersBothSectionsInLightAndDark() async throws {
        guard ProcessInfo.processInfo.environment["UNCLOUD_EXPORT_SETTINGS_SNAPSHOTS"] != nil else { return }

        let drive = FileManager.default.temporaryDirectory
            .appending(path: "uncloud-export-settings-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: drive, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: drive) }

        // The pane shows its sections only when the source is ready. The Apple ID is set for the preview only and put
        // back afterwards, as DesignSnapshotTests does.
        let savedAppleID = ICloudAccount.appleID
        ICloudAccount.appleID = "preview@example.invalid"
        defer { ICloudAccount.appleID = savedAppleID }

        let model = ExportModel()
        model.chooseDestination(.success(drive))
        // Sessions and the on-drive count load in the background.
        try await Task.sleep(for: .milliseconds(800))

        var images: [(String, NSImage)] = []
        for section in ExportModel.ExportSettingsSection.allCases {
            model.exportSettingsSection = section
            for scheme in [ColorScheme.light, .dark] {
                let pane = ExportSettingsPane()
                    .environment(model)
                    .environment(AccountModel.forTesting())
                    .environment(AutoBackupSettings())
                let image = try #require(await Self.renderWindow(pane, size: NSSize(width: 620, height: 900), scheme: scheme))
                images.append(("export-settings-\(section == .general ? "general" : "folders")-\(scheme == .dark ? "dark" : "light")", image))
            }
        }
        model.exportSettingsSection = .general

        for (name, image) in images {
            Attachment.record(try Self.png(image), named: "\(name).png")
        }
    }

    private static func png(_ image: NSImage) throws -> Data {
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let data = rep.representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return data
    }

    /// Renders a view in a borderless offscreen window of the given size.
    private static func renderWindow<V: View>(_ view: V, size: NSSize, scheme: ColorScheme) async -> NSImage? {
        let page = view
            .environment(\.colorScheme, scheme)
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
}
