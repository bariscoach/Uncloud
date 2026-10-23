import AppKit
import SwiftUI
import Testing
@testable import Uncloud

/// Renders the signed-out screens (Welcome, Sign Up, Sign In, Code and the Code error) to PNG attachments, light and
/// dark, at the default window size and the minimum. Runs only when UNCLOUD_ACCOUNT_SNAPSHOTS is set. The PNGs are
/// exported from the result bundle with `xcrun xcresulttool`, as for the other snapshot suites.
@MainActor
@Suite("AccountSnapshot")
struct AccountSnapshotTests {
    private static let sizes = [NSSize(width: 1_000, height: 700), NSSize(width: 760, height: 500)]

    @Test func rendersSignedOutScreens() async throws {
        guard ProcessInfo.processInfo.environment["UNCLOUD_ACCOUNT_SNAPSHOTS"] != nil else { return }
        var images: [(String, NSImage)] = []

        for state in try await Self.states() {
            for size in Self.sizes {
                for scheme in [ColorScheme.light, .dark] {
                    let window = RootView()
                        .environment(state.model)
                    let name = "\(state.name)-\(Int(size.width))-\(Self.name(scheme))"
                    let image = try #require(await Self.renderTitledWindow(window, size: size, scheme: scheme))
                    images.append((name, image))
                }
            }
        }

        for (name, image) in images {
            Attachment.record(try Self.png(image), named: "\(name).png")
        }
    }

    /// The paywall, Settings › Account and the locked panes, signed in, light and dark. Gated like the other snapshots.
    @Test func rendersPaywallAccountAndLocks() async throws {
        guard ProcessInfo.processInfo.environment["UNCLOUD_ACCOUNT_SNAPSHOTS"] != nil else { return }
        var images: [(String, NSImage)] = []
        let paywallSize = NSSize(width: 520, height: 760)
        let accountSize = NSSize(width: 460, height: 640)

        // The paywall, in each state the app shows it in (plan §5.2).
        for state in try await Self.paywallStates() {
            for scheme in [ColorScheme.light, .dark] {
                UserDefaults.standard.set(state.renewal.rawValue, forKey: "uncloudPaywallRenewal")
                let page = PaywallSheet(request: state.request)
                    .environment(state.model)
                    .frame(width: 520)
                let image = try #require(await Self.renderTitledWindow(page, size: paywallSize, scheme: scheme))
                images.append(("paywall-\(state.name)-\(Self.name(scheme))", image))
            }
        }
        UserDefaults.standard.removeObject(forKey: "uncloudPaywallRenewal")

        // Settings › Account: renewing, ending, and free.
        for state in try await Self.accountStates() {
            for scheme in [ColorScheme.light, .dark] {
                let page = AccountSettingsForm()
                    .environment(state.model)
                let image = try #require(await Self.renderTitledWindow(page, size: accountSize, scheme: scheme))
                images.append(("account-\(state.name)-\(Self.name(scheme))", image))
            }
        }

        // A locked pane, a locked tool and a locked sidebar row, in the real main window and Backup pane, signed in as a
        // free account. The window needs a drive and an iCloud source, as the Backup snapshots do.
        let free = try await Self.signedIn(email: "name@example.com")
        let drive = FileManager.default.temporaryDirectory
            .appending(path: "uncloud-account-locks-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: drive, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: drive) }
        let defaults = UserDefaults.standard
        let savedAppleID = ICloudAccount.appleID
        let savedSource = defaults.object(forKey: "librarySource")
        ICloudAccount.appleID = "preview@example.invalid"
        defaults.set(LibrarySource.iCloud.rawValue, forKey: "librarySource")
        defaults.removeObject(forKey: ExportModel.bookmarkKey)
        defer {
            ICloudAccount.appleID = savedAppleID
            if let savedSource {
                defaults.set(savedSource, forKey: "librarySource")
            } else {
                defaults.removeObject(forKey: "librarySource")
            }
        }
        let window = ExportModel()
        window.chooseDestination(.success(drive))
        try await Task.sleep(for: .milliseconds(800))
        window.pane = .browse

        for scheme in [ColorScheme.light, .dark] {
            let main = MainWindow()
                .environment(window)
                .environment(BackupTools(model: window))
                .environment(free)
            let image = try #require(await Self.renderTitledWindow(main, size: NSSize(width: 1_000, height: 700), scheme: scheme))
            images.append(("locked-browse-\(Self.name(scheme))", image))

            let tools = ToolsPane()
                .environment(window)
                .environment(BackupTools(model: window))
                .environment(free)
            let toolsImage = try #require(await Self.renderTitledWindow(tools, size: NSSize(width: 1_000, height: 700), scheme: scheme))
            images.append(("locked-tools-\(Self.name(scheme))", toolsImage))

            let rows = List {
                LockableSidebarRow(title: ExportModel.Pane.browse.title, symbol: ExportModel.Pane.browse.symbol, isLocked: true)
                LockableSidebarRow(title: ExportModel.Pane.browse.title, symbol: ExportModel.Pane.browse.symbol, isLocked: false)
                LockableSidebarRow(title: ExportModel.Pane.tools.title, symbol: ExportModel.Pane.tools.symbol, isLocked: true)
                LockableSidebarRow(title: ExportModel.Pane.cleanup.title, symbol: ExportModel.Pane.cleanup.symbol, isLocked: true)
            }
            .environment(free)
            .frame(width: 240)
            let rowImage = try #require(await Self.renderTitledWindow(rows, size: NSSize(width: 240, height: 200), scheme: scheme))
            images.append(("locked-sidebar-\(Self.name(scheme))", rowImage))

            // Delete from iCloud for a free account: the whole pane is the locked view, with the 30-day note (plan §2.2).
            let cleanup = LockedFeatureView(feature: .cleanUpICloud)
                .environment(free)
            let cleanupImage = try #require(await Self.renderTitledWindow(cleanup, size: NSSize(width: 1_000, height: 700), scheme: scheme))
            images.append(("locked-cleanup-\(Self.name(scheme))", cleanupImage))
        }

        // The PNGs also go to the scratch folder, so they can be looked at without opening the result bundle.
        let scratch = URL(
            fileURLWithPath: "/private/tmp/claude-501/-Users-barishiz-Developer-icloud-photo-export/df886b0f-d79a-4d1c-973d-23c5d89614c2/scratchpad/account-snapshots",
            isDirectory: true
        )
        for (name, image) in images {
            let data = try Self.png(image)
            Attachment.record(data, named: "\(name).png")
            try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
            try? data.write(to: scratch.appending(path: "\(name).png"))
        }
    }

    /// The account button, its popover, Settings (General and Account), the delete sheet and the sidebar button, light
    /// and dark (account-menu plan §7.2). Gated like the others; the PNGs are attachments of the result bundle.
    @Test func rendersAccountMenuAndSettings() async throws {
        guard ProcessInfo.processInfo.environment["UNCLOUD_ACCOUNT_SNAPSHOTS"] != nil else { return }
        var images: [(String, NSImage)] = []
        let now = Date()
        let host = try await Self.signedIn(email: "name@example.com")

        // The account popover (300 pt wide, opening upwards from the sidebar row), in each state the header and actions
        // change in, and in the two photo-source states that have no iCloud lines.
        let plus = Self.summary(.plus, status: .active, periodEnd: now.addingTimeInterval(30 * 86_400), now: now)
        let popoverStates: [(String, AnyView)] = [
            ("free", Self.footerPopover(host.summary, host: host)),
            ("free-ended", Self.footerPopover(Self.summary(.plus, status: .expired, periodEnd: now.addingTimeInterval(-86_400), now: now), host: host)),
            ("plus-renewing", Self.footerPopover(plus, host: host)),
            ("plus-ending", Self.footerPopover(Self.summary(.plus, status: .active, periodEnd: now.addingTimeInterval(30 * 86_400), cancel: true, now: now), host: host)),
            ("past-due", Self.footerPopover(Self.summary(.plus, status: .pastDue, periodEnd: now.addingTimeInterval(-86_400), now: now), host: host)),
            ("offline-grace", Self.footerPopover(Self.summary(.plus, status: .active, periodEnd: now.addingTimeInterval(-86_400), now: now), host: host)),
            ("last-checked", Self.footerPopover(Self.summary(.plus, status: .active, periodEnd: now.addingTimeInterval(30 * 86_400), checked: now.addingTimeInterval(-3 * 86_400), error: .offline, now: now), host: host)),
            ("icloud-signed-out", Self.footerPopover(plus, host: host, appleID: nil)),
            ("mac-needs-access", Self.footerPopover(plus, host: host, source: .photosLibrary, isSourceReady: false)),
        ]
        for (label, view) in popoverStates {
            try await Self.render("menu-popover-\(label)", view, size: NSSize(width: 300, height: 480), into: &images)
        }
        let longEmail = try await Self.signedIn(email: "a.very.long.address.for.testing@example-domain.com")
        let longPopover = Self.footerPopover(longEmail.summary, host: longEmail, isExporting: true)
        try await Self.render("menu-popover-long-email", longPopover, size: NSSize(width: 300, height: 480), into: &images)

        // The account row alone, 240 pt wide, in each state the row's line 2 and dot change in.
        let rowStates: [(String, AnyView)] = [
            ("free", Self.footerRow(host.summary, host: host)),
            ("plus", Self.footerRow(plus, host: host)),
            ("past-due", Self.footerRow(Self.summary(.plus, status: .pastDue, periodEnd: now.addingTimeInterval(-86_400), now: now), host: host)),
            ("icloud-signed-out", Self.footerRow(plus, host: host, appleID: nil)),
            ("mac", Self.footerRow(plus, host: host, source: .photosLibrary, isSourceReady: true)),
        ]
        for (label, view) in rowStates {
            try await Self.render("menu-footer-row-\(label)", view.frame(width: 240).padding(Tokens.Space.s), size: NSSize(width: 256, height: 80), into: &images)
        }

        // Settings › Account (460 pt) in each state.
        let accountStates = try await Self.accountTabStates()
        for (label, model) in accountStates {
            let view = AccountSettingsForm()
                .environment(model)
            try await Self.render("menu-account-\(label)", view, size: NSSize(width: 460, height: 640), into: &images)
        }

        // Delete Account (420 pt): empty, matched, deleting, error; a paid plan and a never-paid account. The deleting
        // state needs a delete that is still running while the sheet renders, so its account's delete waits a minute.
        let slow = try await Self.signedIn(email: "slow@example.com", deleteDelay: .seconds(60))
        let deleting = Task { await slow.deleteAccount(confirmEmail: "slow@example.com") }
        try await Task.sleep(for: .milliseconds(200))
        let sheetStates = try await Self.deleteSheetStates()
        for (label, view) in sheetStates {
            try await Self.render("menu-delete-\(label)", view, size: NSSize(width: 420, height: 420), into: &images)
        }
        let deletingSheet = DeleteAccountSheet(email: "slow@example.com", isPaid: false, hadPlan: false, isExporting: false, initialConfirmation: "slow@example.com")
            .environment(slow)
        try await Self.render("menu-delete-deleting", deletingSheet, size: NSSize(width: 420, height: 420), into: &images)
        deleting.cancel()

        // Settings with its tabs (460 pt), signed in: General, then Account.
        let settings = AutoBackupSettings()
        let exportModel = ExportModel()
        for (label, tab) in [("general", SettingsTab.general), ("account", SettingsTab.account)] {
            UserDefaults.standard.set(tab.rawValue, forKey: SettingsTab.storageKey)
            let view = SettingsView()
                .environment(exportModel)
                .environment(settings)
                .environment(host)
            try await Self.render("menu-settings-\(label)", view, size: NSSize(width: 460, height: 640), into: &images)
        }
        UserDefaults.standard.removeObject(forKey: SettingsTab.storageKey)

        // The whole main window's sidebar, with the brand header at the top and the account row pinned at the bottom:
        // iCloud Plus, Free and payment due, at the default and minimum window sizes. The source is iCloud and signed in.
        let plusModel = try await Self.signedIn(email: "plus@example.com")
        let pastDueModel = try await Self.signedIn(email: "pastdue@example.com")
        let defaults = UserDefaults.standard
        let savedAppleID = ICloudAccount.appleID
        let savedSource = defaults.object(forKey: "librarySource")
        ICloudAccount.appleID = "preview@example.invalid"
        defaults.set(LibrarySource.iCloud.rawValue, forKey: "librarySource")
        defer {
            ICloudAccount.appleID = savedAppleID
            if let savedSource {
                defaults.set(savedSource, forKey: "librarySource")
            } else {
                defaults.removeObject(forKey: "librarySource")
            }
        }
        let sidebarModel = ExportModel()
        for (label, account) in [("plus", plusModel), ("free", host), ("past-due", pastDueModel)] {
            for size in [NSSize(width: 1_000, height: 700), NSSize(width: 760, height: 500)] {
                let window = MainWindow()
                    .environment(sidebarModel)
                    .environment(BackupTools(model: sidebarModel))
                    .environment(account)
                try await Self.render("menu-sidebar-\(label)-\(Int(size.width))", window, size: size, into: &images)
            }
        }

        // The sidebar column alone, at 220 pt: the five pane rows in order, the brand header above and the account row
        // below. The window's own sidebar draws no rows into a cached bitmap, so this shows the rows and their order.
        for (label, account) in [("plus", plusModel), ("free", host), ("past-due", pastDueModel)] {
            let column = List {
                SidebarPaneRows()
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                SidebarBrandHeader()
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 0) {
                    Divider()
                    AccountFooterRow()
                }
            }
            .environment(sidebarModel)
            .environment(BackupTools(model: sidebarModel))
            .environment(account)
            .frame(width: 220, height: 420)
            try await Self.render("sidebar-column-\(label)", column, size: NSSize(width: 220, height: 420), into: &images)
        }

        for (name, image) in images {
            Attachment.record(try Self.png(image), named: "\(name).png")
        }
    }

    /// The account popover as the sidebar row opens it, built the way the row builds it (`AccountFooterContent`).
    private static func footerPopover(
        _ summary: AccountSummary,
        host: AccountModel,
        source: LibrarySource = .iCloud,
        appleID: String? = "name@icloud.com",
        isSourceReady: Bool = true,
        isExporting: Bool = false
    ) -> AnyView {
        AnyView(AccountFooterPopover(
            summary: summary,
            content: AccountFooterContent.make(summary: summary, accountMode: .preview, source: source, appleID: appleID, isSourceReady: isSourceReady),
            source: source,
            appleID: appleID,
            isSourceReady: isSourceReady,
            isExporting: isExporting,
            chooseSource: { _ in },
            signInToICloud: {},
            signOutOfICloud: {},
            openPrivacySettings: {},
            close: {}
        ).environment(host))
    }

    /// The account row from values, as the sidebar draws it.
    private static func footerRow(
        _ summary: AccountSummary,
        host: AccountModel,
        source: LibrarySource = .iCloud,
        appleID: String? = "name@icloud.com",
        isSourceReady: Bool = true
    ) -> AnyView {
        AnyView(AccountFooterRowView(
            summary: summary,
            accountMode: .preview,
            source: source,
            appleID: appleID,
            isSourceReady: isSourceReady,
            isExporting: false,
            chooseSource: { _ in },
            signInToICloud: {},
            signOutOfICloud: {},
            openPrivacySettings: {}
        ).environment(host))
    }

    /// Renders `view` in light and dark, adding each image under `label-light` and `label-dark`.
    private static func render<V: View>(_ label: String, _ view: V, size: NSSize, into images: inout [(String, NSImage)]) async throws {
        for scheme in [ColorScheme.light, .dark] {
            let image = try #require(await renderTitledWindow(view, size: size, scheme: scheme))
            images.append(("\(label)-\(name(scheme))", image))
        }
    }

    /// A summary for a preview account in a given plan state, through the pure rules.
    private static func summary(
        _ plan: Plan,
        status: Entitlement.Status,
        periodEnd: Date,
        cancel: Bool = false,
        checked: Date? = nil,
        error: AccountError? = nil,
        now: Date
    ) -> AccountSummary {
        let entitlement = Entitlement(
            plan: plan, status: status, currentPeriodEnd: periodEnd,
            cancelAtPeriodEnd: cancel, checkedAt: checked ?? now
        )
        return AccountSummary.make(
            mode: .preview,
            phase: .signedIn,
            account: UncloudAccount(id: "snapshot", email: "name@example.com", createdAt: now.addingTimeInterval(-400 * 86_400)),
            entitlement: entitlement,
            access: EntitlementPolicy.access(entitlement, now: now),
            lastError: error,
            now: now
        )
    }

    /// Settings › Account states, each reached through the model: signed out, after a delete, and the plan states.
    private static func accountTabStates() async throws -> [(String, AccountModel)] {
        let now = Date()
        var states: [(String, AccountModel)] = []

        states.append(("signed-out", try await signedOutModel()))
        let deleted = try await signedIn(email: "gone@example.com")
        await deleted.deleteAccount(confirmEmail: "gone@example.com")
        states.append(("signed-out-deleted", deleted))

        states.append(("free", try await signedIn(email: "name@example.com")))
        states.append(("free-long-email", try await signedIn(email: "a.very.long.address.for.testing@example-domain.com")))
        states.append(("plus-renewing", try await signedIn(email: "plus@example.com")))
        let ending = try await signedIn(email: "plus@example.com")
        await ending.setAutoRenew(false)
        states.append(("plus-ending", ending))
        states.append(("past-due", try await signedIn(email: "pastdue@example.com")))

        // A free account whose renewal change was refused: the error sits under Subscription.
        let refused = try await signedIn(email: "name@example.com")
        await refused.setAutoRenew(true)
        states.append(("error", refused))

        // Plans the server reports, through a service that answers the plan check with a fixed entitlement.
        let expired = Entitlement(plan: .free, status: .expired, currentPeriodEnd: now.addingTimeInterval(-86_400), cancelAtPeriodEnd: false, checkedAt: now)
        states.append(("free-ended", try await signedIn(email: "name@example.com", plan: expired)))
        let grace = Entitlement(plan: .plus, status: .active, currentPeriodEnd: now.addingTimeInterval(-86_400), cancelAtPeriodEnd: false, checkedAt: now)
        states.append(("offline-grace", try await signedIn(email: "name@example.com", plan: grace)))
        return states
    }

    /// A signed-out model on Welcome, as the app starts after sign-out.
    private static func signedOutModel() async throws -> AccountModel {
        let defaults = isolatedDefaults()
        return AccountModel(mode: .preview, service: PreviewAccountService(store: PreviewAccountStore(defaults: defaults)), tokens: DefaultsAccountTokenStore(defaults: defaults), defaults: defaults)
    }

    /// Delete Account sheets: empty, matched, a refused confirmation (the error), and the two plan variants.
    private static func deleteSheetStates() async throws -> [(String, AnyView)] {
        let paid = try await signedIn(email: "plus@example.com")
        let free = try await signedIn(email: "name@example.com")
        let failed = try await signedIn(email: "name@example.com")
        await failed.deleteAccount(confirmEmail: "other@example.com")

        let sheets: [(String, AnyView)] = [
            ("empty-free", AnyView(DeleteAccountSheet(email: "name@example.com", isPaid: false, hadPlan: false, isExporting: false).environment(free))),
            ("empty-paid", AnyView(DeleteAccountSheet(email: "plus@example.com", isPaid: true, hadPlan: true, isExporting: false).environment(paid))),
            ("matched-paid", AnyView(DeleteAccountSheet(email: "plus@example.com", isPaid: true, hadPlan: true, isExporting: false, initialConfirmation: "plus@example.com").environment(paid))),
            ("error", AnyView(DeleteAccountSheet(email: "name@example.com", isPaid: false, hadPlan: false, isExporting: false, initialConfirmation: "other@example.com").environment(failed))),
        ]
        return sheets
    }

    /// A preview account signed in with the stub code. `plan` is what the plan check answers with; `deleteDelay` holds the
    /// delete call for that long, so a snapshot can show the deleting state.
    static func signedIn(email: String, plan: Entitlement? = nil, deleteDelay: Duration? = nil) async throws -> AccountModel {
        let defaults = isolatedDefaults()
        let base = PreviewAccountService(store: PreviewAccountStore(defaults: defaults), now: { Date() })
        let model = AccountModel(
            mode: .preview,
            service: EntitlementStub(base: base, entitlement: plan, deleteDelay: deleteDelay),
            tokens: DefaultsAccountTokenStore(defaults: defaults),
            defaults: defaults,
            openURL: { _ in }
        )
        await model.submitEmail(email, intent: .signIn)
        await model.submitCode(PreviewAccountService.code)
        await model.refreshEntitlement(force: true)
        return model
    }

    static func name(_ scheme: ColorScheme) -> String {
        scheme == .dark ? "dark" : "light"
    }

    struct PaywallState {
        let name: String
        let model: AccountModel
        let request: PaywallRequest
        let renewal: Renewal
    }

    /// Each paywall state, reached the way the app reaches it.
    static func paywallStates() async throws -> [PaywallState] {
        let defaults = isolatedDefaults()
        func signedInModel(_ failure: AccountError? = nil, email: String = "name@example.com") async throws -> AccountModel {
            let service = CheckoutStub(base: PreviewAccountService(store: PreviewAccountStore(defaults: defaults), now: { Date() }), failure: failure)
            let model = AccountModel(mode: .preview, service: service, tokens: DefaultsAccountTokenStore(defaults: defaults), defaults: defaults, openURL: { _ in })
            await model.submitEmail(email, intent: .signIn)
            await model.submitCode(PreviewAccountService.code)
            return model
        }

        let fresh = try await signedInModel()
        fresh.require(.browseBackup) {}

        let oneYear = try await signedInModel(email: "oneyear@example.com")
        oneYear.require(.verifyBackup) {}

        let waiting = try await signedInModel()
        waiting.require(.findDuplicates) {}
        await waiting.openCheckout(for: .findDuplicates, renewal: .automatic)

        let processing = try await signedInModel()
        processing.require(.freeUpSpace) {}
        await processing.openCheckout(for: .freeUpSpace, renewal: .automatic)
        _ = processing.handle(URL(string: "uncloud://checkout/success?session_id=cs_test_snapshot")!)
        await processing.refreshTask?.value

        let failed = try await signedInModel(.checkoutUnavailable)
        failed.require(.cleanUpICloud) {}
        await failed.openCheckout(for: .cleanUpICloud, renewal: .automatic)

        return [
            PaywallState(name: "default", model: fresh, request: fresh.paywall!, renewal: .automatic),
            PaywallState(name: "one-year", model: oneYear, request: oneYear.paywall!, renewal: .oneYear),
            PaywallState(name: "waiting", model: waiting, request: waiting.paywall!, renewal: .automatic),
            PaywallState(name: "processing", model: processing, request: processing.paywall!, renewal: .automatic),
            PaywallState(name: "error", model: failed, request: failed.paywall!, renewal: .automatic),
        ]
    }

    /// Settings › Account in each plan state. "Ending" is a plan set not to renew.
    static func accountStates() async throws -> [(name: String, model: AccountModel)] {
        let renewing = try await signedIn(email: "plus@example.com")
        let ending = try await signedIn(email: "plus@example.com")
        await ending.setAutoRenew(false)
        let free = try await signedIn(email: "name@example.com")
        return [("plus-renewing", renewing), ("plus-ending", ending), ("free", free)]
    }

    /// A preview account signed in with the stub code, on its own defaults.
    static func signedIn(email: String) async throws -> AccountModel {
        let defaults = isolatedDefaults()
        let service = PreviewAccountService(store: PreviewAccountStore(defaults: defaults), now: { Date() })
        let model = AccountModel(mode: .preview, service: service, tokens: DefaultsAccountTokenStore(defaults: defaults), defaults: defaults, openURL: { _ in })
        await model.submitEmail(email, intent: .signIn)
        await model.submitCode(PreviewAccountService.code)
        return model
    }

    /// Each signed-out screen, built the way the app reaches it: the model's own actions, against the preview service.
    private static func states() async throws -> [(name: String, model: AccountModel)] {
        func fresh() -> AccountModel {
            let defaults = isolatedDefaults()
            let service = PreviewAccountService(store: PreviewAccountStore(defaults: defaults), now: { Date() })
            // The clock is the real one, so the resend countdown the views draw matches the live app.
            return AccountModel(mode: .preview, service: service, tokens: DefaultsAccountTokenStore(defaults: defaults), defaults: defaults)
        }

        let welcome = fresh()
        let signUp = fresh()
        signUp.show(.signUp)
        let signIn = fresh()
        signIn.show(.signIn)

        let code = fresh()
        await code.submitEmail("name@example.com", intent: .signUp)

        let codeError = fresh()
        await codeError.submitEmail("name@example.com", intent: .signUp)
        await codeError.submitCode("000000")

        return [
            ("welcome", welcome),
            ("signup", signUp),
            ("signin", signIn),
            ("code", code),
            ("code-error", codeError),
        ]
    }

    private static func png(_ image: NSImage) throws -> Data {
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let data = rep.representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return data
    }

    /// Renders a view in a titled window, so the window's frame and title bar draw as they do in the app.
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
        for _ in 0..<25 {
            window.contentView?.layoutSubtreeIfNeeded()
            try? await Task.sleep(for: .milliseconds(100))
        }
        defer { window.close() }
        guard let frameView = window.contentView?.superview,
              let rep = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds) else { return nil }
        frameView.cacheDisplay(in: frameView.bounds, to: rep)
        let image = NSImage(size: frameView.bounds.size)
        image.addRepresentation(rep)
        return image
    }
}

/// The preview service with its checkout replaced: the browser gets a Checkout URL, but no plan is granted, or the call fails.
/// Lets the snapshots show the waiting, processing and error states without a server.
struct CheckoutStub: AccountService {
    let base: PreviewAccountService
    var failure: AccountError?

    func requestCode(email: String, intent: AuthIntent) async throws -> AuthChallenge {
        try await base.requestCode(email: email, intent: intent)
    }

    func verify(challenge: AuthChallenge, code: String) async throws -> AuthSession {
        try await base.verify(challenge: challenge, code: code)
    }

    func currentEntitlement(tokens: AccountTokens) async throws -> Entitlement {
        try await base.currentEntitlement(tokens: tokens)
    }

    func refresh(tokens: AccountTokens) async throws -> AccountTokens {
        try await base.refresh(tokens: tokens)
    }

    func signOut(tokens: AccountTokens) async {
        await base.signOut(tokens: tokens)
    }

    func checkoutURL(tokens: AccountTokens, renewal: Renewal) async throws -> URL {
        if let failure {
            throw failure
        }
        return URL(string: "https://checkout.stripe.com/c/pay/cs_test_snapshot")!
    }

    func manageSubscriptionURL(tokens: AccountTokens) async throws -> URL {
        try await base.manageSubscriptionURL(tokens: tokens)
    }

    func setAutoRenew(_ autoRenew: Bool, tokens: AccountTokens) async throws -> Entitlement {
        try await base.setAutoRenew(autoRenew, tokens: tokens)
    }

    func deleteAccount(confirmEmail: String, tokens: AccountTokens) async throws {
        try await base.deleteAccount(confirmEmail: confirmEmail, tokens: tokens)
    }
}

/// The preview service, with two changes for the snapshots: the plan check can answer with a fixed entitlement (an ended
/// plan, a plan in offline grace), and the delete call can wait first (the deleting state).
struct EntitlementStub: AccountService {
    let base: PreviewAccountService
    var entitlement: Entitlement?
    var deleteDelay: Duration?

    func requestCode(email: String, intent: AuthIntent) async throws -> AuthChallenge {
        try await base.requestCode(email: email, intent: intent)
    }

    func verify(challenge: AuthChallenge, code: String) async throws -> AuthSession {
        try await base.verify(challenge: challenge, code: code)
    }

    func currentEntitlement(tokens: AccountTokens) async throws -> Entitlement {
        let actual = try await base.currentEntitlement(tokens: tokens)
        return entitlement ?? actual
    }

    func refresh(tokens: AccountTokens) async throws -> AccountTokens {
        try await base.refresh(tokens: tokens)
    }

    func signOut(tokens: AccountTokens) async {
        await base.signOut(tokens: tokens)
    }

    func checkoutURL(tokens: AccountTokens, renewal: Renewal) async throws -> URL {
        try await base.checkoutURL(tokens: tokens, renewal: renewal)
    }

    func manageSubscriptionURL(tokens: AccountTokens) async throws -> URL {
        try await base.manageSubscriptionURL(tokens: tokens)
    }

    func setAutoRenew(_ autoRenew: Bool, tokens: AccountTokens) async throws -> Entitlement {
        try await base.setAutoRenew(autoRenew, tokens: tokens)
    }

    func deleteAccount(confirmEmail: String, tokens: AccountTokens) async throws {
        if let deleteDelay {
            try await Task.sleep(for: deleteDelay)
        }
        try await base.deleteAccount(confirmEmail: confirmEmail, tokens: tokens)
    }
}
