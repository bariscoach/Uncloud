import AppKit
import SwiftUI
import Testing
@testable import Uncloud

/// The Tools pane's content: the cards per source, the locks, the disabled reasons and the last-result lines. Pure
/// data, so no view is needed. Also checks that a tool's last result survives `reset()`.
@MainActor
@Suite("Tools pane content")
struct ToolsPaneContentTests {
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)

    private static func cards(
        source: LibrarySource = .iCloud,
        allows: Bool = true,
        canOpen: Bool = true,
        isExporting: Bool = false,
        destinationIssue: String? = nil,
        hasPhotosAccess: Bool = true,
        results: ToolsPaneContent.Results = .init(),
        savedCheck: BackupVerification.SavedCheck = .none
    ) -> [ToolCardContent] {
        ToolsPaneContent.cards(
            source: source,
            allows: { _ in allows },
            canOpen: canOpen,
            isExporting: isExporting,
            destinationIssue: destinationIssue,
            hasPhotosAccess: hasPhotosAccess,
            results: results,
            savedCheck: savedCheck,
            now: now
        )
    }

    @Test func iCloudShowsTwoCardsAndMacShowsThree() {
        #expect(Self.cards(source: .iCloud).map(\.kind) == [.verify, .duplicates])
        #expect(Self.cards(source: .photosLibrary).map(\.kind) == [.verify, .duplicates, .freeUpSpace])
    }

    @Test func lockedToolShowsLockAndKeepsButtonEnabled() {
        let cards = Self.cards(allows: false, canOpen: false, isExporting: true)
        #expect(cards.allSatisfy { $0.isLocked && $0.isEnabled && $0.disabledReason == nil })
    }

    @Test func exportingGivesReasonAndDisablesButtons() {
        let cards = Self.cards(canOpen: false, isExporting: true)
        #expect(cards.allSatisfy { !$0.isEnabled && $0.disabledReason == "Available when the export finishes." })
    }

    @Test func destinationIssueIsTheReason() {
        let cards = Self.cards(canOpen: false, destinationIssue: "The backup folder is read-only.")
        #expect(cards.allSatisfy { $0.disabledReason == "The backup folder is read-only." })
    }

    @Test func freeUpSpaceNeedsPhotosAccess() {
        let card = Self.cards(source: .photosLibrary, hasPhotosAccess: false).first { $0.kind == .freeUpSpace }
        #expect(card?.isEnabled == false)
        #expect(card?.disabledReason == "Needs access to Photos.")
    }

    @Test func pausedCheckShowsWhenVerifyHasNoResult() {
        let verify = Self.cards(savedCheck: .resumable(percentDone: 42, checkedFiles: 20_000)).first { $0.kind == .verify }
        #expect(verify?.lastLine == "Paused at 42%. Continue it from the sheet.")
    }

    @Test func noResultReadsNotRunYet() {
        #expect(Self.cards().allSatisfy { $0.lastLine == "Not run yet." })
    }

    @Test func lastCheckReadsTodayAndTheResult() {
        let results = ToolsPaneContent.Results(verify: ToolResult(date: Self.now, text: "91,772 files OK", isProblem: false))
        let verify = Self.cards(results: results).first { $0.kind == .verify }
        #expect(verify?.lastLine == "Last check: today, 91,772 files OK.")
        #expect(verify?.lastIsProblem == false)
    }

    @Test func problemResultIsFlagged() {
        let results = ToolsPaneContent.Results(verify: ToolResult(date: Self.now, text: "3 files need attention", isProblem: true))
        let verify = Self.cards(results: results).first { $0.kind == .verify }
        #expect(verify?.lastIsProblem == true)
    }

    @Test func lastRunReadsYesterdayAndNeverDoublesThePeriod() throws {
        let yesterday = try #require(Calendar.current.date(byAdding: .day, value: -1, to: Self.now))
        let results = ToolsPaneContent.Results(
            duplicates: ToolResult(date: yesterday, text: "12 duplicates removed", isProblem: false),
            freeUpSpace: ToolResult(date: Self.now, text: "Exporting 3 photos again.", isProblem: false)
        )
        let cards = Self.cards(source: .photosLibrary, results: results)
        #expect(cards.first { $0.kind == .duplicates }?.lastLine == "Last run: yesterday, 12 duplicates removed.")
        #expect(cards.first { $0.kind == .freeUpSpace }?.lastLine == "Last run: today, Exporting 3 photos again.")
    }

    // MARK: - Last result survives reset()

    @Test func verifyResultSurvivesReset() async throws {
        try await withTemporaryDirectoryAsync { drive in
            let model = ExportModel()
            UserDefaults.standard.removeObject(forKey: ExportModel.bookmarkKey)
            model.chooseDestination(.success(drive))
            try await Task.sleep(for: .milliseconds(800))

            let verification = BackupVerification(model: model)
            verification.start(.quick)
            try await Self.waitUntil { !verification.isBusy }
            let result = try #require(verification.lastResult)

            verification.reset()
            #expect(verification.lastResult == result)
        }
    }

    @Test func duplicatesResultSurvivesReset() async throws {
        try await withTemporaryDirectoryAsync { drive in
            let model = ExportModel()
            UserDefaults.standard.removeObject(forKey: ExportModel.bookmarkKey)
            model.chooseDestination(.success(drive))
            try await Task.sleep(for: .milliseconds(800))

            // An empty backup has no duplicates, so the scan ends at `.noneFound`.
            let cleanup = DuplicateCleanup(model: model)
            cleanup.start()
            try await Self.waitUntil { !cleanup.isBusy }
            #expect(cleanup.lastResult?.text == "No duplicates")
            #expect(cleanup.lastResult?.isProblem == false)

            let result = try #require(cleanup.lastResult)
            cleanup.reset()
            #expect(cleanup.lastResult == result)
        }
    }

    private static func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<600 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw CancellationError()
    }
}

/// Renders the Tools pane's cards for each source and plan, in light and dark. Runs only when
/// `UNCLOUD_TOOLS_PANE_SNAPSHOTS` is set; run with `TEST_RUNNER_UNCLOUD_TOOLS_PANE_SNAPSHOTS=1`, then export the
/// PNGs from the result bundle with `xcrun xcresulttool export attachments`.
private let toolsPaneSnapshotsEnabled = ProcessInfo.processInfo.environment["UNCLOUD_TOOLS_PANE_SNAPSHOTS"] != nil

@MainActor
@Suite("Tools pane snapshots", .enabled(if: toolsPaneSnapshotsEnabled))
struct ToolsPaneSnapshotTests {
    @Test func rendersToolsPaneForEachSourceAndPlanInLightAndDark() async throws {
        let now = Date.now
        let results = ToolsPaneContent.Results(
            verify: ToolResult(date: now, text: "91,772 files OK", isProblem: false),
            duplicates: nil,
            freeUpSpace: ToolResult(date: now, text: "2,310 photos removed", isProblem: false)
        )
        for source in [LibrarySource.iCloud, .photosLibrary] {
            for plus in [false, true] {
                for scheme in [ColorScheme.light, .dark] {
                    let cards = ToolsPaneContent.cards(
                        source: source,
                        allows: { _ in plus },
                        canOpen: true,
                        isExporting: false,
                        destinationIssue: nil,
                        hasPhotosAccess: true,
                        results: results,
                        savedCheck: .none,
                        now: now
                    )
                    let height: CGFloat = source == .iCloud ? 560 : 720
                    let image = try #require(await Self.render(
                        ToolsForm(cards: cards, open: { _ in }),
                        size: NSSize(width: 640, height: height),
                        scheme: scheme
                    ))
                    let sourceName = source == .iCloud ? "icloud" : "mac"
                    let plan = plus ? "plus" : "free"
                    let appearance = scheme == .dark ? "dark" : "light"
                    Attachment.record(try Self.png(image), named: "tools-\(sourceName)-\(plan)-\(appearance).png")
                }
            }
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
    private static func render<V: View>(_ view: V, size: NSSize, scheme: ColorScheme) async -> NSImage? {
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
        defer { window.close() }
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
        host.cacheDisplay(in: host.bounds, to: rep)
        let image = NSImage(size: size)
        image.addRepresentation(rep)
        return image
    }
}
