import AppKit
import SwiftUI
import Testing
@testable import Uncloud

/// Renders the Verify Backup sheet in each state (ready, a stopped full check, a running check, quick results, full
/// results), in light and dark. Runs only when UNCLOUD_VERIFY_SHEET_SNAPSHOTS is set, so a normal run writes nothing.
/// Run with `TEST_RUNNER_UNCLOUD_VERIFY_SHEET_SNAPSHOTS=1`, then export the PNGs from the result bundle with
/// `xcrun xcresulttool export attachments`, as the other snapshot suites do.
@MainActor
@Suite("VerifySheetSnapshot")
struct VerifySheetSnapshotTests {
    private static let destination = URL(fileURLWithPath: "/Volumes/Backup/Uncloud", isDirectory: true)

    @Test func rendersVerifySheetStates() async throws {
        guard ProcessInfo.processInfo.environment["UNCLOUD_VERIFY_SHEET_SNAPSHOTS"] != nil else { return }
        let model = ExportModel()
        let now = Date()
        var images: [(String, NSImage)] = []
        for scheme in [ColorScheme.light, .dark] {
            for (name, verification) in Self.states(model: model, now: now) {
                let sheet = VerifyBackupSheet(verification: verification)
                    .environment(model)
                let image = try #require(await Self.renderWindow(sheet, size: NSSize(width: 520, height: 600), scheme: scheme))
                images.append(("verify-\(name)-\(scheme == .dark ? "dark" : "light")", image))
            }
        }
        for (name, image) in images {
            Attachment.record(try Self.png(image), named: "\(name).png")
        }
    }

    /// One verification per sheet state, built the way the app builds them.
    private static func states(model: ExportModel, now: Date) -> [(String, BackupVerification)] {
        let quickReport = QuickVerifyReport(
            checkedFiles: 45_831,
            okItems: 41_000,
            seconds: 4.2,
            missingFiles: ["2024/07/IMG_0412.HEIC", "2024/07/IMG_0413.HEIC"],
            emptyFiles: ["2024/08/IMG_0007.MOV"],
            changedFiles: ["2024/06/IMG_1180.JPG"],
            sizeMismatchItemIDs: ["icloud-id:AAA"],
            problemItemIDs: ["icloud-id:AAA", "local-1", "local-2"]
        )
        let quickProblems = BackupVerification.QuickSummary(
            destination: destination,
            report: quickReport,
            affectedFiles: ["2024/06/IMG_1180.JPG", "2024/07/IMG_0412.HEIC", "2024/07/IMG_0413.HEIC", "2024/08/IMG_0007.MOV"],
            affectedFileCount: 4
        )
        let quickClean = BackupVerification.QuickSummary(
            destination: destination,
            report: QuickVerifyReport(
                checkedFiles: 45_831, okItems: 41_000, seconds: 0.4, missingFiles: [], emptyFiles: [], changedFiles: [],
                sizeMismatchItemIDs: [], problemItemIDs: []
            ),
            affectedFiles: [],
            affectedFileCount: 0
        )
        let progress = BackupVerification.Progress(
            check: .full,
            done: 20_100,
            total: 45_831,
            bytesRead: 3_200_000_000,
            startedAt: now.addingTimeInterval(-600),
            baseline: 0
        )
        let summary = BackupVerification.Summary(
            destination: destination,
            checkedFileCount: 45_831,
            verifiedCount: 41_010,
            damagedCount: 2,
            unverifiableCount: 0,
            notBackedUpCount: nil,
            affectedFiles: ["2024/07/IMG_0412.HEIC", "2024/07/IMG_0413.HEIC"],
            affectedFileCount: 2,
            reexportIDs: [],
            notInLibraryCount: 0,
            resumedFromCheckpoint: true,
            restartReason: nil
        )
        return [
            ("ready", BackupVerification(model: model, savedCheck: BackupVerification.SavedCheck.none)),
            ("ready-resumable", BackupVerification(model: model, savedCheck: .resumable(percentDone: 44, checkedFiles: 20_100))),
            ("checking-full", BackupVerification(model: model, initialState: .checking(progress), savedCheck: BackupVerification.SavedCheck.none)),
            ("quick-clean", BackupVerification(model: model, initialState: .quickFinished(quickClean), savedCheck: BackupVerification.SavedCheck.none)),
            ("quick-problems", BackupVerification(model: model, initialState: .quickFinished(quickProblems), savedCheck: BackupVerification.SavedCheck.none)),
            ("full-resumed", BackupVerification(model: model, initialState: .finished(summary), savedCheck: BackupVerification.SavedCheck.none)),
        ]
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
}
