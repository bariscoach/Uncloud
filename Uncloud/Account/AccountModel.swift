import AppKit
import Foundation
import Observation

/// The paywall sheet's request: the feature that asked for it (nil when opened from Settings), and the action to run after subscribing.
struct PaywallRequest: Identifiable {
    let id = UUID()
    let feature: PaidFeature?
    let then: (@MainActor () -> Void)?
}

/// The one object the account views read: the phase, the account, the cached plan and the paywall.
@MainActor @Observable final class AccountModel {
    enum Phase: Equatable {
        case off
        case restoring
        case signedOut(Route)
        case signedIn
    }

    enum Route: Hashable {
        case welcome
        case signUp
        case signIn
        case code(AuthChallenge, AuthIntent)
    }

    /// Progress of the paywall's checkout (plan D.1).
    enum Checkout: Equatable {
        case idle
        case opening
        /// The browser has Checkout open. `processing` is true once the browser came back before the server confirmed a plan.
        case waiting(processing: Bool)
        case active
        case failed(AccountError)
    }

    let mode: AccountMode
    private(set) var phase: Phase
    private(set) var account: UncloudAccount?
    /// The plan as last reported by the server, or the cached one.
    private(set) var entitlement: Entitlement
    /// Whether the last sign-in created the account. The Welcome announcement depends on it.
    private(set) var isNewAccount = false
    /// The email from the last submit, kept when moving between the email and code screens.
    private(set) var email = ""
    var paywall: PaywallRequest?
    private(set) var checkout: Checkout = .idle
    /// A sign-in request is in flight.
    private(set) var isBusy = false
    /// The error for the current screen.
    private(set) var error: AccountError?

    private let service: AccountService
    @ObservationIgnored private let tokenStore: AccountTokenStore
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let clock: @Sendable () -> Date
    @ObservationIgnored private let openURL: @MainActor (URL) -> Void
    @ObservationIgnored private let isExportRunning: @MainActor () -> Bool
    @ObservationIgnored private var tokens: AccountTokens?
    /// Counts sign-in requests, so a cancelled or superseded request's result is ignored.
    @ObservationIgnored private var requestID = 0
    @ObservationIgnored private var requestCanceller: (() -> Void)?
    /// Set when the server revoked the session while an export ran. Applied by `exportDidFinish()`.
    @ObservationIgnored private var deferredRevocation = false
    /// The last refresh started from a `uncloud://` link or the paywall, so it can be awaited.
    @ObservationIgnored private(set) var refreshTask: Task<Void, Never>?
    /// A token refresh in flight. Concurrent server calls share it, because refresh tokens are single use.
    @ObservationIgnored private var refreshingTokens: Task<AccountTokens, Error>?
    /// The post-checkout polling, cancelled when the paywall closes or the plan settles.
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private let sleep: @Sendable (Duration) async throws -> Void
    /// True while a renewal change is saving, for the Settings toggle's spinner.
    private(set) var isChangingRenewal = false
    /// Set when Manage Subscription opened the billing portal. The next activation of the app refreshes the plan.
    private(set) var awaitingPortalReturn = false

    private static let accountKey = "uncloudAccount"
    private static let entitlementKey = "uncloudEntitlement"
    private static let refreshInterval: TimeInterval = 24 * 60 * 60
    private static let refreshWindow: TimeInterval = 60

    init(
        mode: AccountMode,
        service: AccountService,
        tokens: AccountTokenStore,
        defaults: UserDefaults = .standard,
        clock: @escaping @Sendable () -> Date = { Date() },
        openURL: @escaping @MainActor (URL) -> Void = { NSWorkspace.shared.open($0) },
        isExportRunning: @escaping @MainActor () -> Bool = { false },
        verifyCachedEntitlement: @escaping @Sendable (Entitlement, String) -> Bool = { _, _ in true },
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.mode = mode
        self.service = service
        self.tokenStore = tokens
        self.defaults = defaults
        self.clock = clock
        self.openURL = openURL
        self.isExportRunning = isExportRunning
        self.sleep = sleep

        // Restoring is synchronous: the account and plan come from defaults, the tokens from the store.
        let cachedAccount = mode == .off ? nil : Self.load(UncloudAccount.self, forKey: Self.accountKey, in: defaults)
        let cachedEntitlement = Self.load(Entitlement.self, forKey: Self.entitlementKey, in: defaults) ?? .free
        let storedTokens = mode == .off ? nil : tokens.load()
        // A cached plan whose signature doesn't verify is not trusted: Free until the server answers.
        let trusted = cachedAccount != nil && cachedAccount.map { verifyCachedEntitlement(cachedEntitlement, $0.id) } == true
        // Tokens the Keychain won't give back (denied, locked) don't end a verified session: the user stays signed in,
        // and a server call asks for sign-in again (M5).
        let signedIn = cachedAccount != nil && (storedTokens != nil || trusted)
        phase = mode == .off ? .off : (signedIn ? .signedIn : .signedOut(.welcome))
        account = signedIn ? cachedAccount : nil
        entitlement = signedIn && trusted ? cachedEntitlement : .free
        self.tokens = signedIn ? storedTokens : nil
        if signedIn && !trusted {
            refreshTask = Task { await refreshEntitlement(force: true) }
        }
    }

    /// The app's model. Preview accounts for Debug builds. `live` talks to the server; if its configuration is
    /// incomplete, `AccountConfiguration` has already resolved it to `off`.
    convenience init(
        configuration: AccountConfiguration = .current,
        isExportRunning: @escaping @MainActor () -> Bool = { false }
    ) {
        switch configuration.mode {
        case .preview:
            self.init(
                mode: .preview, service: PreviewAccountService(), tokens: DefaultsAccountTokenStore(defaults: .standard),
                isExportRunning: isExportRunning
            )
        case .live:
            let verifier = EntitlementVerifier(base64PublicKey: configuration.entitlementPublicKey)
            if let service = LiveAccountService(configuration: configuration, verifier: verifier) {
                self.init(
                    mode: .live,
                    service: service,
                    tokens: KeychainAccountTokenStore(),
                    isExportRunning: isExportRunning,
                    verifyCachedEntitlement: { entitlement, accountID in verifier.isValid(entitlement, accountID: accountID) }
                )
            } else {
                self.init(mode: .off, service: PreviewAccountService(), tokens: KeychainAccountTokenStore())
            }
        case .off:
            self.init(mode: .off, service: PreviewAccountService(), tokens: KeychainAccountTokenStore())
        }
    }

    /// The plan's access right now. Computed from the clock, so grace and expiry move on their own.
    var access: EntitlementPolicy.Access {
        EntitlementPolicy.access(entitlement, now: clock())
    }

    /// Whether a paid feature may be used. Always true when accounts are off.
    func allows(_ feature: PaidFeature) -> Bool {
        mode == .off || access != .free
    }

    /// Whether the full menus show. Signed out, the menus are reduced to the system items and Help (plan B.2).
    var showsAppMenus: Bool {
        phase == .off || phase == .signedIn
    }

    /// Runs `action` if the feature is allowed. Otherwise opens the paywall; `action` runs after a successful subscribe, on Continue.
    func require(_ feature: PaidFeature, _ action: @escaping @MainActor () -> Void) {
        if allows(feature) {
            action()
            return
        }
        checkout = .idle
        paywall = PaywallRequest(feature: feature, then: action)
    }

    /// Opens the paywall without a feature, from Settings. Nothing runs after it.
    func showPaywall() {
        guard mode != .off, case .signedIn = phase else { return }
        checkout = .idle
        paywall = PaywallRequest(feature: nil, then: nil)
    }

    /// Moves between Welcome, Sign Up, Sign In and the code screen. Does nothing while signed in.
    func show(_ route: Route) {
        guard case .signedOut = phase else { return }
        if isBusy {
            cancelRequest()
        }
        phase = .signedOut(route)
        error = nil
    }

    func submitEmail(_ raw: String, intent: AuthIntent) async {
        guard mode != .off, case .signedOut = phase, !isBusy else { return }
        guard let normalized = EmailAddress.normalized(raw) else {
            error = .invalidEmail
            return
        }
        email = normalized
        let service = service
        await perform({ try await service.requestCode(email: normalized, intent: intent) }) { challenge in
            self.phase = .signedOut(.code(challenge, intent))
        }
    }

    func submitCode(_ raw: String) async {
        guard mode != .off, case let .signedOut(.code(challenge, _)) = phase, !isBusy else { return }
        let code = OneTimeCode.sanitized(raw)
        guard OneTimeCode.isComplete(code) else { return }
        let service = service
        await perform({ try await service.verify(challenge: challenge, code: code) }) { session in
            self.didSignIn(session)
        }
    }

    func resendCode() async {
        guard mode != .off, case let .signedOut(.code(challenge, intent)) = phase, !isBusy else { return }
        let service = service
        await perform({ try await service.requestCode(email: challenge.email, intent: intent) }) { fresh in
            self.phase = .signedOut(.code(fresh, intent))
        }
    }

    /// Drops the error once the user edits the field it belongs to.
    func clearError() {
        error = nil
    }

    /// Stops the request in flight, such as on Esc. Its result is dropped and the screen stays as it was.
    func cancelRequest() {
        guard isBusy else { return }
        requestID += 1
        requestCanceller?()
        requestCanceller = nil
        isBusy = false
    }

    /// Signs out on this Mac. The server revokes the refresh token on a best-effort basis.
    /// Refused while an export runs, so the export's sign-in is never pulled away mid-run.
    func signOut() async {
        guard mode != .off, case .signedIn = phase, !isExportRunning() else { return }
        let old = tokens
        forgetAccount()
        phase = .signedOut(.welcome)
        if let old {
            await service.signOut(tokens: old)
        }
    }

    /// Asks the server for the current plan. Non-forced calls only check once a day. Offline keeps the cache.
    func refreshEntitlement(force: Bool) async {
        guard mode != .off, case .signedIn = phase, tokens != nil else { return }
        if !force, clock().timeIntervalSince(entitlement.checkedAt) < Self.refreshInterval {
            return
        }
        do {
            // Refreshes the tokens through the shared refresh first, so no two paths spend the same refresh token (L3).
            let current = try await currentTokens(forceRefresh: false)
            let fresh = try await service.currentEntitlement(tokens: current)
            guard case .signedIn = phase else { return }
            entitlement = fresh
            cacheAccount()
            settleCheckout()
        } catch AccountError.signedOut {
            // A revoked session. Already ended by `currentTokens` when the refresh was refused; this covers the plan call.
            if case .signedIn = phase {
                revokeSession()
            }
        } catch {
            // Offline and server errors keep the cached plan.
        }
    }

    /// Opens Stripe Checkout in the browser. The paywall waits there until the app comes back with a refreshed plan.
    /// `renewal` is the paywall's choice: automatic renewal, or one year that ends (plan §1).
    func openCheckout(for feature: PaidFeature?, renewal: Renewal = .automatic) async {
        guard mode != .off, case .signedIn = phase else { return }
        checkout = .opening
        error = nil
        let service = service
        do {
            let url = try await authorized { try await service.checkoutURL(tokens: $0, renewal: renewal) }
            openURL(url)
            checkout = .waiting(processing: false)
        } catch AccountError.alreadySubscribed {
            // Already on Plus: show the plan, not a second checkout.
            checkout = .waiting(processing: false)
            await refreshEntitlement(force: true)
            if case .waiting = checkout {
                checkout = .failed(.alreadySubscribed)
            }
        } catch {
            checkout = .failed(error as? AccountError ?? .server(message: nil))
        }
    }

    func openManageSubscription() async {
        guard mode != .off, case .signedIn = phase else { return }
        error = nil
        let service = service
        do {
            let url = try await authorized { try await service.manageSubscriptionURL(tokens: $0) }
            openURL(url)
            awaitingPortalReturn = true
        } catch {
            self.error = error as? AccountError ?? .server(message: nil)
        }
    }

    /// Turns renewal on or off for the current plan. On failure the old plan stays and `error` says why.
    func setAutoRenew(_ autoRenew: Bool) async {
        guard mode != .off, case .signedIn = phase, !isChangingRenewal else { return }
        isChangingRenewal = true
        error = nil
        defer { isChangingRenewal = false }
        let service = service
        do {
            let fresh = try await authorized { try await service.setAutoRenew(autoRenew, tokens: $0) }
            guard case .signedIn = phase else { return }
            entitlement = fresh
            cacheAccount()
        } catch {
            if case .signedIn = phase {
                self.error = error as? AccountError ?? .server(message: nil)
            }
        }
    }

    /// Handles a `uncloud://` link. Returns false for anything it doesn't handle (plan D.2).
    @discardableResult
    func handle(_ url: URL) -> Bool {
        guard mode != .off, let action = AccountURL(url) else { return false }
        switch action {
        case .checkoutSuccess:
            // A hint to look again. The server decides whether the plan is paid.
            refreshTask = Task {
                await refreshEntitlement(force: true)
                if case .waiting = checkout, access == .free {
                    checkout = .waiting(processing: true)
                    pollAfterCheckout()
                }
            }
        case .checkoutCancel:
            if paywall != nil {
                checkout = .idle
            }
        case .refresh:
            refreshTask = Task { await refreshEntitlement(force: true) }
        }
        return true
    }

    /// Continue on the paywall's thank-you state. Closes the paywall and runs the action that opened it.
    func finishPaywall() {
        guard checkout == .active else { return }
        let then = paywall?.then
        dismissPaywall()
        then?()
    }

    /// Not Now, or closing the paywall. The action that opened it doesn't run.
    func dismissPaywall() {
        paywall = nil
        checkout = .idle
    }

    /// The app became active. If the browser was on checkout or the billing portal, looks at the plan again.
    func appDidBecomeActive() {
        guard mode != .off, case .signedIn = phase else { return }
        var checkoutOpen = false
        if case .waiting = checkout {
            checkoutOpen = true
        }
        guard awaitingPortalReturn || checkoutOpen else { return }
        awaitingPortalReturn = false
        refreshTask = Task { await refreshEntitlement(force: true) }
    }

    #if DEBUG
    /// Preview only: ends the plan now, so the locks and the ended captions can be checked by hand.
    func debugExpireNow() {
        guard mode == .preview, case .signedIn = phase else { return }
        entitlement = Entitlement(plan: .free, status: .expired, currentPeriodEnd: clock(), cancelAtPeriodEnd: false, checkedAt: clock())
        cacheAccount()
    }
    #endif

    /// Called when an export ends. Applies a session the server revoked while it ran (M4). Revocation is deferred
    /// while `isExportRunning` says so, and this is where the deferred one is applied.
    func exportDidFinish() {
        guard deferredRevocation else { return }
        deferredRevocation = false
        revokeSession()
    }

    // MARK: - Private

    /// Runs a server call with a current access token (plan §6.3). Refreshes first when the token is about to expire,
    /// and retries once after a refresh when the server says the token is no good. A second failure ends the session.
    private func authorized<T: Sendable>(_ call: @escaping @Sendable (AccountTokens) async throws -> T) async throws -> T {
        let current = try await currentTokens(forceRefresh: false)
        do {
            return try await call(current)
        } catch AccountError.signedOut {
            let renewed = try await currentTokens(forceRefresh: true)
            do {
                return try await call(renewed)
            } catch AccountError.signedOut {
                revokeSession()
                throw AccountError.signedOut
            }
        }
    }

    private func currentTokens(forceRefresh: Bool) async throws -> AccountTokens {
        guard let current = tokens ?? reloadTokens() else {
            // Signed in, but the tokens can't be read. Ask for sign-in again; the session itself is kept (M5).
            throw AccountError.signedOut
        }
        if !forceRefresh, current.accessExpiresAt >= clock().addingTimeInterval(Self.refreshWindow) {
            return current
        }
        do {
            return try await sharedRefresh(current)
        } catch AccountError.signedOut {
            revokeSession()
            throw AccountError.signedOut
        }
    }

    /// Reads the tokens from the store again, for a session that started without them. A grant or unlock since launch is used.
    private func reloadTokens() -> AccountTokens? {
        guard case .signedIn = phase, let loaded = tokenStore.load() else { return nil }
        tokens = loaded
        return loaded
    }

    /// One refresh at a time. The refreshed pair is saved before anyone uses it, because the old refresh token is spent.
    private func sharedRefresh(_ current: AccountTokens) async throws -> AccountTokens {
        if let inFlight = refreshingTokens {
            return try await inFlight.value
        }
        let service = service
        let task = Task { try await service.refresh(tokens: current) }
        refreshingTokens = task
        let renewed: AccountTokens
        do {
            renewed = try await task.value
        } catch {
            refreshingTokens = nil
            throw error
        }
        refreshingTokens = nil
        if case .signedIn = phase {
            tokens = renewed
            try? tokenStore.save(renewed)
        }
        return renewed
    }

    /// While the browser is back and the server hasn't confirmed a plan, looks again at 2, 5, 10, 20 and 40 seconds.
    private func pollAfterCheckout() {
        pollTask?.cancel()
        let sleep = sleep
        let gaps: [Duration] = [.seconds(2), .seconds(3), .seconds(5), .seconds(10), .seconds(20)]
        pollTask = Task {
            for gap in gaps {
                do {
                    try await sleep(gap)
                } catch {
                    return
                }
                guard case .waiting(processing: true) = checkout else { return }
                await refreshEntitlement(force: true)
            }
        }
    }

    /// Runs one sign-in request. Its result is applied only if the request wasn't cancelled or superseded.
    private func perform<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T, apply: (T) -> Void) async {
        requestID += 1
        let id = requestID
        isBusy = true
        error = nil
        let task = Task { try await operation() }
        requestCanceller = { task.cancel() }
        let result = await task.result
        guard id == requestID else { return }
        requestCanceller = nil
        isBusy = false
        switch result {
        case let .success(value):
            apply(value)
        case let .failure(failure):
            error = (failure as? AccountError) ?? .server(message: nil)
        }
    }

    private func didSignIn(_ session: AuthSession) {
        tokens = session.tokens
        // A failed Keychain write only means the user has to sign in again after a relaunch.
        try? tokenStore.save(session.tokens)
        account = session.account
        entitlement = session.entitlement
        isNewAccount = session.isNewAccount
        cacheAccount()
        phase = .signedIn
        error = nil
    }

    /// Signed-out state after the server revoked the session. The Welcome page says why.
    private func revokeSession() {
        guard !isExportRunning() else {
            deferredRevocation = true
            return
        }
        forgetAccount()
        phase = .signedOut(.welcome)
        error = .signedOut
    }

    private func forgetAccount() {
        tokens = nil
        tokenStore.clear()
        account = nil
        entitlement = .free
        isNewAccount = false
        deferredRevocation = false
        checkout = .idle
        paywall = nil
        cacheAccount()
    }

    /// A paywall waiting on checkout moves to its thank-you state once the server reports a paid plan.
    private func settleCheckout() {
        guard paywall != nil else { return }
        switch checkout {
        case .opening, .waiting:
            if access != .free {
                checkout = .active
            }
        case .idle, .active, .failed:
            break
        }
    }

    /// Stores the account and plan in defaults. Neither is secret. The tokens are never written here.
    private func cacheAccount() {
        Self.save(account, forKey: Self.accountKey, in: defaults)
        Self.save(account == nil ? nil : entitlement, forKey: Self.entitlementKey, in: defaults)
    }

    private static func load<T: Decodable>(_ type: T.Type, forKey key: String, in defaults: UserDefaults) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    private static func save<T: Encodable>(_ value: T?, forKey key: String, in defaults: UserDefaults) {
        guard let value else {
            defaults.removeObject(forKey: key)
            return
        }
        if let data = try? JSONEncoder().encode(value) {
            defaults.set(data, forKey: key)
        }
    }
}
