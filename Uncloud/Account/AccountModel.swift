import AppKit
import Foundation
import Observation

/// The one object the account views read: the phase and the account.
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

    /// A one-line message for Welcome and Settings that outlives the screen it was set on.
    enum Notice: Equatable {
        case accountDeleted
    }

    let mode: AccountMode
    private(set) var phase: Phase
    private(set) var account: UncloudAccount?
    /// Whether the last sign-in created the account. The Welcome announcement depends on it.
    private(set) var isNewAccount = false
    /// The email from the last submit, kept when moving between the email and code screens.
    private(set) var email = ""
    /// A sign-in request is in flight.
    private(set) var isBusy = false
    /// The error for the current screen.
    private(set) var error: AccountError?

    private let service: AccountService
    @ObservationIgnored private let tokenStore: AccountTokenStore
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let clock: @Sendable () -> Date
    @ObservationIgnored private let isExportRunning: @MainActor () -> Bool
    @ObservationIgnored private var tokens: AccountTokens?
    /// Counts sign-in requests, so a cancelled or superseded request's result is ignored.
    @ObservationIgnored private var requestID = 0
    @ObservationIgnored private var requestCanceller: (() -> Void)?
    /// Set when the server revoked the session while an export ran. Applied by `exportDidFinish()`.
    @ObservationIgnored private var deferredRevocation = false
    /// A token refresh in flight. Concurrent server calls share it, because refresh tokens are single use.
    @ObservationIgnored private var refreshingTokens: Task<AccountTokens, Error>?
    /// True while Delete Account is running, so the sheet's button can show progress and a second call is ignored.
    private(set) var isDeletingAccount = false
    /// Set by the popover and the app menu. The main window hosts the sign-out confirmation it opens.
    var isConfirmingSignOut = false
    /// Set after the account is deleted, cleared by the next sign-in.
    private(set) var notice: Notice?

    private static let accountKey = "uncloudAccount"
    /// The plan cache of earlier builds. Removed at launch, since nothing reads it now.
    private static let legacyPlanKey = "uncloudEntitlement"
    private static let refreshInterval: TimeInterval = 24 * 60 * 60
    private static let refreshWindow: TimeInterval = 60

    init(
        mode: AccountMode,
        service: AccountService,
        tokens: AccountTokenStore,
        defaults: UserDefaults = .standard,
        clock: @escaping @Sendable () -> Date = { Date() },
        isExportRunning: @escaping @MainActor () -> Bool = { false }
    ) {
        self.mode = mode
        self.service = service
        self.tokenStore = tokens
        self.defaults = defaults
        self.clock = clock
        self.isExportRunning = isExportRunning

        // Restoring is synchronous: the account comes from defaults, the tokens from the store.
        let cachedAccount = mode == .off ? nil : Self.load(UncloudAccount.self, forKey: Self.accountKey, in: defaults)
        let storedTokens = mode == .off ? nil : tokens.load()
        // Tokens the Keychain won't give back (denied, locked) don't end the session: the user stays signed in,
        // and a server call asks for sign-in again (M5).
        let signedIn = cachedAccount != nil
        phase = mode == .off ? .off : (signedIn ? .signedIn : .signedOut(.welcome))
        account = signedIn ? cachedAccount : nil
        self.tokens = signedIn ? storedTokens : nil
        defaults.removeObject(forKey: Self.legacyPlanKey)
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
            if let service = LiveAccountService(configuration: configuration) {
                self.init(
                    mode: .live,
                    service: service,
                    tokens: KeychainAccountTokenStore(),
                    isExportRunning: isExportRunning
                )
            } else {
                self.init(mode: .off, service: PreviewAccountService(), tokens: KeychainAccountTokenStore())
            }
        case .off:
            self.init(mode: .off, service: PreviewAccountService(), tokens: KeychainAccountTokenStore())
        }
    }

    /// What the account button, the popover and the Account tab show.
    var summary: AccountSummary {
        AccountSummary.make(mode: mode, phase: phase, account: account)
    }

    /// Whether the full menus show. Signed out, the menus are reduced to the system items and Help (plan B.2).
    var showsAppMenus: Bool {
        phase == .off || phase == .signedIn
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

    /// Confirms the account with the server. Non-forced calls only check once a day. Offline keeps the cached account.
    func refreshAccount(force: Bool) async {
        guard mode != .off, case .signedIn = phase, tokens != nil || reloadTokens() != nil else { return }
        if !force, let checked = account?.checkedAt, clock().timeIntervalSince(checked) < Self.refreshInterval {
            return
        }
        do {
            // Refreshes the tokens through the shared refresh first, so no two paths spend the same refresh token (L3).
            let current = try await currentTokens(forceRefresh: false)
            let fresh = try await service.currentAccount(tokens: current)
            guard case .signedIn = phase else { return }
            account = UncloudAccount(id: fresh.id, email: fresh.email, createdAt: account?.createdAt, checkedAt: clock())
            cacheAccount()
        } catch AccountError.signedOut {
            // A revoked session. Already ended by `currentTokens` when the refresh was refused; this covers the account call.
            if case .signedIn = phase {
                revokeSession()
            }
        } catch {
            // Offline and server errors keep the cached account.
        }
    }

    /// Deletes the account. `confirmEmail` is what the user typed; it must match the account's email,
    /// ignoring case and spaces, or nothing is sent. On success the account is forgotten on this Mac and the
    /// signed-out screens show `notice`. Refused during an export, as sign-out is.
    @discardableResult
    func deleteAccount(confirmEmail raw: String) async -> Bool {
        guard mode != .off, case .signedIn = phase, !isExportRunning(), !isDeletingAccount else { return false }
        let typed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let accountEmail = account?.email, typed.lowercased() == accountEmail.lowercased() else {
            error = .confirmationMismatch
            return false
        }
        isDeletingAccount = true
        error = nil
        defer { isDeletingAccount = false }
        let service = service
        do {
            try await authorized { try await service.deleteAccount(confirmEmail: typed, tokens: $0) }
        } catch AccountError.signedOut {
            // The session ended: `authorized` already moved the app to the signed-out screens.
            return false
        } catch {
            self.error = error as? AccountError ?? .server(message: nil)
            return false
        }
        forgetAccount()
        phase = .signedOut(.welcome)
        error = nil
        isConfirmingSignOut = false
        notice = .accountDeleted
        return true
    }

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
        isNewAccount = session.isNewAccount
        notice = nil
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
        isNewAccount = false
        deferredRevocation = false
        cacheAccount()
    }

    /// Stores the account in defaults. It is not secret. The tokens are never written here.
    private func cacheAccount() {
        Self.save(account, forKey: Self.accountKey, in: defaults)
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
