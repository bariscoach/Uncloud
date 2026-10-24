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

    @Test("Signing in again with the same email is not a new account")
    func returningAccount() async throws {
        let clock = TestClock()
        let service = Self.makeService(clock: clock)
        #expect(try await Self.signIn(service, email: "a@example.com").isNewAccount)
        clock.advance(by: PreviewAccountService.resendInterval)
        #expect(try await Self.signIn(service, email: "a@example.com").isNewAccount == false)
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

    @Test("currentAccount never renews the tokens itself: the model does that, once, for every caller (L3)")
    func entitlementDoesNotRenew() async throws {
        let clock = TestClock()
        let service = Self.makeService(clock: clock)
        let session = try await Self.signIn(service, email: "a@example.com")
        clock.advance(by: PreviewAccountService.accessLifetime + 1)
        _ = try await service.currentAccount(tokens: session.tokens)
        // The old refresh token is still good, because nothing rotated it.
        let renewed = try await service.refresh(tokens: session.tokens)
        #expect(renewed.refreshToken != session.tokens.refreshToken)
    }

    @Test("Signing out revokes the refresh token")
    func signOutRevokes() async throws {
        let service = Self.makeService(clock: TestClock())
        let session = try await Self.signIn(service, email: "a@example.com")
        await service.signOut(tokens: session.tokens)
        await #expect(throws: AccountError.signedOut) {
            try await service.currentAccount(tokens: session.tokens)
        }
    }

    @Test("Delete Account needs the account's email, ignores case and spaces, and removes the account")
    func deleteAccount() async throws {
        let clock = TestClock()
        let defaults = isolatedDefaults()
        let service = Self.makeService(clock: clock, defaults: defaults)
        let session = try await Self.signIn(service, email: "name@example.com")
        await #expect(throws: AccountError.confirmationMismatch) {
            try await service.deleteAccount(confirmEmail: "other@example.com", tokens: session.tokens)
        }
        #expect(PreviewAccountStore(defaults: defaults).load()["name@example.com"] != nil)

        try await service.deleteAccount(confirmEmail: "  NAME@example.com ", tokens: session.tokens)
        #expect(PreviewAccountStore(defaults: defaults).load()["name@example.com"] == nil)
        await #expect(throws: AccountError.signedOut) {
            try await service.currentAccount(tokens: session.tokens)
        }
        clock.advance(by: 60)
        let again = try await Self.signIn(service, email: "name@example.com")
        #expect(again.isNewAccount)
    }

    @Test("A new account records when it was created")
    func recordsCreatedAt() async throws {
        let clock = TestClock()
        let service = Self.makeService(clock: clock)
        let session = try await Self.signIn(service, email: "dated@example.com")
        #expect(session.account.createdAt == clock.now)
    }

    @Test("Accounts survive a new service on the same store")
    func persists() async throws {
        let clock = TestClock()
        let defaults = isolatedDefaults()
        let first = Self.makeService(clock: clock, defaults: defaults)
        let session = try await Self.signIn(first, email: "a@example.com")

        let second = Self.makeService(clock: clock, defaults: defaults)
        let account = try await second.currentAccount(tokens: session.tokens)
        #expect(account.email == "a@example.com")
    }
}
