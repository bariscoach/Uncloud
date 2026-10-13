import AppKit
import SwiftUI
import Testing
@testable import Uncloud

/// Renders the Export History and Check Drive views to PNG files for design review, in light and dark.
/// The PNGs go to the session scratch folder only when that folder exists, so the test passes everywhere
/// else without writing anything.
@MainActor
@Suite("DesignSnapshot")
struct DesignSnapshotTests {
    private static let scratch = URL(
        fileURLWithPath: "/private/tmp/claude-501/-Users-barishiz-Developer-icloud-photo-export/df886b0f-d79a-4d1c-973d-23c5d89614c2/scratchpad",
        isDirectory: true
    )

    @Test func rendersExportHistoryInLightAndDark() async throws {
        guard Self.scratchIsWritable else { return }
        let chains = Self.sampleChains()
        for scheme in [ColorScheme.light, .dark] {
            let page = Form {
                ExportHistoryView(chains: chains, unavailableText: nil, showInFinder: {})
            }
            .formStyle(.grouped)
            try save(await render(page, size: NSSize(width: 520, height: 720), scheme: scheme),
                     named: "export-history-\(Self.name(scheme)).png")
        }
    }

    @Test func rendersSessionDetailInLightAndDark() async throws {
        guard Self.scratchIsWritable else { return }
        let chain = Self.sampleChains()[0]
        for scheme in [ColorScheme.light, .dark] {
            try save(await render(ExportSessionDetailView(chain: chain), size: NSSize(width: 560, height: 760), scheme: scheme),
                     named: "session-detail-\(Self.name(scheme)).png")
        }
    }

    /// The whole Backup pane, with a drive that holds fabricated sessions and about 9,200 exported items.
    /// The PNGs are attached to the test result, since the sandboxed test host can't see the scratch folder.
    @Test func rendersBackupPaneInLightAndDark() async throws {
        let defaults = UserDefaults.standard
        let drive = FileManager.default.temporaryDirectory
            .appending(path: "uncloud-preview-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: drive, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: drive) }

        // Exports read from the drive's journal and session files; the library count and Apple ID are set for
        // the preview only and put back afterwards.
        let store = SessionStore(destination: drive)
        for session in Self.sampleSessions() {
            try store.write(session)
        }
        let records = (0..<9_207).map { index in
            (key: "preview-\(index)", paths: ["2024/0\(index % 9 + 1)/IMG_\(10_000 + index).HEIC"])
        }
        try ExportManifest.appendRecords(records, in: drive)

        let savedAppleID = ICloudAccount.appleID
        let savedCount = defaults.object(forKey: "icloudLibraryCount")
        ICloudAccount.appleID = "preview@example.invalid"
        defaults.set(93_015, forKey: "icloudLibraryCount")
        defer {
            ICloudAccount.appleID = savedAppleID
            defaults.set(savedCount, forKey: "icloudLibraryCount")
        }

        defaults.removeObject(forKey: ExportModel.bookmarkKey)
        let model = ExportModel()
        model.chooseDestination(.success(drive))
        // Sessions and the on-drive count load in the background.
        try await Task.sleep(for: .milliseconds(800))

        for scheme in [ColorScheme.light, .dark] {
            let pane = BackupPane()
                .environment(model)
                .environment(BackupTools(model: model))
            let image = try #require(await render(pane, size: NSSize(width: 560, height: 1_480), scheme: scheme))
            let name = "backup-pane-\(Self.name(scheme)).png"
            Attachment.record(try Self.pngData(image), named: name)
            try save(image, named: name)
        }
    }

    @Test func rendersCheckDriveInLightAndDark() async throws {
        guard Self.scratchIsWritable else { return }
        for scheme in [ColorScheme.light, .dark] {
            let row = Form {
                Section {
                    DriveSummaryRow(
                        summary: "about 9,207 already on this drive · about 83,808 to go",
                        lastChecked: Date().addingTimeInterval(-3_600),
                        isChecking: false, progressText: nil, canCheck: true,
                        onCheck: {}, onCancel: {}
                    )
                    DriveSummaryRow(
                        summary: nil, lastChecked: nil,
                        isChecking: true, progressText: "41,000 of about 93,000 files", canCheck: false,
                        onCheck: {}, onCancel: {}
                    )
                } header: {
                    Text("Export")
                }
            }
            .formStyle(.grouped)
            try save(await render(row, size: NSSize(width: 520, height: 260), scheme: scheme),
                     named: "check-drive-row-\(Self.name(scheme)).png")

            try save(await render(CheckDriveResultsSheet(report: Self.sampleReport(), source: .iCloud, onShowSetAside: {}),
                                  size: NSSize(width: 520, height: 760), scheme: scheme),
                     named: "check-drive-results-\(Self.name(scheme)).png")
        }
    }

    // MARK: - Fabricated values

    private static func name(_ scheme: ColorScheme) -> String {
        scheme == .dark ? "dark" : "light"
    }

    private static var scratchIsWritable: Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: scratch.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    /// Four chains, newest first: a completed one, one with failures and automatic resumes, one stopped and
    /// waiting to resume, and one cancelled from an earlier day.
    static func sampleChains() -> [ExportHistoryChain] {
        ExportHistory.chains(from: sampleSessions(), pendingResume: AutoResume(
            attempt: 2, resumeAt: Date().addingTimeInterval(3_600 * 0.5), reason: "The iCloud session expired",
            selection: nil, automatic: false, isWaitingForDestination: false
        ))
    }

    /// The sessions behind `sampleChains`, as a drive would hold them.
    static func sampleSessions() -> [ExportSession] {
        let now = Date()
        let hour: TimeInterval = 3_600

        // Completed in one run, started this morning.
        let completedID = UUID()
        let completed = session(
            chainID: completedID, attempt: 1, trigger: .manual, startedAt: now.addingTimeInterval(-hour * 3),
            endedAt: now.addingTimeInterval(-hour * 2.2), status: .completed,
            exported: 2_604, skipped: 3_614, failed: 0, bytes: 7_400_000_000, source: .iCloud,
            check: driveCheck(onDrive: 3_614, toGo: 2_604)
        )

        // Completed with failures after two automatic resumes, started yesterday.
        let resumedID = UUID()
        let resumedFirst = session(
            chainID: resumedID, attempt: 1, trigger: .automaticBackup, startedAt: now.addingTimeInterval(-hour * 30),
            endedAt: now.addingTimeInterval(-hour * 29.5), status: .failed, reason: "Apple is limiting downloads",
            exported: 900, skipped: 9_207, failed: 0, bytes: 2_100_000_000, source: .iCloud,
            check: driveCheck(onDrive: 9_207, toGo: 83_808), retryable: true,
            autoResume: ExportSession.AutoResumeNote(attempt: 2, resumeAt: now.addingTimeInterval(-hour * 28))
        )
        let resumedSecond = session(
            chainID: resumedID, attempt: 2, trigger: .autoResume, startedAt: now.addingTimeInterval(-hour * 28),
            endedAt: now.addingTimeInterval(-hour * 27), status: .failed, reason: "Apple is limiting downloads",
            exported: 1_100, skipped: 10_107, failed: 0, bytes: 2_600_000_000, source: .iCloud,
            retryable: true,
            autoResume: ExportSession.AutoResumeNote(attempt: 3, resumeAt: now.addingTimeInterval(-hour * 26))
        )
        let resumedThird = session(
            chainID: resumedID, attempt: 3, trigger: .autoResume, startedAt: now.addingTimeInterval(-hour * 26),
            endedAt: now.addingTimeInterval(-hour * 24.5), status: .completedWithFailures,
            exported: 600, skipped: 11_207, failed: 12, bytes: 1_300_000_000, source: .iCloud,
            failures: [
                ExportSession.Failure(name: "IMG_4021.HEIC", reason: "Apple sent a damaged file"),
                ExportSession.Failure(name: "IMG_4022.MOV", reason: "The download timed out"),
            ]
        )

        // Stopped and waiting to resume at 15:10.
        let waitingID = UUID()
        let waiting = session(
            chainID: waitingID, attempt: 1, trigger: .manual, startedAt: now.addingTimeInterval(-hour * 0.5),
            endedAt: now.addingTimeInterval(-hour * 0.4), status: .failed, reason: "The iCloud session expired",
            exported: 120, skipped: 0, failed: 0, bytes: 180_000_000, source: .iCloud,
            retryable: true, autoResume: ExportSession.AutoResumeNote(attempt: 2, resumeAt: now.addingTimeInterval(hour * 0.5))
        )

        // Cancelled on an earlier day, copied from the Photos library.
        let cancelled = session(
            chainID: UUID(), attempt: 1, trigger: .exportAll, startedAt: now.addingTimeInterval(-hour * 96),
            endedAt: now.addingTimeInterval(-hour * 95.5), status: .cancelled,
            exported: 40, skipped: 0, failed: 0, bytes: 0, source: .photosLibrary
        )

        return [completed, resumedFirst, resumedSecond, resumedThird, waiting, cancelled]
    }

    private static func session(
        chainID: UUID,
        attempt: Int,
        trigger: ExportSession.Trigger,
        startedAt: Date,
        endedAt: Date,
        status: ExportSession.Status,
        reason: String? = nil,
        exported: Int,
        skipped: Int,
        failed: Int,
        bytes: Int,
        source: LibrarySource,
        check: ExportSession.DriveCheckSummary? = nil,
        retryable: Bool? = nil,
        autoResume: ExportSession.AutoResumeNote? = nil,
        failures: [ExportSession.Failure] = []
    ) -> ExportSession {
        var made = ExportSession(
            id: UUID(),
            chainID: chainID,
            attempt: attempt,
            trigger: trigger,
            startedAt: startedAt,
            appVersion: "0.1.4 (5)",
            launchID: UUID(),
            source: source,
            layout: .placeThenMonth,
            writesSidecars: true,
            selection: ExportSession.SelectionSummary(kind: .everything, count: 93_015)
        )
        made.endedAt = endedAt
        made.updatedAt = endedAt
        made.counts = ExportSession.Counts(exported: exported, skipped: skipped, failed: failed, bytesWritten: bytes)
        made.result = ExportSession.Result(status: status, reason: reason, retryable: retryable)
        made.driveCheck = check
        made.autoResume = autoResume
        made.failures = failures
        if attempt > 1 {
            made.continuation = ExportSession.Continuation(strategy: .fromRank, startRank: 9_207, fallbackReason: nil)
        }
        return made
    }

    private static func driveCheck(onDrive: Int, toGo: Int) -> ExportSession.DriveCheckSummary {
        ExportSession.DriveCheckSummary(
            onDrive: onDrive, toGo: toGo, missing: 12, damaged: 3, setAside: 3, untracked: 4, mode: .quick, seconds: 1.2
        )
    }

    static func sampleReport() -> DriveCheckReport {
        DriveCheckReport(
            mode: .full,
            selectedCount: 93_015,
            onDrive: 9_207,
            isApproximate: false,
            toGo: 83_808,
            missingItems: 12,
            missingFiles: (1...12).map { "2024/0\($0)/IMG_\(1000 + $0).HEIC" },
            damagedFiles: ["2023/07/IMG_2201.JPG", "2023/07/IMG_2202.MOV", "2023/08/IMG_2310.HEIC"],
            setAsideFiles: ["2023/07/IMG_2201.JPG", "2023/07/IMG_2202.MOV", "2023/08/IMG_2310.HEIC"],
            setAsideFolder: "check-2026-10-13T09-14-02Z",
            registeredFiles: ["2025/01/IMG_5001.HEIC", "2025/01/IMG_5002.HEIC"],
            otherFiles: 4,
            partialFiles: 2,
            partialItems: 1,
            filesListed: 94_122,
            seconds: 41.6
        )
    }

    // MARK: - Rendering

    private static func pngData(_ image: NSImage) throws -> Data {
        let tiff = try #require(image.tiffRepresentation)
        let bitmap = try #require(NSBitmapImageRep(data: tiff))
        return try #require(bitmap.representation(using: .png, properties: [:]))
    }

    /// Writes to the scratch folder. The sandboxed test host can be refused there, so it falls back to its
    /// own temporary folder rather than failing the run.
    private func save(_ image: NSImage?, named name: String) throws {
        let image = try #require(image)
        let tiff = try #require(image.tiffRepresentation)
        let bitmap = try #require(NSBitmapImageRep(data: tiff))
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        do {
            try png.write(to: Self.scratch.appending(path: name))
        } catch {
            try png.write(to: FileManager.default.temporaryDirectory.appending(path: name))
        }
    }

    /// Hosts the view in an offscreen window and captures it with cacheDisplay, as LandingSnapshotTests does.
    private func render<V: View>(_ view: V, size: NSSize, scheme: ColorScheme) async -> NSImage? {
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
        for _ in 0..<5 {
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
