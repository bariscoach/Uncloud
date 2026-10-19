import Foundation
import Testing
@testable import Uncloud

@Suite("PreviewAccountService")
struct PreviewAccountServiceTests {
    private static func makeService(clock: TestClock, defaults: UserDefaults? = nil) -> PreviewAccountService {
        PreviewAccountService(store: PreviewAccountStore(defaults: defaults ?? isolatedDefaults()), now: clock.reader)
    }

    /// Requests a code and signs in with it.
    private static func signIn(_ service: PreviewAccountService, email: String) async throws -> AuthSession {
        let challenge = try await service.requestCode(email: email, intent: .signUp)
        return try await service.verify(challenge: challenge, code: PreviewAccountService.code)
    }

    @Test("A code verifies and creates the account")
    func requestAndVerify() async throws {
        let service = Self.makeService(clock: TestClock())
        let session = try await Self.signIn(service, email: "New@Example.com")
        #expect(session.isNewAccount)
        #expect(session.account.email == "new@example.com")
        #expect(session.entitlement.plan == .free)
        #expect(session.entitlement.status == .none)
    }

    @Test("Five wrong codes end the challenge, and the right code no longer works")
    func tooManyAttempts() async throws {
        let service = Self.makeService(clock: TestClock())
        let challenge = try await service.requestCode(email: "a@example.com", intent: .signIn)
        for _ in 0..<4 {
            await #expect(throws: AccountError.wrongCode) {
                try await service.verify(challenge: challenge, code: "000000")
            }
        }
        await #expect(throws: AccountError.tooManyAttempts) {
            try await service.verify(challenge: challenge, code: "000000")
        }
        await #expect(throws: AccountError.tooManyAttempts) {
            try await service.verify(challenge: challenge, code: PreviewAccountService.code)
        }
    }

    @Test("A challenge expires after ten minutes")
    func expires() async throws {
        let clock = TestClock()
        let service = Self.makeService(clock: clock)
        let challenge = try await service.requestCode(email: "a@example.com", intent: .signIn)
        clock.advance(by: 601)
        await #expect(throws: AccountError.codeExpired) {
            try await service.verify(challenge: challenge, code: PreviewAccountService.code)
        }
    }

    @Test("Asking again within 30 seconds is rate limited")
    func resendInterval() async throws {
        let clock = TestClock()
        let service = Self.makeService(clock: clock)
        _ = try await service.requestCode(email: "a@example.com", intent: .signIn)
        await #expect(throws: AccountError.self) {
            try await service.requestCode(email: "a@example.com", intent: .signIn)
        }
        clock.advance(by: 30)
        _ = try await service.requestCode(email: "a@example.com", intent: .signIn)
    }

    @Test("Simulation emails produce their errors")
    func simulationEmails() async throws {
        let service = Self.makeService(clock: TestClock())
        await #expect(throws: AccountError.offline) {
            try await service.requestCode(email: "offline@example.com", intent: .signIn)
        }
        await #expect(throws: AccountError.self) {
            try await service.requestCode(email: "limit@example.com", intent: .signIn)
        }
        await #expect(throws: AccountError.invalidEmail) {
            try await service.requestCode(email: "not an email", intent: .signIn)
        }
    }

    @Test("Plus and past-due simulation emails start on those plans")
    func simulatedPlans() async throws {
        let service = Self.makeService(clock: TestClock())
        let plus = try await Self.signIn(service, email: "plus@example.com")
        #expect(plus.entitlement.plan == .plus)
        #expect(plus.entitlement.status == .active)
        #expect(plus.entitlement.currentPeriodEnd != nil)

        let pastDue = try await Self.signIn(service, email: "pastdue@example.com")
        #expect(pastDue.entitlement.plan == .plus)
        #expect(pastDue.entitlement.status == .pastDue)
    }

    @Test("Signing in again with the same email is not a new account")
    func returningAccount() async throws {
        let clock = TestClock()
        let service = Self.makeService(clock: clock)
        #expect(try await Self.signIn(service, email: "a@example.com").isNewAccount)
        clock.advance(by: PreviewAccountService.resendInterval)
        #expect(try await Self.signIn(service, email: "a@example.com").isNewAccount == false)
    }

    @Test("Checkout flips the plan to Plus for a year")
    func checkoutMakesPlus() async throws {
        let clock = TestClock()
        let service = Self.makeService(clock: clock)
        let session = try await Self.signIn(service, email: "a@example.com")

        let url = try await service.checkoutURL(tokens: session.tokens, renewal: .automatic)
        #expect(url.scheme == "uncloud")
        #expect(url.host == "checkout")
        #expect(url.path == "/success")
        #expect(url.query?.hasPrefix("session_id=preview_") == true)

        let (entitlement, _) = try await service.currentEntitlement(tokens: session.tokens)
        #expect(entitlement.plan == .plus)
        #expect(entitlement.status == .active)
        #expect(entitlement.currentPeriodEnd == clock.now.addingTimeInterval(365 * 24 * 60 * 60))
    }

    @Test("Refresh rotates the refresh token, and the old one is then signed out")
    func refreshRotates() async throws {
        let service = Self.makeService(clock: TestClock())
        let session = try await Self.signIn(service, email: "a@example.com")
        let renewed = try await service.refresh(tokens: session.tokens)
        #expect(renewed.refreshToken != session.tokens.refreshToken)
        await #expect(throws: AccountError.signedOut) {
            try await service.refresh(tokens: session.tokens)
        }
    }

    @Test("An expired access token is renewed by currentEntitlement")
    func renewsExpiredAccess() async throws {
        let clock = TestClock()
        let service = Self.makeService(clock: clock)
        let session = try await Self.signIn(service, email: "a@example.com")
        clock.advance(by: PreviewAccountService.accessLifetime + 1)
        let (_, renewed) = try await service.currentEntitlement(tokens: session.tokens)
        #expect(renewed.refreshToken != session.tokens.refreshToken)
    }

    @Test("Signing out revokes the refresh token")
    func signOutRevokes() async throws {
        let service = Self.makeService(clock: TestClock())
        let session = try await Self.signIn(service, email: "a@example.com")
        await service.signOut(tokens: session.tokens)
        await #expect(throws: AccountError.signedOut) {
            try await service.currentEntitlement(tokens: session.tokens)
        }
    }

    @Test("Accounts survive a new service on the same store")
    func persists() async throws {
        let clock = TestClock()
        let defaults = isolatedDefaults()
        let first = Self.makeService(clock: clock, defaults: defaults)
        let session = try await Self.signIn(first, email: "a@example.com")
        _ = try await first.checkoutURL(tokens: session.tokens, renewal: .automatic)

        let second = Self.makeService(clock: clock, defaults: defaults)
        let (entitlement, _) = try await second.currentEntitlement(tokens: session.tokens)
        #expect(entitlement.plan == .plus)
    }

    @Test("One year is the same subscription set not to renew; renewal can be turned back on")
    func renewalChoice() async throws {
        let clock = TestClock()
        let service = Self.makeService(clock: clock)
        let session = try await Self.signIn(service, email: "renew@example.com")
        _ = try await service.checkoutURL(tokens: session.tokens, renewal: .oneYear)
        let (oneYear, tokens) = try await service.currentEntitlement(tokens: session.tokens)
        #expect(oneYear.plan == .plus)
        #expect(oneYear.cancelAtPeriodEnd)

        let renewed = try await service.setAutoRenew(true, tokens: tokens)
        #expect(renewed.cancelAtPeriodEnd == false)
        let stopped = try await service.setAutoRenew(false, tokens: tokens)
        #expect(stopped.cancelAtPeriodEnd)
    }

    @Test("Setting renewal without a plan is noSubscription")
    func renewalNeedsPlan() async throws {
        let service = Self.makeService(clock: TestClock())
        let session = try await Self.signIn(service, email: "free@example.com")
        await #expect(throws: AccountError.noSubscription) {
            try await service.setAutoRenew(true, tokens: session.tokens)
        }
    }
}
