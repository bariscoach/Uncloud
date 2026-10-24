import AppKit
import SwiftUI
import Testing
@testable import Uncloud

/// Renders the signed-out screens (Welcome, Sign Up, Sign In, Code and the Code error) and the signed-in account
/// screens (the popover, the account row, Settings › Account, Delete Account and the main window) to PNG attachments,
/// light and dark. Runs only when UNCLOUD_ACCOUNT_SNAPSHOTS is set. The PNGs are exported from the result bundle with
/// `xcrun xcresulttool`, as for the other snapshot suites.
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

    /// The account button, its popover, Settings (General and Account), the delete sheet and the main window, signed in.
    /// Gated like the others. Each PNG is also copied to the scratch folder, so it can be viewed without the bundle.
    @Test func rendersAccountMenuAndSettings() async throws {
        guard ProcessInfo.processInfo.environment["UNCLOUD_ACCOUNT_SNAPSHOTS"] != nil else { return }
        var images: [(String, NSImage)] = []
        let host = try await Self.signedIn(email: "name@example.com")

        // The account popover (300 pt wide, opening upwards from the sidebar row), in the photo-source states that change it.
        let popoverStates: [(String, AnyView)] = [
            ("signed-in", Self.footerPopover(host.summary, host: host)),
            ("icloud-signed-out", Self.footerPopover(host.summary, host: host, appleID: nil)),
            ("mac-needs-access", Self.footerPopover(host.summary, host: host, source: .photosLibrary, isSourceReady: false)),
        ]
        for (label, view) in popoverStates {
            try await Self.render("menu-popover-\(label)", view, size: NSSize(width: 300, height: 480), into: &images)
        }
        let longEmail = try await Self.signedIn(email: "a.very.long.address.for.testing@example-domain.com")
        let longPopover = Self.footerPopover(longEmail.summary, host: longEmail, isExporting: true)
        try await Self.render("menu-popover-long-email", longPopover, size: NSSize(width: 300, height: 480), into: &images)

        // The account row alone, 240 pt wide.
        let rowStates: [(String, AnyView)] = [
            ("signed-in", Self.footerRow(host.summary, host: host)),
            ("icloud-signed-out", Self.footerRow(host.summary, host: host, appleID: nil)),
            ("mac", Self.footerRow(host.summary, host: host, source: .photosLibrary, isSourceReady: true)),
        ]
        for (label, view) in rowStates {
            try await Self.render("menu-footer-row-\(label)", view.frame(width: 240).padding(Tokens.Space.s), size: NSSize(width: 256, height: 80), into: &images)
        }

        // Settings › Account (460 pt) in each state.
        for (label, model) in try await Self.accountTabStates() {
            let view = AccountSettingsForm()
                .environment(model)
            try await Self.render("menu-account-\(label)", view, size: NSSize(width: 460, height: 640), into: &images)
        }

        // Delete Account (420 pt): empty, matched, error, and deleting. The deleting state needs a delete that is still
        // running while the sheet renders, so its account's delete waits a minute.
        let slow = try await Self.signedIn(email: "slow@example.com", deleteDelay: .seconds(60))
        let deleting = Task { await slow.deleteAccount(confirmEmail: "slow@example.com") }
        try await Task.sleep(for: .milliseconds(200))
        for (label, view) in try await Self.deleteSheetStates() {
            try await Self.render("menu-delete-\(label)", view, size: NSSize(width: 420, height: 420), into: &images)
        }
        let deletingSheet = DeleteAccountSheet(email: "slow@example.com", isExporting: false, initialConfirmation: "slow@example.com")
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

        // The main window with the account row at the bottom, and every pane open for a free account (no lock).
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
        let windowModel = ExportModel()
        for pane in [ExportModel.Pane.browse, .cleanup] {
            windowModel.pane = pane
            for size in Self.sizes {
                let window = MainWindow()
                    .environment(windowModel)
                    .environment(BackupTools(model: windowModel))
                    .environment(host)
                try await Self.render("menu-main-\(pane.title.lowercased().replacingOccurrences(of: " ", with: "-"))-\(Int(size.width))", window, size: size, into: &images)
            }
        }

        // The sidebar column alone, at 220 pt: the pane rows in order, the brand header above and the account row below.
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
        .environment(windowModel)
        .environment(BackupTools(model: windowModel))
        .environment(host)
        .frame(width: 220, height: 420)
        try await Self.render("sidebar-column", column, size: NSSize(width: 220, height: 420), into: &images)

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

    /// Settings › Account states, each reached through the model: signed out, after a delete, and a refused delete.
    private static func accountTabStates() async throws -> [(String, AccountModel)] {
        var states: [(String, AccountModel)] = []

        states.append(("signed-out", try await signedOutModel()))
        let deleted = try await signedIn(email: "gone@example.com")
        await deleted.deleteAccount(confirmEmail: "gone@example.com")
        states.append(("signed-out-deleted", deleted))

        states.append(("signed-in", try await signedIn(email: "name@example.com")))
        states.append(("signed-in-long-email", try await signedIn(email: "a.very.long.address.for.testing@example-domain.com")))

        // A delete the typed email refused: the error sits under Profile.
        let refused = try await signedIn(email: "name@example.com")
        await refused.deleteAccount(confirmEmail: "other@example.com")
        states.append(("error", refused))
        return states
    }

    /// A signed-out model on Welcome, as the app starts after sign-out.
    private static func signedOutModel() async throws -> AccountModel {
        let defaults = isolatedDefaults()
        return AccountModel(mode: .preview, service: PreviewAccountService(store: PreviewAccountStore(defaults: defaults)), tokens: DefaultsAccountTokenStore(defaults: defaults), defaults: defaults)
    }

    /// Delete Account sheets: empty, matched, and a refused confirmation (the error).
    private static func deleteSheetStates() async throws -> [(String, AnyView)] {
        let free = try await signedIn(email: "name@example.com")
        let failed = try await signedIn(email: "name@example.com")
        await failed.deleteAccount(confirmEmail: "other@example.com")

        let sheets: [(String, AnyView)] = [
            ("empty", AnyView(DeleteAccountSheet(email: "name@example.com", isExporting: false).environment(free))),
            ("matched", AnyView(DeleteAccountSheet(email: "name@example.com", isExporting: false, initialConfirmation: "name@example.com").environment(free))),
            ("error", AnyView(DeleteAccountSheet(email: "name@example.com", isExporting: false, initialConfirmation: "other@example.com").environment(failed))),
        ]
        return sheets
    }

    /// A preview account signed in with the stub code. `deleteDelay` holds the delete call for that long, so a snapshot
    /// can show the deleting state.
    static func signedIn(email: String, deleteDelay: Duration? = nil) async throws -> AccountModel {
        let defaults = isolatedDefaults()
        let base = PreviewAccountService(store: PreviewAccountStore(defaults: defaults), now: { Date() })
        let model = AccountModel(
            mode: .preview,
            service: DelayedDeleteService(base: base, deleteDelay: deleteDelay),
            tokens: DefaultsAccountTokenStore(defaults: defaults),
            defaults: defaults
        )
        await model.submitEmail(email, intent: .signIn)
        await model.submitCode(PreviewAccountService.code)
        return model
    }

    static func name(_ scheme: ColorScheme) -> String {
        scheme == .dark ? "dark" : "light"
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

/// The preview service, with the delete call optionally held for a while (the deleting state of the sheet).
struct DelayedDeleteService: AccountService {
    let base: PreviewAccountService
    var deleteDelay: Duration?

    func requestCode(email: String, intent: AuthIntent) async throws -> AuthChallenge {
        try await base.requestCode(email: email, intent: intent)
    }

    func verify(challenge: AuthChallenge, code: String) async throws -> AuthSession {
        try await base.verify(challenge: challenge, code: code)
    }

    func currentAccount(tokens: AccountTokens) async throws -> UncloudAccount {
        try await base.currentAccount(tokens: tokens)
    }

    func refresh(tokens: AccountTokens) async throws -> AccountTokens {
        try await base.refresh(tokens: tokens)
    }

    func signOut(tokens: AccountTokens) async {
        await base.signOut(tokens: tokens)
    }

    func deleteAccount(confirmEmail: String, tokens: AccountTokens) async throws {
        if let deleteDelay {
            try await Task.sleep(for: deleteDelay)
        }
        try await base.deleteAccount(confirmEmail: confirmEmail, tokens: tokens)
    }
}
