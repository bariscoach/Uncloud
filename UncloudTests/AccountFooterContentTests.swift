import AppKit
import SwiftUI
import Testing
@testable import Uncloud

/// Every string and dot rule of the account row (plan §6.2 to §6.4). Pure: the summaries come from the summary tests'
/// helpers, so the clock is fixed.
@Suite("AccountFooterContent")
struct AccountFooterContentTests {
    static let now = AccountSummaryTests.now
    static let day = AccountSummaryTests.day

    static func content(
        _ summary: AccountSummary,
        mode: AccountMode = .preview,
        source: LibrarySource = .iCloud,
        appleID: String? = "name@icloud.com",
        isSourceReady: Bool = true
    ) -> AccountFooterContent {
        AccountFooterContent.make(summary: summary, accountMode: mode, source: source, appleID: appleID, isSourceReady: isSourceReady)
    }

    static func free() -> AccountSummary {
        AccountSummaryTests.signedIn(AccountSummaryTests.plan(.none, periodEnd: nil), now: now)
    }

    static func plus() -> AccountSummary {
        AccountSummaryTests.signedIn(AccountSummaryTests.plan(.active, periodEnd: now.addingTimeInterval(30 * day)), now: now)
    }

    static func pastDue() -> AccountSummary {
        AccountSummaryTests.signedIn(AccountSummaryTests.plan(.pastDue, periodEnd: now.addingTimeInterval(-day)), now: now)
    }

    static func offlineGrace() -> AccountSummary {
        AccountSummaryTests.signedIn(AccountSummaryTests.plan(.active, periodEnd: now.addingTimeInterval(-day)), now: now)
    }

    static func loading() -> AccountSummary {
        AccountSummary.make(
            mode: .preview, phase: .restoring, account: nil,
            entitlement: AccountSummaryTests.plan(.none, periodEnd: nil), access: .free, lastError: nil, now: now
        )
    }

    @Test func freeWithICloudConnected() {
        let row = Self.content(Self.free())
        #expect(row.line1 == "name@example.com")
        #expect(row.line2 == "Free · iCloud Photos")
        #expect(!row.needsAttention)
        #expect(row.showsUncloudSection)
        #expect(row.sourceStateText == "Connected")
        #expect(!row.sourceStateIsWarning)
        #expect(row.accessibilityValue == "name@example.com, Free, iCloud Photos, signed in as name@icloud.com")
    }

    @Test func plusRenewingLineTwo() {
        let row = Self.content(Self.plus())
        #expect(row.line2 == "Plus · iCloud Photos")
        #expect(!row.needsAttention)
    }

    @Test func paymentDueNeedsAttention() {
        let row = Self.content(Self.pastDue())
        #expect(row.line2 == "Plus, payment due · iCloud Photos")
        #expect(row.needsAttention)
        #expect(row.accessibilityValue.hasSuffix("needs attention"))
    }

    @Test func offlineGraceNeedsAttention() {
        let row = Self.content(Self.offlineGrace())
        #expect(row.line2 == "Plus, not checked · iCloud Photos")
        #expect(row.needsAttention)
    }

    @Test func iCloudSignedOutNeedsAttention() {
        let row = Self.content(Self.free(), appleID: nil)
        #expect(row.line2 == "Free · iCloud: not signed in")
        #expect(row.needsAttention)
        #expect(row.sourceStateText == "Not signed in")
        #expect(row.sourceStateIsWarning)
        #expect(row.accessibilityValue == "name@example.com, Free, iCloud Photos, not signed in, needs attention")
    }

    @Test func photosOnThisMacReadyHasNoDot() {
        let row = Self.content(Self.free(), source: .photosLibrary, appleID: nil)
        #expect(row.line2 == "Free · Photos on This Mac")
        #expect(!row.needsAttention)
        #expect(row.sourceStateText == "Ready")
        #expect(row.accessibilityValue.hasSuffix("Photos on This Mac, ready"))
    }

    @Test func photosOnThisMacNeedsAccessHasDot() {
        let row = Self.content(Self.free(), source: .photosLibrary, appleID: nil, isSourceReady: false)
        #expect(row.line2 == "Free · Photos: needs access")
        #expect(row.needsAttention)
        #expect(row.sourceStateText == "Needs access")
        #expect(row.sourceStateIsWarning)
    }

    @Test func loadingShowsPlaceholderAndNoDot() {
        let row = Self.content(Self.loading(), appleID: nil)
        #expect(row.line1 == "Uncloud")
        #expect(row.line2 == "Loading…")
        #expect(!row.needsAttention)
        #expect(row.showsUncloudSection)
    }

    @Test func accountsOffShowsAppleIDAndNoUncloudSection() {
        let summary = AccountSummary.make(
            mode: .off, phase: .signedIn, account: nil,
            entitlement: AccountSummaryTests.plan(.none, periodEnd: nil), access: .free, lastError: nil, now: Self.now
        )
        let row = Self.content(summary, mode: .off)
        #expect(row.line1 == "name@icloud.com")
        #expect(row.line2 == "iCloud Photos")
        #expect(!row.showsUncloudSection)
        #expect(!row.needsAttention)
    }

    @Test func accountsOffMacShowsSourceTitle() {
        let summary = AccountSummary.make(
            mode: .off, phase: .signedIn, account: nil,
            entitlement: AccountSummaryTests.plan(.none, periodEnd: nil), access: .free, lastError: nil, now: Self.now
        )
        let row = Self.content(summary, mode: .off, source: .photosLibrary, appleID: nil)
        #expect(row.line1 == "Photos on This Mac")
        #expect(row.line2 == "Photos on This Mac")
        #expect(!row.showsUncloudSection)
    }

    @Test func signedOutOfUncloudHidesTheAccountSection() {
        let summary = AccountSummary.make(
            mode: .preview, phase: .signedOut(.welcome), account: nil,
            entitlement: AccountSummaryTests.plan(.none, periodEnd: nil), access: .free, lastError: nil, now: Self.now
        )
        let row = Self.content(summary)
        #expect(row.line1 == "name@icloud.com")
        #expect(row.line2 == "iCloud Photos")
        #expect(!row.showsUncloudSection)
    }
}

/// Renders the account row and its popover in each state of the plan's table, light and dark. Runs only when
/// UNCLOUD_ACCOUNT_FOOTER_SNAPSHOTS is set (pass it as TEST_RUNNER_UNCLOUD_ACCOUNT_FOOTER_SNAPSHOTS=1). The PNGs are
/// attachments of the result bundle, exported with `xcrun xcresulttool export attachments`.
@MainActor
@Suite("AccountFooterSnapshot")
struct AccountFooterSnapshotTests {
    struct State {
        let name: String
        let summary: AccountSummary
        var mode: AccountMode = .preview
        var source: LibrarySource = .iCloud
        var appleID: String? = "name@icloud.com"
        var isSourceReady = true
        var isExporting = false
    }

    static func states() -> [State] {
        let now = AccountSummaryTests.now
        let day = AccountSummaryTests.day
        let offline = AccountSummaryTests.signedIn(
            AccountSummaryTests.plan(.active, periodEnd: now.addingTimeInterval(30 * day), checkedAt: now.addingTimeInterval(-3 * day)),
            error: .offline, now: now
        )
        return [
            State(name: "free", summary: AccountFooterContentTests.free()),
            State(name: "plus", summary: AccountFooterContentTests.plus()),
            State(name: "payment-due", summary: AccountFooterContentTests.pastDue()),
            State(name: "offline-grace", summary: offline),
            State(name: "icloud-signed-out", summary: AccountFooterContentTests.free(), appleID: nil),
            State(name: "photos-on-this-mac", summary: AccountFooterContentTests.free(), source: .photosLibrary, appleID: nil),
            State(name: "mac-needs-access", summary: AccountFooterContentTests.free(), source: .photosLibrary, appleID: nil, isSourceReady: false),
            State(name: "exporting", summary: AccountFooterContentTests.plus(), isExporting: true),
            State(name: "loading", summary: AccountFooterContentTests.loading()),
        ]
    }

    @Test func rendersRowAndPopover() async throws {
        guard ProcessInfo.processInfo.environment["UNCLOUD_ACCOUNT_FOOTER_SNAPSHOTS"] != nil else { return }
        // The popover's account section reads the model for its actions only; the states are passed in as values.
        let defaults = isolatedDefaults()
        let account = AccountModel(
            mode: .preview,
            service: PreviewAccountService(store: PreviewAccountStore(defaults: defaults), now: { Date() }),
            tokens: DefaultsAccountTokenStore(defaults: defaults),
            defaults: defaults,
            openURL: { _ in }
        )
        var images: [(String, NSImage)] = []

        for state in Self.states() {
            for scheme in [ColorScheme.light, .dark] {
                let row = AccountFooterRowView(
                    summary: state.summary,
                    accountMode: state.mode,
                    source: state.source,
                    appleID: state.appleID,
                    isSourceReady: state.isSourceReady,
                    isExporting: state.isExporting,
                    chooseSource: { _ in },
                    signInToICloud: {},
                    signOutOfICloud: {},
                    openPrivacySettings: {}
                )
                .environment(account)
                .frame(width: 240)
                let rowImage = try #require(await Self.renderTitledWindow(row, size: NSSize(width: 240, height: 80), scheme: scheme))
                images.append(("footer-\(state.name)-row-\(Self.name(scheme))", rowImage))

                let popover = AccountFooterPopover(
                    summary: state.summary,
                    content: AccountFooterContent.make(
                        summary: state.summary,
                        accountMode: state.mode,
                        source: state.source,
                        appleID: state.appleID,
                        isSourceReady: state.isSourceReady
                    ),
                    source: state.source,
                    appleID: state.appleID,
                    isSourceReady: state.isSourceReady,
                    isExporting: state.isExporting,
                    chooseSource: { _ in },
                    signInToICloud: {},
                    signOutOfICloud: {},
                    openPrivacySettings: {},
                    close: {}
                )
                .environment(account)
                let popoverImage = try #require(await Self.renderTitledWindow(popover, size: NSSize(width: 300, height: 460), scheme: scheme))
                images.append(("footer-\(state.name)-popover-\(Self.name(scheme))", popoverImage))
            }
        }

        for (name, image) in images {
            Attachment.record(try Self.png(image), named: "\(name).png")
        }
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

    /// Renders a view in a titled window, as the other snapshot suites do.
    private static func renderTitledWindow<V: View>(_ view: V, size: NSSize, scheme: ColorScheme) async -> NSImage? {
        let page = view
            .environment(\.colorScheme, scheme)
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
        for _ in 0..<15 {
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
