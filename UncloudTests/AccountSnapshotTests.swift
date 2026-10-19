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
                let page = Form {
                    AccountSection()
                }
                .formStyle(.grouped)
                .frame(width: 460)
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

            let backup = BackupPane()
                .environment(window)
                .environment(BackupTools(model: window))
                .environment(free)
            let backupImage = try #require(await Self.renderTitledWindow(backup, size: NSSize(width: 1_000, height: 700), scheme: scheme))
            images.append(("locked-tools-\(Self.name(scheme))", backupImage))

            let rows = List {
                LockableSidebarRow(title: "Browse Backup", symbol: "map", isLocked: true)
                LockableSidebarRow(title: "Browse Backup", symbol: "map", isLocked: false)
            }
            .environment(free)
            .frame(width: 240)
            let rowImage = try #require(await Self.renderTitledWindow(rows, size: NSSize(width: 240, height: 120), scheme: scheme))
            images.append(("locked-sidebar-\(Self.name(scheme))", rowImage))
        }

        for (name, image) in images {
            Attachment.record(try Self.png(image), named: "\(name).png")
        }
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

    func currentEntitlement(tokens: AccountTokens) async throws -> (Entitlement, AccountTokens) {
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
}
