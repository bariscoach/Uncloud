import Foundation
import Testing
@testable import Uncloud

/// A scripted account service for the model's live paths. Rejects access tokens on demand, to exercise retries.
actor FakeLiveService: AccountService {
    private(set) var refreshCalls = 0
    private(set) var renewalChanges: [Bool] = []
    private(set) var checkoutRenewals: [Renewal] = []
    var rejectAll = false
    var rejectedAccessTokens: Set<String> = []
    var checkoutError: AccountError?
    private(set) var deletions: [String] = []
    var deleteError: AccountError?
    var plan = Entitlement.free
    private let refreshDelay: Duration

    init(refreshDelay: Duration = .zero) {
        self.refreshDelay = refreshDelay
    }

    private func check(_ tokens: AccountTokens) throws {
        if rejectAll || rejectedAccessTokens.contains(tokens.accessToken) {
            throw AccountError.signedOut
        }
    }

    func requestCode(email: String, intent: AuthIntent) async throws -> AuthChallenge {
        throw AccountError.server(message: "not used")
    }

    func verify(challenge: AuthChallenge, code: String) async throws -> AuthSession {
        throw AccountError.server(message: "not used")
    }

    func currentEntitlement(tokens: AccountTokens) async throws -> Entitlement {
        try check(tokens)
        return plan
    }

    func refresh(tokens: AccountTokens) async throws -> AccountTokens {
        refreshCalls += 1
        if refreshDelay > .zero {
            try await Task.sleep(for: refreshDelay)
        }
        let number = refreshCalls
        return AccountTokens(
            accessToken: "access-\(number)",
            refreshToken: "refresh-\(number)",
            accessExpiresAt: Date(timeIntervalSince1970: 2_000_000_000)
        )
    }

    func signOut(tokens: AccountTokens) async {}

    func checkoutURL(tokens: AccountTokens, renewal: Renewal) async throws -> URL {
        try check(tokens)
        checkoutRenewals.append(renewal)
        if let checkoutError { throw checkoutError }
        return URL(string: "https://checkout.stripe.com/c/pay/cs_test_fake")!
    }

    func manageSubscriptionURL(tokens: AccountTokens) async throws -> URL {
        try check(tokens)
        return URL(string: "https://billing.stripe.com/p/session/fake")!
    }

    func setAutoRenew(_ autoRenew: Bool, tokens: AccountTokens) async throws -> Entitlement {
        try check(tokens)
        renewalChanges.append(autoRenew)
        return Entitlement(
            plan: .plus,
            status: .active,
            currentPeriodEnd: Date(timeIntervalSince1970: 2_000_000_000),
            cancelAtPeriodEnd: !autoRenew,
            checkedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
    }

    func deleteAccount(confirmEmail: String, tokens: AccountTokens) async throws {
        try check(tokens)
        if let deleteError {
            throw deleteError
        }
        deletions.append(confirmEmail)
    }

    func setDeleteError(_ value: AccountError?) {
        deleteError = value
    }

    func setRejectAll(_ value: Bool) {
        rejectAll = value
    }

    func setRejectedAccessTokens(_ values: Set<String>) {
        rejectedAccessTokens = values
    }

    func setPlan(_ entitlement: Entitlement) {
        plan = entitlement
    }

    func setCheckoutError(_ error: AccountError?) {
        checkoutError = error
    }
}

/// A token store whose Keychain item can be made unreadable, as when access is denied or the Keychain is locked.
final class GatedTokenStore: AccountTokenStore, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: AccountTokens?
    private var readable: Bool

    init(tokens: AccountTokens, readable: Bool) {
        stored = tokens
        self.readable = readable
    }

    func setReadable(_ value: Bool) {
        lock.lock()
        defer { lock.unlock() }
        readable = value
    }

    func load() -> AccountTokens? {
        lock.lock()
        defer { lock.unlock() }
        return readable ? stored : nil
    }

    func save(_ tokens: AccountTokens) throws {
        lock.lock()
        defer { lock.unlock() }
        stored = tokens
    }

    func clear() {
        lock.lock()
        defer { lock.unlock() }
        stored = nil
    }
}

/// Records the sleeps the poll asks for, so the tests don't wait.
final class SleepLog: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Duration] = []

    func record(_ duration: Duration) {
        lock.lock()
        values.append(duration)
        lock.unlock()
    }

    var all: [Duration] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}

@MainActor
@Suite("AccountModel live paths", .serialized)
struct AccountModelLiveTests {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)
    static let plus = Entitlement(
        plan: .plus,
        status: .active,
        currentPeriodEnd: now.addingTimeInterval(365 * 24 * 60 * 60),
        cancelAtPeriodEnd: false,
        checkedAt: now
    )

    /// A model that starts signed in on `cached` (Free by default), with tokens that expire at `accessExpiresAt`.
    static func signedInModel(
        service: FakeLiveService,
        cached: Entitlement = .free,
        accessExpiresAt: Date = now.addingTimeInterval(3600),
        verifyCachedEntitlement: @escaping @Sendable (Entitlement, String) -> Bool = { _, _ in true },
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        clock: TestClock = TestClock(Self.now),
        gated: GatedTokenStore? = nil
    ) -> (AccountModel, OpenedURLs) {
        let defaults = isolatedDefaults()
        let tokenStore = DefaultsAccountTokenStore(defaults: defaults)
        let tokens = AccountTokens(accessToken: "access-0", refreshToken: "refresh-0", accessExpiresAt: accessExpiresAt)
        try? tokenStore.save(tokens)
        defaults.set(try? JSONEncoder().encode(UncloudAccount(id: "user-1", email: "name@example.com")), forKey: "uncloudAccount")
        defaults.set(try? JSONEncoder().encode(cached), forKey: "uncloudEntitlement")
        let opened = OpenedURLs()
        let model = AccountModel(
            mode: .live,
            service: service,
            tokens: gated ?? tokenStore,
            defaults: defaults,
            clock: clock.reader,
            openURL: { opened.urls.append($0) },
            isExportRunning: { false },
            verifyCachedEntitlement: verifyCachedEntitlement,
            sleep: sleep
        )
        return (model, opened)
    }

    @Test("Concurrent server calls share one token refresh, because refresh tokens are single use")
    func concurrentCallsShareRefresh() async {
        let service = FakeLiveService(refreshDelay: .milliseconds(50))
        let (model, opened) = Self.signedInModel(service: service, accessExpiresAt: Self.now.addingTimeInterval(10))
        async let first: Void = model.openManageSubscription()
        async let second: Void = model.openManageSubscription()
        _ = await (first, second)
        #expect(await service.refreshCalls == 1)
        #expect(opened.urls.count == 2)
        #expect(model.phase == .signedIn)
    }

    @Test("The plan check and a server call share one token refresh, because refresh tokens are single use (L3)")
    func planCheckSharesRefresh() async {
        let service = FakeLiveService(refreshDelay: .milliseconds(50))
        let (model, opened) = Self.signedInModel(service: service, accessExpiresAt: Self.now.addingTimeInterval(10))
        async let plan: Void = model.refreshEntitlement(force: true)
        async let portal: Void = model.openManageSubscription()
        _ = await (plan, portal)
        #expect(await service.refreshCalls == 1)
        #expect(opened.urls.count == 1)
        #expect(model.phase == .signedIn)
    }

    @Test("Tokens the Keychain won't return keep a verified session signed in, and a server call asks for sign-in again (M5)")
    func unreadableTokensKeepSession() async {
        let service = FakeLiveService()
        let gated = GatedTokenStore(
            tokens: AccountTokens(accessToken: "access-0", refreshToken: "refresh-0", accessExpiresAt: Self.now.addingTimeInterval(3600)),
            readable: false
        )
        let (model, opened) = Self.signedInModel(service: service, cached: Self.plus, gated: gated)
        #expect(model.phase == .signedIn)
        #expect(model.account?.id == "user-1")
        #expect(model.access != .free)
        #expect(model.showsAppMenus)

        await model.openManageSubscription()
        #expect(model.phase == .signedIn)
        #expect(model.error == .signedOut)
        #expect(model.access != .free)
        #expect(opened.urls.isEmpty)
        #expect(await service.refreshCalls == 0)

        // Access is granted later: the next call reads the tokens again and succeeds.
        gated.setReadable(true)
        await model.openManageSubscription()
        #expect(model.error == nil)
        #expect(opened.urls.count == 1)
    }

    @Test("Unreadable tokens with a plan that doesn't verify start signed out, as before")
    func unreadableTokensUntrustedPlanIsWelcome() {
        let gated = GatedTokenStore(
            tokens: AccountTokens(accessToken: "access-0", refreshToken: "refresh-0", accessExpiresAt: Self.now),
            readable: false
        )
        let (model, _) = Self.signedInModel(service: FakeLiveService(), cached: Self.plus, verifyCachedEntitlement: { _, _ in false }, gated: gated)
        #expect(model.phase == .signedOut(.welcome))
    }

    @Test("A rejected access token is refreshed once and the call retried")
    func retryAfterSignedOut() async {
        let service = FakeLiveService()
        await service.setRejectedAccessTokens(["access-0"])
        let (model, opened) = Self.signedInModel(service: service)
        await model.openManageSubscription()
        #expect(await service.refreshCalls == 1)
        #expect(opened.urls.count == 1)
        #expect(model.phase == .signedIn)
        #expect(model.error == nil)
    }

    @Test("A second rejection ends the session, and says why")
    func secondRejectionRevokes() async {
        let service = FakeLiveService()
        await service.setRejectAll(true)
        let (model, opened) = Self.signedInModel(service: service)
        await model.openManageSubscription()
        #expect(model.phase == .signedOut(.welcome))
        #expect(model.error == .signedOut)
        #expect(model.account == nil)
        #expect(opened.urls.isEmpty)
    }

    @Test("Setting renewal updates the plan on success, and the toggle state with it")
    func setAutoRenew() async {
        let service = FakeLiveService()
        let (model, _) = Self.signedInModel(service: service)
        await model.setAutoRenew(false)
        #expect(await service.renewalChanges == [false])
        #expect(model.entitlement.cancelAtPeriodEnd == true)
        #expect(model.isChangingRenewal == false)
        #expect(model.error == nil)
    }

    @Test("Already subscribed refreshes the plan and the paywall shows it as active")
    func alreadySubscribedSettles() async {
        let service = FakeLiveService()
        await service.setCheckoutError(.alreadySubscribed)
        await service.setPlan(Self.plus)
        let (model, opened) = Self.signedInModel(service: service)
        model.require(.browseBackup) {}
        await model.openCheckout(for: .browseBackup, renewal: .oneYear)
        #expect(model.checkout == .active)
        #expect(opened.urls.isEmpty)
        #expect(await service.checkoutRenewals == [.oneYear])
    }

    @Test("A cached plan whose signature doesn't verify loads as Free, and a fresh check is scheduled")
    func untrustedCacheIsNotTrusted() async {
        let service = FakeLiveService()
        await service.setPlan(Self.plus)
        let (model, _) = Self.signedInModel(service: service, verifyCachedEntitlement: { _, _ in false })
        #expect(model.entitlement == .free)
        await model.refreshTask?.value
        #expect(model.entitlement.plan == .plus)
    }

    @Test("After the browser comes back before the plan is confirmed, the server is polled at 2, 5, 10, 20 and 40 seconds")
    func pollingSchedule() async throws {
        let service = FakeLiveService()
        let log = SleepLog()
        let (model, _) = Self.signedInModel(service: service, sleep: { log.record($0) })
        model.require(.browseBackup) {}
        await model.openCheckout(for: .browseBackup)
        #expect(model.handle(URL(string: "uncloud://checkout/success?session_id=cs_test_abc123")!))
        await model.refreshTask?.value
        #expect(model.checkout == .waiting(processing: true))
        for _ in 0..<500 where log.all.count < 5 {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(log.all == [.seconds(2), .seconds(3), .seconds(5), .seconds(10), .seconds(20)])
    }

    @Test("Delete Account sends the typed email; success forgets the account")
    func deleteAccountLive() async {
        let service = FakeLiveService()
        let (model, _) = Self.signedInModel(service: service)
        #expect(await model.deleteAccount(confirmEmail: "Name@Example.com") == true)
        #expect(await service.deletions == ["Name@Example.com"])
        #expect(model.phase == .signedOut(.welcome))
        #expect(model.notice == .accountDeleted)
    }

    @Test("Delete Account offline leaves the account signed in, with the offline message")
    func deleteAccountOffline() async {
        let service = FakeLiveService()
        await service.setDeleteError(.offline)
        let (model, _) = Self.signedInModel(service: service)
        #expect(await model.deleteAccount(confirmEmail: "name@example.com") == false)
        #expect(model.error == .offline)
        #expect(model.phase == .signedIn)
        #expect(model.account != nil)
        #expect(model.isDeletingAccount == false)
    }

    @Test("A session the server revokes during delete ends sign-in")
    func deleteAccountRevoked() async {
        let service = FakeLiveService()
        await service.setRejectAll(true)
        let (model, _) = Self.signedInModel(service: service)
        #expect(await model.deleteAccount(confirmEmail: "name@example.com") == false)
        #expect(model.phase == .signedOut(.welcome))
        #expect(model.error == .signedOut)
    }
}
