import Foundation
import Testing
@testable import Uncloud

/// A scripted account service for the model's live paths. Rejects access tokens on demand, to exercise retries.
actor FakeLiveService: AccountService {
    private(set) var refreshCalls = 0
    private(set) var accountCalls = 0
    var rejectAll = false
    var rejectedAccessTokens: Set<String> = []
    var accountError: AccountError?
    private(set) var deletions: [String] = []
    var deleteError: AccountError?
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

    func currentAccount(tokens: AccountTokens) async throws -> UncloudAccount {
        accountCalls += 1
        try check(tokens)
        if let accountError { throw accountError }
        return UncloudAccount(id: "user-1", email: "name@example.com")
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

    func setAccountError(_ error: AccountError?) {
        accountError = error
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

@MainActor
@Suite("AccountModel live paths", .serialized)
struct AccountModelLiveTests {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)

    /// A model that starts signed in on the cached account, with tokens that expire at `accessExpiresAt`.
    /// Pass `gated` to make the token store unreadable.
    static func signedInModel(
        service: FakeLiveService,
        accessExpiresAt: Date = now.addingTimeInterval(3600),
        checkedAt: Date? = nil,
        clock: TestClock = TestClock(Self.now),
        gated: GatedTokenStore? = nil
    ) -> AccountModel {
        let defaults = isolatedDefaults()
        let tokenStore = DefaultsAccountTokenStore(defaults: defaults)
        let tokens = AccountTokens(accessToken: "access-0", refreshToken: "refresh-0", accessExpiresAt: accessExpiresAt)
        try? tokenStore.save(tokens)
        let cached = UncloudAccount(id: "user-1", email: "name@example.com", checkedAt: checkedAt)
        defaults.set(try? JSONEncoder().encode(cached), forKey: "uncloudAccount")
        return AccountModel(
            mode: .live,
            service: service,
            tokens: gated ?? tokenStore,
            defaults: defaults,
            clock: clock.reader,
            isExportRunning: { false }
        )
    }

    @Test("Concurrent server calls share one token refresh, because refresh tokens are single use")
    func concurrentCallsShareRefresh() async throws {
        let service = FakeLiveService(refreshDelay: .milliseconds(50))
        // The access token is inside the refresh window, so every call refreshes first.
        let model = Self.signedInModel(service: service, accessExpiresAt: Self.now.addingTimeInterval(10))
        async let first: Void = model.refreshAccount(force: true)
        async let second: Void = model.refreshAccount(force: true)
        _ = await (first, second)
        #expect(await service.refreshCalls == 1)
        #expect(model.phase == .signedIn)
    }

    @Test("Tokens the Keychain won't return keep the session signed in, and a server call asks for sign-in again (M5)")
    func unreadableTokensKeepSession() async throws {
        let service = FakeLiveService()
        let gated = GatedTokenStore(
            tokens: AccountTokens(accessToken: "access-0", refreshToken: "refresh-0", accessExpiresAt: Self.now.addingTimeInterval(3600)),
            readable: false
        )
        let model = Self.signedInModel(service: service, gated: gated)
        #expect(model.phase == .signedIn)

        await model.refreshAccount(force: true)
        #expect(model.phase == .signedIn)
        #expect(await service.accountCalls == 0)

        #expect(await model.deleteAccount(confirmEmail: "name@example.com") == false)
        #expect(model.phase == .signedIn)
        #expect(await service.deletions.isEmpty)
    }

    @Test("A rejected access token is refreshed once and the call retried")
    func rejectedTokenRetried() async throws {
        let service = FakeLiveService()
        await service.setRejectedAccessTokens(["access-0"])
        let model = Self.signedInModel(service: service)
        #expect(await model.deleteAccount(confirmEmail: "name@example.com"))
        #expect(await service.refreshCalls == 1)
        #expect(await service.deletions == ["name@example.com"])
    }

    @Test("A second rejection ends the session, and says why")
    func secondRejectionSignsOut() async throws {
        let service = FakeLiveService()
        await service.setRejectAll(true)
        let model = Self.signedInModel(service: service)
        #expect(await model.deleteAccount(confirmEmail: "name@example.com") == false)
        #expect(model.phase == .signedOut(.welcome))
        #expect(model.error == .signedOut)
    }

    @Test("The server revoking the session during an account check signs out")
    func revokedDuringCheck() async throws {
        let service = FakeLiveService()
        await service.setRejectAll(true)
        let model = Self.signedInModel(service: service)
        await model.refreshAccount(force: true)
        #expect(model.phase == .signedOut(.welcome))
        #expect(model.error == .signedOut)
    }

    @Test("Delete Account offline leaves the account signed in, with the offline message")
    func deleteOffline() async throws {
        let service = FakeLiveService()
        await service.setDeleteError(.offline)
        let model = Self.signedInModel(service: service)
        #expect(await model.deleteAccount(confirmEmail: "name@example.com") == false)
        #expect(model.phase == .signedIn)
        #expect(model.error == .offline)
        #expect(model.isDeletingAccount == false)
    }

    @Test("Launch confirms the account once a day, and not again within the day")
    func accountCheckOncePerDay() async throws {
        let service = FakeLiveService()
        let clock = TestClock(Self.now)
        let model = Self.signedInModel(service: service, clock: clock)
        await model.refreshAccount(force: false)
        #expect(await service.accountCalls == 1)
        #expect(model.account?.checkedAt == Self.now)

        clock.advance(by: 60)
        await model.refreshAccount(force: false)
        #expect(await service.accountCalls == 1)

        clock.advance(by: 24 * 60 * 60)
        await model.refreshAccount(force: false)
        #expect(await service.accountCalls == 2)
    }

    @Test("An offline check keeps the cached account, signed in")
    func offlineCheckKeepsAccount() async throws {
        let service = FakeLiveService()
        await service.setAccountError(.offline)
        let model = Self.signedInModel(service: service, checkedAt: nil)
        await model.refreshAccount(force: true)
        #expect(model.phase == .signedIn)
        #expect(model.account?.email == "name@example.com")
        #expect(model.account?.checkedAt == nil)
    }
}
